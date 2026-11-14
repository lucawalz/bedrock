#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: backup-volumes.sh [<namespace>/<claim>] [name=<prefix>]"

NAME_PATTERN='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'
OFFSITE_LABEL=recurring-job.longhorn.io/offsite-backup
OFFSITE_ENABLED=enabled
LONGHORN_DRIVER=driver.longhorn.io
VOLUME_PREFIX=pvc-
VOLUME_ID_LENGTH=8
BACKUP_COMPLETED=Completed
BACKUP_FAILED_STATES=(Error Unknown Deleting)
SNAPSHOT_TIMEOUT_SECONDS=600
BACKUP_TIMEOUT_SECONDS=3600
POLL_SECONDS=10
MAX_ARGUMENTS=2

usage_error() {
  echo "$usage" >&2
  exit 2
}

[ "$#" -le "$MAX_ARGUMENTS" ] || usage_error
target="${1:-}"
name="${2:-}"
if [[ "$target" == name=* && -z "$name" ]]; then
  name="$target"
  target=""
fi
name="${name#name=}"

[ -z "$name" ] || [[ "$name" =~ $NAME_PATTERN ]] || usage_error
if [ -n "$target" ]; then
  [[ "$target" == */* ]] || usage_error
  [[ "${target%%/*}" =~ $NAME_PATTERN && "${target#*/}" =~ $NAME_PATTERN ]] || usage_error
fi

require_tools kubectl jq

claim_query='["\(.metadata.namespace)/\(.metadata.name)", .spec.volumeName // "", .metadata.labels[$label] // ""] | join("|")'
if [ -n "$target" ]; then
  claims="$(kubectl get pvc "${target#*/}" -n "${target%%/*}" -o json | jq -r --arg label "$OFFSITE_LABEL" "$claim_query")"
else
  claims="$(kubectl get pvc -A -l "$OFFSITE_LABEL=$OFFSITE_ENABLED" -o json | jq -r --arg label "$OFFSITE_LABEL" ".items[] | $claim_query")"
fi
[ -n "$claims" ] || fail "no claim carries $OFFSITE_LABEL=$OFFSITE_ENABLED"

plan=()
while IFS='|' read -r claim pv offsite; do
  [ "$offsite" = "$OFFSITE_ENABLED" ] || fail "$claim lacks $OFFSITE_LABEL=$OFFSITE_ENABLED, so it is not backed up off-site"
  [ -n "$pv" ] || fail "$claim is not bound to a PersistentVolume"
  read -r driver volume < <(kubectl get pv "$pv" -o json | jq -r '"\(.spec.csi.driver // "") \(.spec.csi.volumeHandle // "")"')
  [ "$driver" = "$LONGHORN_DRIVER" ] && [ -n "$volume" ] || fail "$claim is not bound to a Longhorn CSI volume"
  backup=""
  if [ -n "$name" ]; then
    id="${volume#"$VOLUME_PREFIX"}"
    backup="$name-${id:0:$VOLUME_ID_LENGTH}"
    for kind in backups.longhorn.io snapshots.longhorn.io; do
      found="$(kubectl get "$kind" "$backup" -n "$LONGHORN_NAMESPACE" -o name --ignore-not-found)"
      [ -z "$found" ] || fail "$found already exists"
    done
  fi
  plan+=("$claim $volume $backup")
done <<< "$claims"

object_name() {
  if [ -n "$2" ]; then echo "name: $2"; else echo "generateName: $1-"; fi
}

create() {
  kubectl create -f - -o jsonpath='{.metadata.name}'
}

snapshot_ready() {
  [ "$(kubectl get snapshots.longhorn.io "$1" -n "$LONGHORN_NAMESPACE" -o jsonpath='{.status.readyToUse}')" = true ]
}

backup_completed() {
  local state
  state="$(kubectl get backups.longhorn.io "$1" -n "$LONGHORN_NAMESPACE" -o jsonpath='{.status.state}')" || return 1
  [[ " ${BACKUP_FAILED_STATES[*]} " != *" $state "* ]] || fail "backup $1 is $state"
  [ "$state" = "$BACKUP_COMPLETED" ]
}

backup_volume() {
  local volume="$1" requested="$2" snapshot backup
  snapshot="$(create <<MANIFEST
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  $(object_name snapshot "$requested")
  namespace: ${LONGHORN_NAMESPACE}
spec:
  volume: ${volume}
  createSnapshot: true
MANIFEST
)" || fail "the Snapshot of $volume was not created"
  wait_until "$SNAPSHOT_TIMEOUT_SECONDS" "$POLL_SECONDS" "snapshot $snapshot of $volume becoming ready" snapshot_ready "$snapshot"
  backup="$(create <<MANIFEST
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  $(object_name backup "$requested")
  namespace: ${LONGHORN_NAMESPACE}
  labels:
    backup-volume: ${volume}
spec:
  snapshotName: ${snapshot}
MANIFEST
)" || fail "the Backup of $volume was not created"
  wait_until "$BACKUP_TIMEOUT_SECONDS" "$POLL_SECONDS" "backup $backup of $volume completing" backup_completed "$backup"
  echo "$backup"
}

failed=0
for entry in "${plan[@]}"; do
  read -r claim volume requested <<< "$entry"
  if backup="$(backup_volume "$volume" "$requested")"; then
    echo "$claim $volume $backup"
  else
    echo "$claim $volume FAILED"
    failed=1
  fi
done
exit "$failed"
