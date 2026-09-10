#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is not on PATH; enter the dev shell or install it" >&2
  exit 1
fi

sources_dir=kubernetes/clusters/home/sources
index="$sources_dir/kustomization.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0

find "$sources_dir/helm" -name '*.yaml' -exec basename {} \; | sed 's|^|helm/|' | sort > "$work/present"
yq -N '.resources[]' "$index" | grep '^helm/' | sort > "$work/listed"

missing="$(comm -23 "$work/present" "$work/listed")"
if [ -n "$missing" ]; then
  echo "Source files not listed in $index, so Flux never creates them:"
  printf '%s\n' "$missing" | sed 's/^/  - /'
  status=1
fi

dangling="$(comm -13 "$work/present" "$work/listed")"
if [ -n "$dangling" ]; then
  echo "Entries in $index with no matching file:"
  printf '%s\n' "$dangling" | sed 's/^/  - /'
  status=1
fi

# A repository nothing pulls from is dead weight that still gets fetched on every interval.
find "$sources_dir/helm" -name '*.yaml' | sort > "$work/files"
while IFS= read -r file; do
  name="$(yq -N '.metadata.name' "$file" </dev/null)"
  if ! grep -rqF "name: $name" --include='*.yaml' kubernetes/apps kubernetes/infrastructure; then
    echo "HelmRepository $name is declared but no HelmRelease references it: $file"
    status=1
  fi
done < "$work/files"

if [ "$status" -eq 0 ]; then
  echo "Source index is in sync."
fi
exit "$status"
