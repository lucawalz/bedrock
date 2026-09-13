#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

namespaces_dir=kubernetes/clusters/home/namespaces
index="$namespaces_dir/default-serviceaccounts.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: > "$work/declared"
for file in "$namespaces_dir"/*.yaml; do
  yq -N 'select(.kind == "Namespace") | .metadata.name' "$file" >> "$work/declared"
done
sort -u "$work/declared" -o "$work/declared"

yq -N 'select(.kind == "ServiceAccount" and .metadata.name == "default") | .metadata.namespace' "$index" \
  | sort -u > "$work/covered"

status=0

compare_sets "$work/declared" "$work/covered" \
  "Namespaces with no default ServiceAccount entry in $index:" \
  "Entries in $index with no matching namespace manifest:"

if [ "$status" -eq 0 ]; then
  echo "Default ServiceAccount list is in sync."
fi
exit "$status"
