#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0

grep -rl 'kind: HelmRelease' kubernetes --include='*.yaml' \
  | xargs yq -N 'select(.kind == "HelmRelease" and .metadata.namespace != null) | .metadata.namespace' \
  | sort -u > "$work/present"

grep -rlE '^kind: Alert$' kubernetes --include='*.yaml' > "$work/alerts" || true
if [ ! -s "$work/alerts" ]; then
  echo "No Alert manifests found under kubernetes/." >&2
  exit 1
fi

xargs yq -N 'select(.kind == "Alert") | .spec.eventSources[] | select(.kind == "HelmRelease") | .namespace' \
  < "$work/alerts" | sort -u > "$work/listed"

compare_sets "$work/present" "$work/listed" \
  "Namespaces holding a HelmRelease that no Alert lists, so their events never reach ntfy:" \
  "Namespaces listed by an Alert that hold no HelmRelease:"

if [ "$status" -eq 0 ]; then
  echo "Alert namespaces are in sync."
fi
exit "$status"
