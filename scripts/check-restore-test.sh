#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

script=scripts/restore-test.sh
seconds_per_hour=3600
fresh_seconds=$((1 * seconds_per_hour))
stale_seconds=$((3 * seconds_per_hour))
expired_seconds=$((14 * seconds_per_hour))

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
[ -z "$FAKE_LOG" ] || echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in
  "get etcdsnapshotfiles.k3s.cattle.io "*)
    created="$(yq -n "(now | to_unix) - $FAKE_AGE_SECONDS | from_unix")"
    printf '{"items":[{"metadata":{"name":"etcd-snapshot-control-plane-1-1"},"spec":{"s3":{"bucket":"bedrock-etcd","prefix":"etcd-snapshots"}},"status":{"readyToUse":true,"creationTime":"%s"}}]}\n' "$created" ;;
  "apply -f -") cat >> "$FAKE_APPLIED" ;;
  "get clusters.postgresql.cnpg.io postgres -n postgres -o json")
    printf '{"spec":{"externalClusters":[{"name":"archive","plugin":{"parameters":{"serverName":"postgres"}}}],"plugins":[{"name":"other","parameters":{"serverName":"postgres-other"}},{"name":"barman-cloud.cloudnative-pg.io","isWALArchiver":true,"parameters":{"barmanObjectName":"postgres-backup","serverName":"%s"}}]}}\n' "$FAKE_ARCHIVE_SERVER" ;;
  "get cluster.postgresql.cnpg.io postgres-restore-test -n postgres") exit 1 ;;
  "get cluster.postgresql.cnpg.io "*currentPrimary*) echo "$3-1" ;;
  "exec "*) echo 42 ;;
  "get deploy paperless-ngx "*claimName*) echo paperless-ngx-data-encrypted ;;
  "get deploy paperless-ngx "*image*) echo ghcr.io/paperless-ngx/paperless-ngx:1.0 ;;
  "get pvc paperless-ngx-data-encrypted "*) echo pvc-data ;;
  "get pv pvc-data "*nodePublishSecretRef*) echo "$FAKE_KEY_SECRET" ;;
  "get backups.longhorn.io "*)
    echo '{"items":[{"status":{"volumeName":"pvc-data","state":"Completed","url":"s3://bedrock-longhorn@auto/?backup=backup-0&volume=pvc-data","volumeSize":"5368709120","labels":{"volume-encrypted":"enabled"},"backupCreatedAt":"2026-11-14T00:00:00Z"}}]}' ;;
  "get volumes.longhorn.io restore-test -n longhorn-system") exit 1 ;;
  "get volumes.longhorn.io "*restoreInitiated*) echo "true false detached" ;;
  "get volumes.longhorn.io "*robustness*) echo healthy ;;
  "get volumes.longhorn.io "*state*) echo detached ;;
  "get pod restore-test-wrong-key "*) echo Pending ;;
  "get pod restore-test-key "*) echo Succeeded ;;
  "get events "*) echo "MountVolume.MountDevice failed: luksOpen failed" ;;
  "logs "*) echo "3 entries" ;;
  "wait "* | "delete "*) ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/bin/kubectl"

drill() {
  : > "$work/log"
  : > "$work/applied"
  FAKE_LOG="$work/log" FAKE_APPLIED="$work/applied" PATH="$work/bin:$PATH" bash "$script" "$1" > "$work/output" 2>&1
}

etcd() {
  local age="$1"
  shift
  FAKE_AGE_SECONDS="$age" PATH="$work/bin:$PATH" bash "$script" "$@" etcd > "$work/output" 2>&1
}

etcd "$fresh_seconds" || fail "a fresh snapshot failed without --max-age: $(cat "$work/output")"
etcd "$fresh_seconds" --max-age 2h || fail "a 1h old snapshot failed --max-age 2h: $(cat "$work/output")"
grep -q 'within --max-age 2h' "$work/output" || fail "a passing --max-age check printed no age"
etcd "$stale_seconds" || fail "a 3h old snapshot failed without --max-age"
if etcd "$stale_seconds" --max-age 2h; then fail "a 3h old snapshot passed --max-age 2h"; fi
grep -q 'older than --max-age 2h' "$work/output" || fail "a stale snapshot did not name --max-age: $(cat "$work/output")"
etcd "$stale_seconds" --max-age 180m || fail "a 3h old snapshot failed --max-age 180m"
if etcd "$stale_seconds" --max-age 10799s; then fail "a 3h old snapshot passed --max-age 10799s"; fi
if etcd "$expired_seconds" --max-age 1d; then fail "a 14h old snapshot passed the 13h drill limit under --max-age 1d"; fi

for bad in "" 2 2w -2h h; do
  code=0
  FAKE_AGE_SECONDS="$fresh_seconds" PATH="$work/bin:$PATH" bash "$script" --max-age ${bad:+"$bad"} etcd > /dev/null 2>&1 || code=$?
  [ "$code" -eq 2 ] || fail "--max-age '$bad' exited $code instead of the usage error"
done

FAKE_ARCHIVE_SERVER=postgres-2027-01 drill postgres || fail "a postgres drill failed: $(cat "$work/output")"
grep -q 'serverName: postgres-2027-01$' "$work/applied" || fail "the restore cluster does not read the WAL archiver's serverName: $(cat "$work/applied")"
if FAKE_ARCHIVE_SERVER="" drill postgres; then fail "a postgres drill without an archive server passed"; fi
grep -q 'isWALArchiver' "$work/output" || fail "the missing archive server refusal does not name the WAL archiver: $(cat "$work/output")"
grep -q '^kubectl apply' "$work/log" && fail "a postgres drill without an archive server applied a manifest"

FAKE_KEY_SECRET=longhorn-crypto-legacy drill longhorn || fail "a longhorn drill failed: $(cat "$work/output")"
[ "$(grep -A1 'nodeStageSecretRef:' "$work/applied" | grep -c 'name: longhorn-crypto-legacy$')" -eq 1 ] \
  || fail "the key attempt does not use the claim's PV key: $(cat "$work/applied")"
grep -q 'unlocks with longhorn-crypto-legacy' "$work/output" || fail "the longhorn drill does not name the claim's key"
if FAKE_KEY_SECRET="" drill longhorn; then fail "a longhorn drill on a PV without a key Secret passed"; fi
grep -q 'pvc-data' "$work/output" || fail "the missing key refusal does not name the PV: $(cat "$work/output")"
grep -q '^kubectl apply' "$work/log" && fail "a longhorn drill without a key Secret applied a manifest"

sed -n '/^dump_key_time() {$/,/^}$/p' "$script" > "$work/dump-key-time.sh"
[ -s "$work/dump-key-time.sh" ] || fail "$script defines no dump_key_time function"
[ "$(bash -c ". '$work/dump-key-time.sh'; dump_key_time 2026-11-11T033000Z.gpg")" = 2026-11-11T03:30:00Z ] \
  || fail "dump_key_time does not turn a dump key into an RFC 3339 time"

echo "restore-test --max-age fails a stale backup, keeps the drill limit and rejects malformed ages; the drills read the archive server and key from the cluster."
