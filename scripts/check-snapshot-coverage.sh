#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

k8s_dir=kubernetes
gate_label="recurring-job.longhorn.io/source"

status=0
undeclared=""

check_values() {
  local kind="$1" file="$2" query="$3"
  local values
  values="$(yq -N "$query" "$file")"
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    if [ "$value" != "enabled" ]; then
      undeclared="$undeclared$kind in $file"$'\n'
    fi
  done <<< "$values"
}

while IFS= read -r file; do
  check_values "PersistentVolumeClaim" "$file" \
    "select(.kind == \"PersistentVolumeClaim\") | (.metadata.labels[\"$gate_label\"] // \"missing\")"
done < <(grep -rl "kind: PersistentVolumeClaim" --include="*.yaml" "$k8s_dir")

while IFS= read -r file; do
  check_values "volumeClaimTemplate" "$file" \
    ".. | select(tag == \"!!map\") | select(has(\"volumeClaimTemplate\")) | (.volumeClaimTemplate.metadata.labels[\"$gate_label\"] // \"missing\")"
done < <(grep -rl "volumeClaimTemplate:" --include="*.yaml" "$k8s_dir")

if [ -n "$undeclared" ]; then
  echo "Declared volumes that do not state a recurring-job snapshot group (inclusion or exclusion):"
  printf '%s' "$undeclared" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Every declared PVC and volumeClaimTemplate states its snapshot-group membership."
fi
exit "$status"
