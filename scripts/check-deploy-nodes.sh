#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

script=scripts/deploy-nodes.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat > "$work/bin/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >> "$FAKE_LOG"
FAKE
cat > "$work/bin/nix" <<'FAKE'
#!/bin/sh
echo "nix $*" >> "$FAKE_LOG"
[ -z "$NIX_SSHOPTS" ] || echo "NIX_SSHOPTS=$NIX_SSHOPTS" >> "$FAKE_LOG"
case "$*" in *"$FAKE_FAIL_ON"*) exit 1 ;; esac
FAKE
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in *volumes.longhorn.io*) printf 'vol-a|%s\nvol-b|detached|unknown\n' "$FAKE_VOLUME" ;; esac
FAKE

cat > "$work/bin/dig" <<'FAKE'
#!/bin/sh
echo "dig $*" >> "$FAKE_LOG"
[ -n "$FAKE_DNS_EMPTY" ] || echo 10.20.0.50
FAKE

chmod +x "$work"/bin/*

dry="$(FAKE_LOG=/dev/null PATH="$work/bin:$PATH" bash "$script" --dry-run 2>&1)" || fail "dry run failed"
[ "$(printf '%s\n' "$dry" | grep '^+ rebuild' | cut -d' ' -f2,3)" = $'rebuild worker-2\nrebuild worker-1\nrebuild control-plane-1\nrebuild_router' ] \
  || fail "dry run does not rebuild in the expected order"

run() {
  : > "$work/log"
  FAKE_LOG="$work/log" FAKE_FAIL_ON="$1" FAKE_VOLUME="$2" FAKE_DNS_EMPTY="${3:-}" PATH="$work/bin:$PATH" \
    VOLUME_TIMEOUT_SECONDS=1 ROUTER_TIMEOUT_SECONDS=1 POLL_SECONDS=1 SHORT_TMPDIR="$work" bash "$script" >/dev/null 2>&1
}

run none "attached|healthy" || fail "healthy run failed"
grep -q 'flake .#router' "$work/log" || fail "healthy run skipped the router"
grep -q "^NIX_SSHOPTS=-F $work/router-ssh-config\$" "$work/log" || fail "router rebuild lacks the cp1-direct NIX_SSHOPTS"
grep -q 'HostName 100.105.211.67' "$work/router-ssh-config" || fail "router ssh config lacks the cp1-direct tailnet address"

if run '.#worker-1' "attached|healthy"; then fail "failed rebuild did not fail the run"; fi
grep -q 'flake .#worker-2' "$work/log" || fail "worker-2 was not rebuilt first"
if grep -qE 'control-plane-1|router' "$work/log"; then fail "run continued past a failed host"; fi

if run none "attached|degraded"; then fail "degraded volume did not fail the run"; fi
if run none "attaching|"; then fail "attaching volume with unknown robustness did not fail the run"; fi
if grep -q 'flake .#worker-1' "$work/log"; then fail "run continued past unhealthy volumes"; fi

if run none "attached|healthy" empty; then fail "empty DNS answer did not fail the run"; fi

echo "ok"
