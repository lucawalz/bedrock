#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

alert=kubernetes/infrastructure/configs/notifications/alert.yaml

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0

grep -rl 'kind: HelmRelease' kubernetes --include='*.yaml' \
  | xargs yq -N 'select(.kind == "HelmRelease" and .metadata.namespace != null) | .metadata.namespace' \
  | sort -u > "$work/present"

yq -N '.spec.eventSources[] | select(.kind == "HelmRelease") | .namespace' "$alert" | sort -u > "$work/listed"

compare_sets "$work/present" "$work/listed" \
  "Namespaces holding a HelmRelease that $alert does not list, so their events never reach ntfy:" \
  "Namespaces listed in $alert that hold no HelmRelease:"

if [ "$status" -eq 0 ]; then
  echo "Alert namespaces are in sync."
fi
exit "$status"
