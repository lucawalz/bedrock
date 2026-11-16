#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools nix jq

HOST_COUNT=4

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export BEDROCK_KNOWN_HOSTS_FILE="$work/known_hosts.d/bedrock"
real_nix="$(command -v nix)"

stub_secret_keys() {
  cat > "$work/bin/nix" <<FAKE
#!/bin/sh
case "\$*" in
  *secrets.nix*) echo '{"a.age":{"publicKeys":[$1]}}' ;;
  *) exec "$real_nix" "\$@" ;;
esac
FAKE
  chmod +x "$work/bin/nix"
}

refuses_and_keeps_file() {
  echo keep > "$BEDROCK_KNOWN_HOSTS_FILE"
  if PATH="$work/bin:$PATH" bash scripts/known-hosts.sh > /dev/null 2> "$work/err"; then
    fail "$1 was accepted"
  fi
  grep -q "$2" "$work/err" || fail "failure does not say: $2"
  [ "$(cat "$BEDROCK_KNOWN_HOSTS_FILE")" = keep ] || fail "failed run touched the existing file"
}

bash scripts/known-hosts.sh > /dev/null || fail "known-hosts failed on the repo data"
grep -qx "control-plane-1,10.20.0.10,control-plane-1.tail26ab10.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICqxm9zCib4DwlpLDftuxjS/hVmmy7vMnQ46MKJEmA2j" "$BEDROCK_KNOWN_HOSTS_FILE" \
  || fail "control-plane-1 line missing or wrong"
grep -qx "worker-1,10.20.0.11,worker-1.tail26ab10.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7xowdEtDWgOBx/m1nuZ2NVzfPkXESvzMysGWUeaaNV" "$BEDROCK_KNOWN_HOSTS_FILE" \
  || fail "worker-1 line missing or wrong"
grep -qx "router,10.20.0.1,router.tail26ab10.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHnDz824ffxsJJiJRnNuPhSZhxxt69uVLcBwuZxL+V08" "$BEDROCK_KNOWN_HOSTS_FILE" \
  || fail "router line missing or wrong"
[ "$(wc -l < "$BEDROCK_KNOWN_HOSTS_FILE")" -eq "$HOST_COUNT" ] || fail "expected one line per host"

echo stale > "$BEDROCK_KNOWN_HOSTS_FILE"
bash scripts/known-hosts.sh > /dev/null
! grep -q stale "$BEDROCK_KNOWN_HOSTS_FILE" || fail "existing file was not fully replaced"
[ "$(find "$work/known_hosts.d" -type f | wc -l)" -eq 1 ] || fail "temp file left behind"

mkdir "$work/bin"
stub_secret_keys '"ssh-ed25519 AAAAkey root@control-plane-1"'
refuses_and_keeps_file "a missing key" "no host key for worker-1"

stub_secret_keys '"ssh-ed25519 AAAAone root@control-plane-1","ssh-ed25519 AAAAtwo root@control-plane-1"'
refuses_and_keeps_file "two keys for one host" "more than one host key for control-plane-1"

echo "OK: known-hosts writes pinned lines atomically and refuses a missing or ambiguous key"
