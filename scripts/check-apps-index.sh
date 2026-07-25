#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

apps_dir=kubernetes/apps
index="$apps_dir/kustomization.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find "$apps_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort > "$work/present"
yq -N '.resources[]' "$index" | sort > "$work/listed"

status=0

missing="$(comm -23 "$work/present" "$work/listed")"
if [ -n "$missing" ]; then
  echo "App directories not listed in $index, so Flux never deploys them:"
  printf '%s\n' "$missing" | sed 's/^/  - /'
  status=1
fi

dangling="$(comm -13 "$work/present" "$work/listed")"
if [ -n "$dangling" ]; then
  echo "Entries in $index with no matching directory:"
  printf '%s\n' "$dangling" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "App index is in sync."
fi
exit "$status"
