#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

sources_dir=kubernetes/clusters/home/sources
index="$sources_dir/kustomization.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0

# A repository nothing pulls from is dead weight that still gets fetched on every interval.
find "$sources_dir/helm" -name '*.yaml' | sort > "$work/files"
while IFS= read -r file; do
  name="$(yq -N '.metadata.name' "$file" </dev/null)"
  if ! grep -rqF "name: $name" --include='*.yaml' kubernetes/apps kubernetes/infrastructure; then
    echo "HelmRepository $name is declared but no HelmRelease references it: $file"
    status=1
  fi
done < "$work/files"

find "$sources_dir/helm" -name '*.yaml' -exec basename {} \; | sed 's|^|helm/|' | sort > "$work/present"
yq -N '.resources[]' "$index" | grep '^helm/' | sort > "$work/listed"

compare_sets "$work/present" "$work/listed" \
  "Source files not listed in $index, so Flux never creates them:" \
  "Entries in $index with no matching file:" \
  "Source index is in sync."
