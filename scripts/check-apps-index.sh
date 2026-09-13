#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

apps_dir=kubernetes/apps
index="$apps_dir/kustomization.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find "$apps_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort > "$work/present"
yq -N '.resources[]' "$index" | sed 's|/ks\.yaml$||' | sort > "$work/listed"

status=0

compare_sets "$work/present" "$work/listed" \
  "App directories not listed in $index, so Flux never deploys them:" \
  "Entries in $index with no matching directory:" \
  "App index is in sync."
