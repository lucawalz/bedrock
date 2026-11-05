#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools kustomize yq helm awk

root_name=flux-system
root_path=kubernetes/clusters/home
# k3s ships these CRDs and the Flux bootstrap installs the toolkit ones before any Kustomization runs.
base_groups="helm.cattle.io k3s.cattle.io source.toolkit.fluxcd.io kustomize.toolkit.fluxcd.io helm.toolkit.fluxcd.io notification.toolkit.fluxcd.io image.toolkit.fluxcd.io"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! RENDER_OUTPUT_DIR="$work/rendered" scripts/render-helm-releases.sh > "$work/render.log" 2>&1; then
  cat "$work/render.log" >&2
  echo "render-helm-releases.sh failed, so CRD sources cannot be resolved" >&2
  exit 1
fi

facts="$work/facts"
: > "$facts"
status=0

emit_objects() {
  local kustomization="$1" origin="$2" file="$3"
  yq -N '[.kind, .apiVersion, (.metadata.namespace // "-") + "/" + .metadata.name, (.spec.group // "-"), (.spec.names.kind // "-")] | @tsv' "$file" \
    | awk -F'\t' -v ks="$kustomization" -v origin="$origin" 'NF {
        group = (index($2, "/") > 0) ? substr($2, 1, index($2, "/") - 1) : ""
        if ($1 == "CustomResourceDefinition") print "provides\t" ks "\t" origin "\t" $4 "/" $5
        else print "uses\t" ks "\t" origin "\t" group "/" $1 "\t" $1 " " $3
      }' >> "$facts"
}

printf '%s\t%s\n' "$root_name" "$root_path" > "$work/queue"
printf 'node\t%s\t\n' "$root_name" >> "$facts"
index=1
while line="$(sed -n "${index}p" "$work/queue")" && [ -n "$line" ]; do
  index=$((index + 1))
  name="${line%%$'\t'*}"
  path="${line#*$'\t'}"
  path="${path#./}"
  build="$work/build-$name.yaml"

  if ! kustomize build "$path" > "$build"; then
    echo "Kustomization $name: kustomize build $path failed" >&2
    status=1
    continue
  fi
  emit_objects "$name" plain "$build"

  while IFS=$'\t' read -r namespace release; do
    [ -n "$release" ] || continue
    rendered="$work/rendered/$namespace.$release.yaml"
    if [ ! -f "$rendered" ]; then
      echo "Kustomization $name: HelmRelease $namespace/$release has no rendering" >&2
      status=1
      continue
    fi
    emit_objects "$name" "helmrelease $namespace/$release" "$rendered"
  done < <(yq -N 'select(.kind == "HelmRelease") | [.metadata.namespace, .metadata.name] | @tsv' "$build")

  yq -N '
    select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1")
    | [.metadata.name, .spec.sourceRef.name, .spec.path, ((.spec.dependsOn // []) | map(.name) | join(","))]
    | @tsv
  ' "$build" | while IFS=$'\t' read -r child source child_path depends; do
    [ -n "$child" ] || continue
    printf 'node\t%s\t%s\n' "$child" "$depends" >> "$facts"
    if [ "$source" = "$root_name" ]; then
      printf '%s\t%s\n' "$child" "$child_path" >> "$work/queue"
    else
      echo "Skipping $child: its source $source is outside this repository" >&2
    fi
  done
done

awk -F'\t' -v base="$base_groups" '
  function reaches(from, target,   parts, count, i) {
    if (from in visited) return 0
    visited[from] = 1
    count = split(deps[from], parts, ",")
    for (i = 1; i <= count; i++) {
      if (parts[i] == target || reaches(parts[i], target)) return 1
    }
    return 0
  }
  BEGIN { split(base, list, " "); for (i in list) based[list[i]] = 1 }
  $1 == "node" { deps[$2] = $3 }
  $1 == "provides" && !(($4, $2, $3) in seen_provider) {
    seen_provider[$4, $2, $3] = 1
    providers[$4]++
    provider_ks[$4, providers[$4]] = $2
    provider_origin[$4, providers[$4]] = $3
  }
  $1 == "uses" && !(($2, $3, $4) in seen_use) {
    seen_use[$2, $3, $4] = 1
    uses++
    use_ks[uses] = $2; use_origin[uses] = $3; use_kind[uses] = $4; use_object[uses] = $5
  }
  END {
    for (crd in providers) {
      if (providers[crd] > 1) {
        owners = ""
        for (i = 1; i <= providers[crd]; i++) owners = owners " " provider_ks[crd, i] " (" provider_origin[crd, i] ")"
        print "FAIL " crd ": CRD installed by more than one source:" owners
        failed = 1
      }
    }
    for (u = 1; u <= uses; u++) {
      crd = use_kind[u]
      group = substr(crd, 1, index(crd, "/") - 1)
      where = use_ks[u] ": " use_object[u] " from " use_origin[u]
      if (!(crd in providers)) {
        if (group in based || group == "" || group !~ /\./ || group ~ /\.k8s\.io$/) continue
        print "FAIL " where ": no Kustomization installs the CRD for " crd
        failed = 1
        continue
      }
      ok = 0
      sources = ""
      for (i = 1; i <= providers[crd]; i++) {
        ks = provider_ks[crd, i]
        origin = provider_origin[crd, i]
        sources = sources " " ks " (" origin ")"
        delete visited
        if (ks == use_ks[u] && (origin == "plain" || origin == use_origin[u])) ok = 1
        else if (reaches(use_ks[u], ks)) ok = 1
      }
      if (!ok) {
        print "FAIL " where ": needs " crd ", whose CRD comes from" sources ", not a dependsOn of " use_ks[u]
        failed = 1
      }
    }
    exit failed
  }
' "$facts" || status=1

if [ "$status" -eq 0 ]; then
  echo "Every custom resource has its CRD installed by an earlier Kustomization."
fi
exit "$status"
