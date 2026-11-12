#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

script=scripts/deploy-nodes.sh
expected_order="rebuild worker-2
rebuild worker-1
rebuild control-plane-1
rebuild_router"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

order() { grep -oE '^\+ (rebuild(_router)?( [a-z0-9-]+)?)' | sed 's/^+ //; s/ [0-9.]*$//'; }

dry="$(PATH="$work/bin:$PATH" bash "$script" --dry-run 2>&1 || true)"
[ "$(printf '%s\n' "$dry" | order)" = "$expected_order" ] || fail "dry run does not rebuild in the expected order"

cat > "$work/bin/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >> "$FAKE_LOG"
FAKE
cat > "$work/bin/nix" <<'FAKE'
#!/bin/sh
echo "nix $*" >> "$FAKE_LOG"
case "$*" in *"$FAKE_FAIL_ON"*) exit 1 ;; esac
FAKE
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in *volumes.longhorn.io*) printf 'vol-a %s\nvol-b unknown\n' "$FAKE_ROBUSTNESS" ;; esac
FAKE

chmod +x "$work"/bin/*

run() {
  : > "$work/log"
  FAKE_LOG="$work/log" FAKE_FAIL_ON="$1" FAKE_ROBUSTNESS="$2" PATH="$work/bin:$PATH" \
    VOLUME_TIMEOUT_SECONDS=1 POLL_SECONDS=1 SHORT_TMPDIR="$work" bash "$script" >/dev/null 2>&1
}

run none healthy || fail "healthy run failed"
grep -q 'flake .#router' "$work/log" || fail "healthy run skipped the router"

if run '.#worker-1' healthy; then fail "failed rebuild did not fail the run"; fi
grep -q 'flake .#worker-2' "$work/log" || fail "worker-2 was not rebuilt first"
if grep -qE 'control-plane-1|router' "$work/log"; then fail "run continued past a failed host"; fi

if run none degraded; then fail "degraded volume did not fail the run"; fi
if grep -q 'flake .#worker-1' "$work/log"; then fail "run continued past degraded volumes"; fi

echo "ok"
