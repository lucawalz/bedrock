#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

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

missing="$(comm -23 "$work/declared" "$work/covered")"
if [ -n "$missing" ]; then
  echo "Namespaces with no default ServiceAccount entry in $index:"
  printf '%s\n' "$missing" | sed 's/^/  - /'
  status=1
fi

stale="$(comm -13 "$work/declared" "$work/covered")"
if [ -n "$stale" ]; then
  echo "Entries in $index with no matching namespace manifest:"
  printf '%s\n' "$stale" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Default ServiceAccount list is in sync."
fi
exit "$status"
