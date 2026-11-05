#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools helm yq

sources_dir=kubernetes/clusters/home/sources/helm
readonly KUBE_VERSION=1.35.0

pairs=(
  "traefik-crds traefik"
  "prometheus-operator-crds kube-prometheus-stack"
)

# traefik-crds 1.18.0 predates this field and no Middleware in the repository sets it.
allowed_gaps=(
  "middlewares.traefik.io spec.versions.0.schema.openAPIV3Schema.properties.spec.properties.errors.properties.errorRequestHeaders"
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
printf '%s\n' "${allowed_gaps[@]}" | sort -u > "$work/allowed"
: > "$work/gaps"

schema_fields() {
  local chart="$1" release version source url
  release="$(grep -rl 'kind: HelmRelease' --include='helmrelease.yaml' kubernetes \
    | xargs env CHART="$chart" yq -N 'select(.kind == "HelmRelease" and .spec.chart.spec.chart == strenv(CHART)) | .spec.chart.spec.version + " " + .spec.chart.spec.sourceRef.name' \
    | awk 'NF { print; exit }')"
  if [ -z "$release" ]; then
    echo "No HelmRelease installs chart $chart" >&2
    return 1
  fi
  read -r version source <<< "$release"
  url="$(SOURCE="$source" yq -N 'select(.kind == "HelmRepository" and .metadata.name == strenv(SOURCE)) | .spec.url' "$sources_dir"/*.yaml | awk 'NF { print; exit }')"
  echo "Comparing $chart $version" >&2
  helm template crds "$chart" --repo "$url" --version "$version" --kube-version "$KUBE_VERSION" --include-crds \
    | yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name as $name | .. | select((parent | key) == "properties") | $name + " " + (path | join("."))' \
    | sort -u
}

for pair in "${pairs[@]}"; do
  read -r crd_chart main_chart <<< "$pair"
  schema_fields "$crd_chart" > "$work/crd-chart" || { status=1; continue; }
  schema_fields "$main_chart" > "$work/main-chart" || { status=1; continue; }

  awk '{ sub(/^[^.]*\./, "", $1); print $1 }' "$work/crd-chart" | sort -u > "$work/groups"
  awk 'NR == FNR { groups[$1] = 1; next } { name = $1; sub(/^[^.]*\./, "", name) } name in groups' \
    "$work/groups" "$work/main-chart" > "$work/main-served"
  if [ ! -s "$work/main-served" ]; then
    echo "$main_chart ships no CRD in a group $crd_chart serves, so the pair compares nothing"
    status=1
    continue
  fi

  comm -13 "$work/crd-chart" "$work/main-served" | tee -a "$work/gaps" | comm -23 - "$work/allowed" > "$work/missing"
  if [ -s "$work/missing" ]; then
    echo "$crd_chart lacks CRD fields that $main_chart ships; bump them together:"
    sed 's/^/  - /' "$work/missing"
    status=1
  fi
done

sort -u "$work/gaps" | comm -13 - "$work/allowed" > "$work/stale"
if [ -s "$work/stale" ]; then
  echo "Allowed CRD gaps that no longer occur; remove them from allowed_gaps:"
  sed 's/^/  - /' "$work/stale"
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Every CRD-only chart covers the CRD fields of the chart it replaces."
fi
exit "$status"
