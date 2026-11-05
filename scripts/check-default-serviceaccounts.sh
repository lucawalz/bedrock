#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

namespaces_dir=kubernetes/clusters/home/namespaces
index="$namespaces_dir/default-serviceaccounts.yaml"
app_namespaces=(kubernetes/apps/*/namespace.yaml)

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

compare_sets "$work/declared" "$work/covered" \
  "Namespaces with no default ServiceAccount in $index or beside their Namespace:" \
  "Default ServiceAccounts with no matching Namespace manifest:"

if [ "$status" -eq 0 ]; then
  echo "Default ServiceAccount list is in sync."
fi
exit "$status"
