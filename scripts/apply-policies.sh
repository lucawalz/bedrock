#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

policies=kubernetes/infrastructure/configs/policies
kyverno_release=kubernetes/infrastructure/controllers/security/kyverno/helmrelease.yaml

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rendered="$work/rendered"
RENDER_OUTPUT_DIR="$rendered" bash scripts/render-helm-releases.sh > /dev/null

# Namespaces Kyverno filters out of admission must not be gated here either, or CI is stricter than the cluster.
yq -N '.spec.values.config.resourceFiltersIncludeNamespaces[]' "$kyverno_release" > "$work/ungoverned"

governed="$work/governed"
mkdir -p "$governed"

for file in "$rendered"/*.yaml; do
  namespace="${file##*/}"
  namespace="${namespace%%.*}"
  keep=1
  while read -r pattern; do
    # shellcheck disable=SC2053
    if [[ "$namespace" == $pattern ]]; then
      keep=0
      break
    fi
  done < "$work/ungoverned"
  [ "$keep" -eq 0 ] || cp "$file" "$governed/"
done

resource_args=()
for file in "$governed"/*.yaml; do
  resource_args+=(--resource "$file")
done

while read -r file; do
  resource_args+=(--resource "$file")
done < <(find kubernetes/apps -path "*/app/*" -name "deployment.yaml")

# PolicyExceptions are only honoured when passed explicitly, so without this CI is stricter than admission.
kyverno apply "$policies" --exception "$policies/exceptions.yaml" "${resource_args[@]}"
