#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools jq

script=scripts/backup-volumes.sh
label=recurring-job.longhorn.io/offsite-backup
paperless=paperless/paperless-ngx-data-encrypted
paperless_volume=pvc-11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa
webui=llm/open-webui-encrypted
webui_volume=pvc-22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb
postgres=postgres/postgres-1
postgres_volume=pvc-33333333-cccc-4ccc-8ccc-cccccccccccc

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

claim_json() {
  local namespace="${1%%/*}" name="${1#*/}" volume="$2" labelled="$3"
  jq -n --arg namespace "$namespace" --arg name "$name" --arg volume "$volume" --arg label "$label" --argjson labelled "$labelled" '
    {metadata: {namespace: $namespace, name: $name, labels: (if $labelled then {($label): "enabled"} else {} end)},
     spec: {volumeName: $volume}}'
}
{
  claim_json "$paperless" "$paperless_volume" true
  claim_json "$webui" "$webui_volume" true
  claim_json "$postgres" "$postgres_volume" false
} | jq -s . > "$work/claims"

cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in
  "create -f - -o jsonpath={.metadata.name}")
    manifest="$(cat)"
    printf '%s\n' "$manifest" >> "$FAKE_CREATED"
    name="$(printf '%s\n' "$manifest" | sed -n 's/^  name: //p')"
    [ -n "$name" ] || name="$(printf '%s\n' "$manifest" | sed -n 's/^  generateName: //p')generated"
    kind="$(printf '%s\n' "$manifest" | sed -n 's/^kind: //p')"
    printf '%s\n' "$manifest" > "$FAKE_CREATED_DIR/$(ls "$FAKE_CREATED_DIR" | wc -l | tr -d ' ')-$kind-$name"
    printf '%s' "$name" ;;
  "get pvc -A -l recurring-job.longhorn.io/offsite-backup=enabled -o json")
    jq --arg label "recurring-job.longhorn.io/offsite-backup" '{items: [.[] | select(.metadata.labels[$label] == "enabled")]}' "$FAKE_CLAIMS" ;;
  "get pvc "*" -n "*" -o json")
    jq -e --arg name "$3" --arg namespace "$5" '.[] | select(.metadata.name == $name and .metadata.namespace == $namespace)' "$FAKE_CLAIMS" \
      || { echo "persistentvolumeclaims \"$3\" not found" >&2; exit 1; } ;;
  "get pv "*" -o json")
    driver=driver.longhorn.io
    [ "$3" != "$FAKE_NON_LONGHORN" ] || driver=nfs.csi.k8s.io
    printf '{"spec":{"csi":{"driver":"%s","volumeHandle":"%s"}}}\n' "$driver" "$3" ;;
  "get backups.longhorn.io "*"-o name"*)
    [ "$3" != "$FAKE_EXISTING_BACKUP" ] || echo "backup.longhorn.io/$3" ;;
  "get snapshots.longhorn.io "*)
    echo true ;;
  "get backups.longhorn.io "*"-o jsonpath"*)
    if [ -n "$FAKE_STUCK" ]; then echo InProgress
    elif [ "$3" = "$FAKE_FAILED_BACKUP" ]; then echo Error
    else echo Completed; fi ;;
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
  : > "$work/created"
  rm -rf "$work/created.d" && mkdir "$work/created.d"
  FAKE_LOG="$work/log" FAKE_CREATED="$work/created" FAKE_CREATED_DIR="$work/created.d" FAKE_CLAIMS="${FAKE_CLAIMS:-$work/claims}" \
    PATH="$work/bin:$PATH" bash "$script" "$@" > "$work/output" 2>&1
}

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -q '^kubectl create' "$work/log"; then fail "$reason still created a resource"; fi
}

created_count() {
  grep -c "^kind: $1$" "$work/created" || true
}

run name=pre-rebuild "" || { cat "$work/output" >&2; fail "a named backup of every labelled claim failed"; }
grep -q -- '--context' "$work/log" && fail "kubectl was pinned to a context"
grep -E '^kubectl (apply|delete|patch|edit|label|annotate|scale|replace)' "$work/log" && fail "the backup changed more than it created"
[ "$(created_count Snapshot)" -eq 2 ] && [ "$(created_count Backup)" -eq 2 ] || fail "the backup did not create one Snapshot and one Backup per labelled claim: $(cat "$work/created")"
grep -q "$postgres_volume" "$work/created" && fail "the backup touched the unlabelled Postgres volume"
for volume in "$paperless_volume" "$webui_volume"; do
  id="${volume#pvc-}"
  name="pre-rebuild-${id:0:8}"
  snapshot=("$work"/created.d/*-Snapshot-"$name")
  backup=("$work"/created.d/*-Backup-"$name")
  [ -f "${snapshot[0]}" ] && [ -f "${backup[0]}" ] || fail "no Snapshot and Backup named $name: $(ls "$work/created.d")"
  [ "${snapshot[0]##*/}" \< "${backup[0]##*/}" ] || fail "the Backup $name was created before its Snapshot"
  grep -qx "  volume: $volume" "${snapshot[0]}" || fail "the Snapshot $name does not name volume $volume"
  grep -qx "  createSnapshot: true" "${snapshot[0]}" || fail "the Snapshot $name does not ask for a new snapshot"
  grep -qx "    backup-volume: $volume" "${backup[0]}" || fail "the Backup $name does not name volume $volume"
  grep -qx "  snapshotName: $name" "${backup[0]}" || fail "the Backup $name does not name snapshot $name"
done
grep -q "^$paperless $paperless_volume pre-rebuild-11111111$" "$work/output" || fail "the summary lacks the Paperless line: $(cat "$work/output")"
grep -q "^$webui $webui_volume pre-rebuild-22222222$" "$work/output" || fail "the summary lacks the Open WebUI line: $(cat "$work/output")"

run "$paperless" || { cat "$work/output" >&2; fail "a backup of one named claim failed"; }
[ "$(created_count Backup)" -eq 1 ] || fail "a named target created other than one Backup"
grep -q "generateName: backup-" "$work/created" || fail "an unnamed backup does not leave the name to the cluster"
grep -q "^$paperless $paperless_volume backup-generated$" "$work/output" || fail "the summary lacks the generated backup name: $(cat "$work/output")"

run "$paperless" pre-rebuild || { cat "$work/output" >&2; fail "a named claim with a positional name failed"; }
grep -q "^$paperless $paperless_volume pre-rebuild-11111111$" "$work/output" || fail "a positional name was not used"

run "$paperless" name=pre-rebuild || { cat "$work/output" >&2; fail "a named claim with name= failed"; }
grep -q "^$paperless $paperless_volume pre-rebuild-11111111$" "$work/output" || fail "name= after a target was not used"

for bad in paperless "/claim" "paperless/" "Paperless/claim" "paperless/claim/x" "paperless/-claim"; do
  refused "the target '$bad'" "$bad"
done
refused "the backup name 'Bad_Name'" "$paperless" Bad_Name
refused "the backup name 'name=Bad_Name'" name=Bad_Name ""
refused "too many arguments" "$paperless" pre-rebuild extra
refused "a named target without the offsite label" "$postgres"
grep -q "$label" "$work/output" || fail "the refusal of an unlabelled claim does not name the label"
refused "a claim that does not exist" paperless/missing
FAKE_NON_LONGHORN="$webui_volume" refused "a labelled claim on a non-Longhorn PV" "" pre-rebuild
FAKE_NON_LONGHORN="$paperless_volume" refused "a named claim on a non-Longhorn PV" "$paperless"
claim_json "$paperless" "" true | jq -s . > "$work/unbound"
FAKE_CLAIMS="$work/unbound" refused "an unbound claim" "$paperless"
echo '[]' > "$work/none"
FAKE_CLAIMS="$work/none" refused "a cluster without labelled claims" ""
FAKE_EXISTING_BACKUP=pre-rebuild-22222222 refused "an existing backup name" "" pre-rebuild
grep -q pre-rebuild-22222222 "$work/output" || fail "the refusal does not name the existing backup"

if FAKE_FAILED_BACKUP=pre-rebuild-11111111 run "" pre-rebuild; then fail "a failed backup exited zero"; fi
grep -q "^$paperless $paperless_volume FAILED" "$work/output" || fail "the failed volume has no failure line: $(cat "$work/output")"
grep -q "^$webui $webui_volume pre-rebuild-22222222$" "$work/output" || fail "a failed backup stopped the remaining volumes"
grep -q '^sleep ' "$work/log" && fail "a failed backup waited for the timeout"

if FAKE_STUCK=1 run "$paperless" pre-rebuild; then fail "a backup that never completed succeeded"; fi
grep -q "^$paperless $paperless_volume FAILED" "$work/output" || fail "the timeout has no failure line: $(cat "$work/output")"
grep -q '^sleep ' "$work/log" || fail "the backup wait did not poll"

echo "backup-volumes refuses every unsafe start, backs up exactly the labelled claims and reports each volume."
