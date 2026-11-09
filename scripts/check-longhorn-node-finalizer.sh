#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

manifest=kubernetes/infrastructure/configs/reaper/cronjob.yaml
script_query='select(.kind == "CronJob" and .metadata.name == "longhorn-node-finalizer") | .spec.jobTemplate.spec.template.spec.containers[0].command[2]'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

yq -N "$script_query" "$manifest" > "$work/finalizer.sh"
[ -s "$work/finalizer.sh" ] || fail "$manifest has no longhorn-node-finalizer script"

cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
case "$*" in
  "get nodes.longhorn.io"*) printf '%s\n' "$FAKE_LONGHORN_NODES" ;;
  "get node "*)
    case "$FAKE_NODE_LOOKUP" in
      present) exit 0 ;;
      notfound) echo "Error from server (NotFound): nodes \"$3\" not found" >&2; exit 1 ;;
      *) echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2; exit 1 ;;
    esac ;;
  patch*) echo "$*" >> "$FAKE_PATCH_LOG" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$work/bin/kubectl"

status=0

run_case() {
  local name="$1" lookup="$2" allow="$3" expected="$4"
  : > "$work/patches"
  if ! PATH="$work/bin:$PATH" FAKE_PATCH_LOG="$work/patches" FAKE_NODE_LOOKUP="$lookup" \
    FAKE_LONGHORN_NODES="worker-1 $allow" sh "$work/finalizer.sh" > /dev/null 2> "$work/stderr"; then
    echo "FAIL: $name: script exited non-zero"
    status=1
    return
  fi
  local patched=0
  [ -s "$work/patches" ] && patched=1
  if [ "$patched" != "$expected" ]; then
    echo "FAIL: $name: patched=$patched, expected $expected"
    status=1
  fi
  if [ "$lookup" = error ] && ! grep -q . "$work/stderr"; then
    echo "FAIL: $name: no skip line on stderr"
    status=1
  fi
}

run_case "node present" present true 0
run_case "node NotFound, scheduling on" notfound true 1
run_case "node lookup error" error true 0
run_case "node NotFound, scheduling already off" notfound false 0

if [ "$status" -eq 0 ]; then
  echo "Longhorn node finalizer only disables scheduling for absent nodes."
fi
exit "$status"
