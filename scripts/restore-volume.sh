#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: restore-volume.sh <namespace>/<claim> <backup> [longhorn-crypto|longhorn-crypto-legacy] [kustomization=<name>]"

NAME_PATTERN='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'
SIZE_PATTERN='^[0-9]+$'
KEY_SECRETS=(longhorn-crypto longhorn-crypto-legacy)
DEFAULT_KEY_SECRET="${KEY_SECRETS[0]}"
FLUX_NAMESPACE=flux-system
STORAGE_CLASS=longhorn-encrypted
REPLICAS=3
BACKUP_COMPLETED=Completed
BACKUP_ENCRYPTED=enabled
FAULTED=faulted
RESTORE_TIMEOUT_SECONDS=1800
POLL_SECONDS=10
MIN_ARGUMENTS=2
MAX_ARGUMENTS=4

usage_error() {
  echo "$usage" >&2
  exit 2
}

[ "$#" -ge "$MIN_ARGUMENTS" ] && [ "$#" -le "$MAX_ARGUMENTS" ] || usage_error
target="$1"
backup="$2"
key="${3:-$DEFAULT_KEY_SECRET}"
kustomization="${4:-}"
if [[ "$key" == kustomization=* && -z "$kustomization" ]]; then
  kustomization="$key"
  key="$DEFAULT_KEY_SECRET"
fi
kustomization="${kustomization#kustomization=}"

[[ "$target" == */* ]] || usage_error
namespace="${target%%/*}"
claim="${target#*/}"
[[ "$namespace" =~ $NAME_PATTERN && "$claim" =~ $NAME_PATTERN && "$backup" =~ $NAME_PATTERN ]] || usage_error
[[ " ${KEY_SECRETS[*]} " == *" $key "* ]] || fail "key '$key' is not one of ${KEY_SECRETS[*]}"
[ -z "$kustomization" ] || [[ "$kustomization" =~ $NAME_PATTERN ]] || usage_error

require_tools kubectl jq

backup_json="$(kubectl get backups.longhorn.io "$backup" -n "$LONGHORN_NAMESPACE" -o json --ignore-not-found)"
[ -n "$backup_json" ] || fail "backup $backup does not exist in $LONGHORN_NAMESPACE"
IFS='|' read -r state url size encrypted access_mode < <(jq -r '.status | [.state, .url, .volumeSize,
  .labels["volume-encrypted"], .labels["longhorn.io/volume-access-mode"]] | map(. // "") | join("|")' <<< "$backup_json")
[ "$state" = "$BACKUP_COMPLETED" ] || fail "backup $backup is '$state', not $BACKUP_COMPLETED"
[ "$encrypted" = "$BACKUP_ENCRYPTED" ] || fail "backup $backup is not from an encrypted volume"
[ -n "$url" ] && [[ "$size" =~ $SIZE_PATTERN ]] || fail "backup $backup has no URL or volume size"
case "$access_mode" in
  rwo) pv_access_mode=ReadWriteOnce ;;
  rwx) pv_access_mode=ReadWriteMany ;;
  *) fail "backup $backup records an unknown access mode '$access_mode'" ;;
esac

kubectl get secret "$key" -n "$LONGHORN_NAMESPACE" -o name >/dev/null || fail "Secret $LONGHORN_NAMESPACE/$key does not exist"

refuse_existing() {
  local found
  found="$(kubectl get "$@" -o name --ignore-not-found)"
  [ -z "$found" ] || fail "$found already exists"
}
refuse_existing pvc "$claim" -n "$namespace"
refuse_existing pv "$claim"
refuse_existing volumes.longhorn.io "$claim" -n "$LONGHORN_NAMESPACE"

candidates="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n "$FLUX_NAMESPACE" -o json \
  | jq -r --arg id "${namespace}_${claim}__PersistentVolumeClaim" --arg name "$kustomization" '
      [.items[] | select(any(.status.inventory.entries[]?; .id == $id))] as $owners
      | (if ($owners | length) > 0 then $owners else [.items[] | select(.metadata.name == $name)] end)[]
      | "\(.metadata.name) \(.spec.suspend // false)"')"
[[ "$candidates" != *$'\n'* ]] || fail "several Kustomizations list $target: $(cut -d' ' -f1 <<< "$candidates" | tr '\n' ' ')"
if [ -z "$candidates" ]; then
  [ -n "$kustomization" ] || fail "no Kustomization inventory lists $target; name the one that creates it with kustomization=<name>"
  fail "Kustomization $FLUX_NAMESPACE/$kustomization does not exist"
fi
read -r owner suspended <<< "$candidates"
[ -z "$kustomization" ] || [ "$kustomization" = "$owner" ] || fail "$target belongs to Kustomization $owner, not $kustomization"
[ "$suspended" = true ] || fail "Kustomization $owner is not suspended; run flux suspend kustomization $owner -n $FLUX_NAMESPACE first"

echo "restoring $backup into Longhorn Volume $claim"
longhorn_volume_manifest "$claim" "$url" "$size" "$REPLICAS" "$access_mode" | kubectl apply -f -
trap 'echo "Longhorn Volume $LONGHORN_NAMESPACE/$claim is left for inspection; delete it before a retry" >&2' EXIT
wait_until "$RESTORE_TIMEOUT_SECONDS" "$POLL_SECONDS" "the restore of $backup into $claim" longhorn_restore_finished "$claim"
[ "$(longhorn_volume_status "$claim" robustness)" != "$FAULTED" ] || fail "Longhorn Volume $claim restored $FAULTED"

kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${claim}
spec:
  capacity:
    storage: "${size}"
  accessModes:
    - ${pv_access_mode}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${STORAGE_CLASS}
  claimRef:
    namespace: ${namespace}
    name: ${claim}
  csi:
    driver: driver.longhorn.io
    volumeHandle: ${claim}
    fsType: ext4
    nodeStageSecretRef:
      name: ${key}
      namespace: ${LONGHORN_NAMESPACE}
    nodePublishSecretRef:
      name: ${key}
      namespace: ${LONGHORN_NAMESPACE}
MANIFEST
trap - EXIT

cat <<NEXT
PersistentVolume $claim is reserved for $target and opens with $key. Next:
  flux resume kustomization $owner -n $FLUX_NAMESPACE
  just luks-discards $target    (once the volume is attached)
NEXT
