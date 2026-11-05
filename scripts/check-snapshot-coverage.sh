#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

k8s_dir=kubernetes
gate_label="recurring-job.longhorn.io/source"
offsite_label="recurring-job.longhorn.io/offsite-backup"
disposable_class="longhorn-disposable"

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

while IFS= read -r file; do
  check_values "volumeClaimTemplates entry" "$file" \
    ".. | select(tag == \"!!map\") | select(has(\"volumeClaimTemplates\")) | .volumeClaimTemplates[] | (.metadata.labels[\"$gate_label\"] // \"missing\")"
done < <(grep -rl "volumeClaimTemplates:" --include="*.yaml" "$k8s_dir")

offsite_on_disposable=""
while IFS= read -r file; do
  if grep -q "$offsite_label" "$file"; then
    offsite_on_disposable="$offsite_on_disposable$file"$'\n'
  fi
done < <(grep -rl "$disposable_class" --include="*.yaml" "$k8s_dir" | grep -v "/storageclass-")

if [ -n "$offsite_on_disposable" ]; then
  echo "Files that use $disposable_class and carry the off-site backup label:"
  printf '%s' "$offsite_on_disposable" | sed 's/^/  - /'
  status=1
fi

if [ -n "$undeclared" ]; then
  echo "Declared volumes that do not state a recurring-job snapshot group (inclusion or exclusion):"
  printf '%s' "$undeclared" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "Every declared PVC and volumeClaimTemplate states its snapshot-group membership, and no disposable volume is backed up off-site."
fi
exit "$status"
