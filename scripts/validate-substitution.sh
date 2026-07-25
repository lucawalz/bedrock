#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0

# A literal '$' in a substituted file is consumed by Flux postBuild envsubst unless doubled as '$$'.
# shellcheck disable=SC2016
if grep -RInE '\$([^${]|$)' kubernetes/apps/*/app 2>/dev/null | grep -vE '\$\$' | grep -v 'apps/blog/'; then
  echo "unescaped '\$' will be mangled by postBuild substitution; escape as '\$\$'"
  fail=1
fi

schema_args=(-schema-location default)
if [ -n "${KUBECONFORM_SCHEMA_LOCATION:-}" ]; then
  schema_args+=(-schema-location "$KUBECONFORM_SCHEMA_LOCATION")
fi

has_kubeconform=0
if command -v kubeconform >/dev/null 2>&1; then
  has_kubeconform=1
else
  echo "kubeconform not found; rendering without schema validation"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find kubernetes/apps -name ks.yaml > "$work/definitions"
find kubernetes/clusters/home/config -name "*.yaml" >> "$work/definitions"

while read -r definition; do
  while read -r name; do
    [ -n "$name" ] || continue

    path="$(NAME="$name" yq -N '
      select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.path
    ' "$definition" | awk 'NF { print; exit }')"
    path="${path#./}"

    if [ ! -d "$path" ]; then
      echo "Kustomization $name points at missing path $path" >&2
      fail=1
      continue
    fi

    echo "Rendering $name from $path"
    if [ "$has_kubeconform" -eq 1 ]; then
      flux build kustomization "$name" \
        --path "$path" \
        --kustomization-file "$definition" \
        --dry-run \
        | kubeconform -strict -ignore-missing-schemas "${schema_args[@]}" -summary || fail=1
    else
      flux build kustomization "$name" \
        --path "$path" \
        --kustomization-file "$definition" \
        --dry-run >/dev/null || fail=1
    fi
  done < <(yq -N '
    select(.kind == "Kustomization" and .spec.sourceRef.name == "flux-system") | .metadata.name
  ' "$definition")
done < "$work/definitions"

exit "$fail"
