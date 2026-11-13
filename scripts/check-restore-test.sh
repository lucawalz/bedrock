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
created="$(yq -n "(now | to_unix) - $FAKE_AGE_SECONDS | from_unix")"
printf '{"items":[{"metadata":{"name":"etcd-snapshot-control-plane-1-1"},"spec":{"s3":{"bucket":"bedrock-etcd","prefix":"etcd-snapshots"}},"status":{"readyToUse":true,"creationTime":"%s"}}]}\n' "$created"
FAKE
chmod +x "$work/bin/kubectl"

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

sed -n '/^dump_key_time() {$/,/^}$/p' "$script" > "$work/dump-key-time.sh"
[ -s "$work/dump-key-time.sh" ] || fail "$script defines no dump_key_time function"
[ "$(bash -c ". '$work/dump-key-time.sh'; dump_key_time 2026-11-11T033000Z.gpg")" = 2026-11-11T03:30:00Z ] \
  || fail "dump_key_time does not turn a dump key into an RFC 3339 time"

echo "restore-test --max-age fails a stale backup, keeps the drill limit and rejects malformed ages."
