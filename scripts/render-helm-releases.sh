#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sources_dir=kubernetes/clusters/home/sources/helm
readonly KUBE_VERSION=1.35.0

# Charts gate optional resources on the API set they discover, which helm cannot read without a cluster.
api_versions=(
  monitoring.coreos.com/v1
  monitoring.coreos.com/v1alpha1
  cert-manager.io/v1
  traefik.io/v1alpha1
  policy/v1
  snapshot.storage.k8s.io/v1
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

output_dir="${RENDER_OUTPUT_DIR:-}"
[ -z "$output_dir" ] || mkdir -p "$output_dir"

schema_args=(-schema-location default)
if [ -n "${KUBECONFORM_SCHEMA_LOCATION:-}" ]; then
  schema_args+=(-schema-location "$KUBECONFORM_SCHEMA_LOCATION")
fi

helm_args=(--kube-version "$KUBE_VERSION")
for api in "${api_versions[@]}"; do
  helm_args+=(--api-versions "$api")
done

source_ref() {
  SOURCE_NAME="$1" yq -N '
    select(.kind == "HelmRepository" and .metadata.name == strenv(SOURCE_NAME))
    | [.spec.url, (.spec.type // "default")] | join(" ")
  ' "$sources_dir"/*.yaml | awk 'NF { print; exit }'
}

fail=0
rendered="$work/rendered.yaml"

grep -rl "kind: HelmRelease" --include="helmrelease.yaml" kubernetes/ \
  | xargs -n1 dirname | sort -u > "$work/directories"

while read -r directory; do
  kustomize build "$directory" > "$rendered"

  for release in $(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$rendered"); do
    export RELEASE="$release"
    yq -N 'select(.kind == "HelmRelease" and .metadata.name == strenv(RELEASE))' "$rendered" > "$work/hr.yaml"

    namespace="$(yq -N '.metadata.namespace' "$work/hr.yaml")"
    chart="$(yq -N '.spec.chart.spec.chart' "$work/hr.yaml")"
    version="$(yq -N '.spec.chart.spec.version' "$work/hr.yaml")"
    source_name="$(yq -N '.spec.chart.spec.sourceRef.name' "$work/hr.yaml")"

    read -r url type <<< "$(source_ref "$source_name")"
    if [ -z "$url" ]; then
      echo "no HelmRepository named $source_name for release $release" >&2
      fail=1
      continue
    fi

    value_args=()
    while read -r configmap; do
      [ -n "$configmap" ] || continue
      export CONFIGMAP="$configmap"
      yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(CONFIGMAP)) | .data["values.yaml"]' \
        "$rendered" > "$work/valuesfrom-$configmap.yaml"
      value_args+=(-f "$work/valuesfrom-$configmap.yaml")
    done < <(yq -N '.spec.valuesFrom[]? | select(.kind == "ConfigMap") | .name' "$work/hr.yaml")

    if [ "$(yq -N '.spec.values // "null"' "$work/hr.yaml")" != "null" ]; then
      yq -N '.spec.values' "$work/hr.yaml" > "$work/values.yaml"
      value_args+=(-f "$work/values.yaml")
    fi

    chart_ref="$chart"
    repo_args=(--repo "$url")
    if [ "$type" = "oci" ]; then
      chart_ref="$url/$chart"
      repo_args=()
    fi

    echo "Rendering $namespace/$release ($chart $version)"
    if ! helm template "$release" "$chart_ref" \
      "${repo_args[@]}" \
      --version "$version" \
      --namespace "$namespace" \
      --include-crds \
      "${value_args[@]}" \
      "${helm_args[@]}" > "$work/raw.yaml"; then
      fail=1
      continue
    fi

    # An OCI pull prints its digest to stdout ahead of the manifests, which is not YAML.
    awk 'seen || /^---$/ { seen = 1; print }' "$work/raw.yaml" > "$work/documents.yaml"
    # Comment-only and hook documents are never applied, and the namespace is stamped at apply time.
    yq '... comments=""' "$work/documents.yaml" \
      | NAMESPACE="$namespace" yq 'select(. != null) | select(.metadata.annotations["helm.sh/hook"] == null) | .metadata.namespace = (.metadata.namespace // strenv(NAMESPACE))' \
      > "$work/output.yaml"

    [ -z "$output_dir" ] || cp "$work/output.yaml" "$output_dir/$namespace.$release.yaml"

    if command -v kubeconform >/dev/null 2>&1; then
      kubeconform -strict -ignore-missing-schemas "${schema_args[@]}" \
        -kubernetes-version "$KUBE_VERSION" -summary "$work/output.yaml" || fail=1
    fi
  done
done < "$work/directories"

exit "$fail"
