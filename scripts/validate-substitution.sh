#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0

# A literal '$' in a substituted file is consumed by Flux postBuild envsubst unless doubled as '$$'.
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

shopt -s nullglob
for ks in kubernetes/apps/*/ks.yaml; do
  app="$(basename "$(dirname "$ks")")"
  echo "Rendering $app"
  if [ "$has_kubeconform" -eq 1 ]; then
    flux build kustomization "$app" \
      --path "kubernetes/apps/$app/app" \
      --kustomization-file "$ks" \
      --dry-run \
      | kubeconform -strict -ignore-missing-schemas "${schema_args[@]}" -summary || fail=1
  else
    flux build kustomization "$app" \
      --path "kubernetes/apps/$app/app" \
      --kustomization-file "$ks" \
      --dry-run >/dev/null || fail=1
  fi
done

exit "$fail"
