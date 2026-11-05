#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

namespaces_dir=kubernetes/clusters/home/namespaces
index="$namespaces_dir/default-serviceaccounts.yaml"
app_namespaces=()
for dir in kubernetes/apps/*/; do
  if [ ! -f "${dir}namespace.yaml" ]; then
    echo "App folder ${dir} has no namespace.yaml with its Namespace and default ServiceAccount."
    exit 1
  fi
  app_namespaces+=("${dir}namespace.yaml")
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: > "$work/declared"
for file in "$namespaces_dir"/*.yaml "${app_namespaces[@]}"; do
  yq -N 'select(.kind == "Namespace") | .metadata.name' "$file" >> "$work/declared"
done
sort -u "$work/declared" -o "$work/declared"

yq -N 'select(.kind == "ServiceAccount" and .metadata.name == "default") | .metadata.namespace' "$index" "${app_namespaces[@]}" \
  | sort -u > "$work/covered"

status=0

for file in "${app_namespaces[@]}"; do
  if [ "$(yq -N 'select(.kind == "Namespace") | .metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' "$file")" != "disabled" ]; then
    echo "$file: Namespace lacks kustomize.toolkit.fluxcd.io/prune: disabled, so removing the app would delete its data."
    status=1
  fi
done

compare_sets "$work/declared" "$work/covered" \
  "Namespaces with no default ServiceAccount in $index or beside their Namespace:" \
  "Default ServiceAccounts with no matching Namespace manifest:"

if [ "$status" -eq 0 ]; then
  echo "Default ServiceAccount list is in sync."
fi
exit "$status"
