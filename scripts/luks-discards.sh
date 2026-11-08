#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: luks-discards.sh <namespace>/<pvc>"

LONGHORN_NAMESPACE=longhorn-system
LONGHORN_DRIVER=driver.longhorn.io
KEY_FIELD=CRYPTO_KEY_VALUE
LUKS_TYPE=LUKS2
ATTACHED_STATE=attached
NAME_PATTERN='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || { echo "$usage" >&2; exit 2; }
target="$1"
[[ "$target" == */* ]] || { echo "$usage" >&2; exit 2; }
namespace="${target%%/*}"
pvc="${target#*/}"
[[ "$namespace" =~ $NAME_PATTERN && "$pvc" =~ $NAME_PATTERN ]] || { echo "$usage" >&2; exit 2; }

require_tools kubectl ssh

pv="$(kubectl get pvc "$pvc" -n "$namespace" -o jsonpath='{.spec.volumeName}')"
[ -n "$pv" ] || fail "pvc $target is not bound to a volume"

pv_field() {
  kubectl get pv "$pv" -o jsonpath="{$1}"
}

[ "$(pv_field .spec.csi.driver)" = "$LONGHORN_DRIVER" ] || fail "pv $pv is not a Longhorn volume"
volume="$(pv_field .spec.csi.volumeHandle)"
key_secret="$(pv_field .spec.csi.nodeStageSecretRef.name)"
key_namespace="$(pv_field .spec.csi.nodeStageSecretRef.namespace)"
[ -n "$key_secret" ] && [ -n "$key_namespace" ] || fail "pv $pv has no encryption secret, so it is not LUKS"

volume_field() {
  kubectl get volumes.longhorn.io "$volume" -n "$LONGHORN_NAMESPACE" -o jsonpath="{$1}"
}

[ "$(volume_field .spec.encrypted)" = true ] || fail "Longhorn volume $volume is not encrypted"
[ "$(volume_field .status.state)" = "$ATTACHED_STATE" ] || fail "Longhorn volume $volume is not attached"
node="$(volume_field .status.currentNodeID)"
[[ "$volume" =~ $NAME_PATTERN && "$node" =~ $NAME_PATTERN ]] || fail "unexpected volume '$volume' or node '$node'"

on_node() {
  ssh -o BatchMode=yes "root@$node" "$@"
}

mapping="/dev/mapper/$volume"
status="$(on_node cryptsetup status "$volume")" || fail "$mapping is not open on $node"
grep -Eq "^[[:space:]]*type:[[:space:]]+$LUKS_TYPE$" <<< "$status" || fail "$mapping on $node is not $LUKS_TYPE"

has_discards() {
  grep -Eq '^[[:space:]]*flags:.*\bdiscards\b' <<< "$1"
}

if has_discards "$status"; then
  echo "$target: discards already enabled on $volume"
else
  kubectl get secret "$key_secret" -n "$key_namespace" -o go-template="{{index .data \"$KEY_FIELD\" | base64decode}}" \
    | on_node cryptsetup refresh --allow-discards --persistent --key-file=- "$volume"
  status="$(on_node cryptsetup status "$volume")"
  has_discards "$status" || fail "$mapping on $node still lacks discards after the refresh"
  echo "$target: discards enabled and stored in the $LUKS_TYPE header of $volume"
fi

mount_point="$(on_node findmnt -n -f -o TARGET --source "$mapping")" || fail "$mapping is not mounted on $node"
on_node fstrim -v "$mount_point"
