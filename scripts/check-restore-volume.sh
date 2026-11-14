#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools jq

script=scripts/restore-volume.sh
target=paperless/paperless-ngx-data-encrypted
claim=paperless-ngx-data-encrypted
backup="backup-0123456789abcdef"
backup_url="s3://bedrock-longhorn@auto/?backup=$backup&volume=pvc-0"
size=5368709120
replicas=3

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in
  "apply -f -")
    manifest="$(cat)"
    printf '%s\n' "$manifest" >> "$FAKE_APPLIED"
    case "$manifest" in *"kind: PersistentVolume"*) echo applied-pv >> "$FAKE_LOG" ;; esac ;;
  "get backups.longhorn.io "*)
    [ -n "$FAKE_BACKUP_MISSING" ] || printf '{"status":{"state":"%s","url":"%s","volumeSize":"%s","labels":{"volume-encrypted":"%s","longhorn.io/volume-access-mode":"%s"}}}\n' \
      "${FAKE_STATE:-Completed}" "$FAKE_BACKUP_URL" "$FAKE_SIZE" "${FAKE_ENCRYPTED:-enabled}" "${FAKE_ACCESS_MODE:-rwo}" ;;
  "get secret "*) [ -z "$FAKE_SECRET_MISSING" ] || exit 1; echo "secret/$3" ;;
  "get pvc "*) [ "$FAKE_EXISTING" != pvc ] || echo "persistentvolumeclaim/$3" ;;
  "get pv "*) [ "$FAKE_EXISTING" != pv ] || echo "persistentvolume/$3" ;;
  "get volumes.longhorn.io "*"-o name"*) [ "$FAKE_EXISTING" != volume ] || echo "volume.longhorn.io/$3" ;;
  "get volumes.longhorn.io "*"-o jsonpath"*)
    case "$*" in
      *restoreInitiated*) if [ -n "$FAKE_STUCK" ]; then echo "true true attached"; else echo "true false detached"; fi ;;
      *robustness*) if [ -n "$FAKE_FAULTED" ]; then echo faulted; else echo unknown; fi ;;
    esac ;;
  "get kustomizations.kustomize.toolkit.fluxcd.io "*)
    inventory='{"id":"paperless_paperless-ngx-data-encrypted__PersistentVolumeClaim"}'
    printf '{"items":[{"metadata":{"name":"paperless"},"spec":{"suspend":%s},"status":{"inventory":{"entries":[%s]}}},{"metadata":{"name":"llm"},"spec":{"suspend":true},"status":{"inventory":{"entries":[%s]}}}]}\n' \
      "${FAKE_SUSPENDED:-true}" "${FAKE_INVENTORY-$inventory}" "${FAKE_SECOND_OWNER:+$inventory}" ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
FAKE
cat > "$work/bin/sleep" <<'FAKE'
#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
FAKE
chmod +x "$work"/bin/*

run() {
  : > "$work/log"
  : > "$work/applied"
  FAKE_LOG="$work/log" FAKE_APPLIED="$work/applied" FAKE_BACKUP_URL="$backup_url" FAKE_SIZE="$size" \
    PATH="$work/bin:$PATH" bash "$script" "$@" > "$work/output" 2>&1
}

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -q '^kubectl apply' "$work/log"; then fail "$reason still applied a manifest"; fi
}

manifest_has() {
  grep -qF -- "$1" "$work/applied" || fail "the applied manifests lack '$1': $(cat "$work/applied")"
}

run "$target" "$backup" || { cat "$work/output" >&2; fail "a valid restore failed"; }
grep -q -- '--context' "$work/log" && fail "kubectl was pinned to a context"
manifest_has "kind: Volume"
manifest_has "name: $claim"
manifest_has "fromBackup: \"$backup_url\""
manifest_has "size: \"$size\""
manifest_has "numberOfReplicas: $replicas"
manifest_has "encrypted: true"
manifest_has "kind: PersistentVolume"
manifest_has "storage: \"$size\""
manifest_has "- ReadWriteOnce"
manifest_has "persistentVolumeReclaimPolicy: Retain"
manifest_has "storageClassName: longhorn-encrypted"
manifest_has "volumeHandle: $claim"
[ "$(grep -A3 'claimRef:' "$work/applied" | tr -d ' ' | tr '\n' ' ')" = "claimRef: namespace:paperless name:$claim csi: " ] \
  || fail "the PV claimRef does not name $target"
[ "$(grep -A1 -e 'nodeStageSecretRef:' -e 'nodePublishSecretRef:' "$work/applied" | grep -c 'name: longhorn-crypto$')" -eq 2 ] \
  || fail "the PV does not name longhorn-crypto in both secret refs"
grep -q 'flux resume kustomization paperless -n flux-system' "$work/output" || fail "the next steps do not resume the owning Kustomization"
grep -q "just luks-discards $target" "$work/output" || fail "the next steps do not mention luks-discards"
grep -q 'resume' "$work/log" && fail "the restore resumed the Kustomization itself"

run "$target" "$backup" longhorn-crypto-legacy || { cat "$work/output" >&2; fail "a restore with the legacy key failed"; }
[ "$(grep -A1 -e 'nodeStageSecretRef:' -e 'nodePublishSecretRef:' "$work/applied" | grep -c 'name: longhorn-crypto-legacy$')" -eq 2 ] \
  || fail "the PV does not name longhorn-crypto-legacy in both secret refs"

FAKE_INVENTORY="" run "$target" "$backup" longhorn-crypto paperless \
  || { cat "$work/output" >&2; fail "a restore naming a suspended Kustomization without an inventory failed"; }
grep -q 'flux resume kustomization paperless -n flux-system' "$work/output" || fail "the next steps do not resume the named Kustomization"

FAKE_INVENTORY="" run "$target" "$backup" kustomization=paperless "" \
  || { cat "$work/output" >&2; fail "a restore with kustomization= in the key position, as just passes it, failed"; }
[ "$(grep -A1 'nodeStageSecretRef:' "$work/applied" | grep -c 'name: longhorn-crypto$')" -eq 1 ] \
  || fail "kustomization= in the key position did not keep the default key"

for bad in paperless "/claim" "paperless/" "Paperless/claim" "paperless/claim/x" "paperless/-claim"; do
  refused "the target '$bad'" "$bad" "$backup"
done
refused "the backup name 'Bad_Name'" "$target" Bad_Name
refused "an unknown key" "$target" "$backup" longhorn-crypto-other
refused "the Kustomization name 'Bad_Name'" "$target" "$backup" longhorn-crypto Bad_Name
refused "a missing argument" "$target"
FAKE_SUSPENDED=false refused "an owning Kustomization that is not suspended" "$target" "$backup"
FAKE_INVENTORY="" refused "a claim no Kustomization owns, without kustomization=" "$target" "$backup"
grep -q 'kustomization=' "$work/output" || fail "the refusal without an owner does not mention kustomization="
FAKE_SUSPENDED=false FAKE_INVENTORY="" refused "a named Kustomization that is not suspended" "$target" "$backup" longhorn-crypto paperless
FAKE_INVENTORY="" refused "a named Kustomization that does not exist" "$target" "$backup" longhorn-crypto apps
refused "a named Kustomization other than the owner" "$target" "$backup" longhorn-crypto llm
FAKE_EXISTING=pvc refused "an existing PVC" "$target" "$backup"
FAKE_EXISTING=pv refused "an existing PV" "$target" "$backup"
FAKE_EXISTING=volume refused "an existing Longhorn Volume" "$target" "$backup"
FAKE_SECOND_OWNER=1 refused "a claim two Kustomizations list" "$target" "$backup"
FAKE_STATE=InProgress refused "a backup that is not Completed" "$target" "$backup"
FAKE_ACCESS_MODE=rwz refused "a backup with an unknown access mode" "$target" "$backup"
FAKE_ENCRYPTED=disabled refused "a backup of an unencrypted volume" "$target" "$backup"
FAKE_BACKUP_MISSING=1 refused "a missing backup" "$target" "$backup"
FAKE_SECRET_MISSING=1 refused "a missing key Secret" "$target" "$backup"

if FAKE_FAULTED=1 run "$target" "$backup"; then fail "a faulted restore succeeded"; fi
grep -q '^applied-pv' "$work/log" && fail "the faulted restore created the PV"
grep -q 'left for inspection' "$work/output" || fail "the faulted restore does not say the Volume was left for inspection"

if FAKE_STUCK=1 run "$target" "$backup"; then fail "a restore that never finished succeeded"; fi
grep -q 'kind: Volume' "$work/applied" || fail "the stuck restore did not create the Volume"
grep -q '^applied-pv' "$work/log" && fail "the stuck restore created the PV"
grep -q 'left for inspection' "$work/output" || fail "the timeout does not say the Volume was left for inspection"
grep -q '^sleep ' "$work/log" || fail "the restore wait did not poll"

echo "restore-volume refuses every unsafe start, restores an encrypted backup and binds it to the claim with the chosen key."
