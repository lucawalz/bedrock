#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: deploy-nodes.sh [--dry-run]"
dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

require_tools nix kubectl ssh

NODES=(worker-2:10.20.0.12 worker-1:10.20.0.11 control-plane-1:10.20.0.10)
ROUTER_ADDRESS=10.20.0.1
BUILD_HOST=root@10.20.0.10
CONTROL_PLANE_ADDRESS=10.20.0.10
CONTROL_PLANE_TAILNET_ADDRESS=100.105.211.67
SHORT_TMPDIR="${SHORT_TMPDIR:-/tmp/nr}"
NODE_READY_TIMEOUT=10m
VOLUME_TIMEOUT_SECONDS="${VOLUME_TIMEOUT_SECONDS:-1800}"
ROUTER_TIMEOUT_SECONDS="${ROUTER_TIMEOUT_SECONDS:-300}"
SSH_CONNECT_TIMEOUT_SECONDS=5
POLL_SECONDS="${POLL_SECONDS:-5}"
DNS_PROBE_NAME=cloudflare.com

step() {
  echo "+ $*"
  if ! $dry_run; then "$@"; fi
}

rebuild() {
  local host="$1" address="$2"
  mkdir -p "$SHORT_TMPDIR"
  TMPDIR="$SHORT_TMPDIR" nix develop --command env TMPDIR="$SHORT_TMPDIR" \
    nixos-rebuild switch --flake ".#$host" --target-host "root@$address" --build-host "$BUILD_HOST"
}

rebuild_router() {
  local config="$SHORT_TMPDIR/router-ssh-config"
  mkdir -p "$SHORT_TMPDIR"
  cat > "$config" <<CONFIG
Host cp1-direct
  HostName $CONTROL_PLANE_TAILNET_ADDRESS
  HostKeyAlias $CONTROL_PLANE_ADDRESS
  User root
Host $ROUTER_ADDRESS $CONTROL_PLANE_ADDRESS
  ProxyJump cp1-direct
CONFIG
  TMPDIR="$SHORT_TMPDIR" NIX_SSHOPTS="-F $config" nix develop --command env TMPDIR="$SHORT_TMPDIR" \
    nixos-rebuild switch --flake .#router --target-host "root@$ROUTER_ADDRESS" --build-host "$BUILD_HOST"
}

# Detached volumes report robustness unknown and cannot degrade, so only degraded or faulted ones block.
volumes_healthy() {
  local deadline=$((SECONDS + VOLUME_TIMEOUT_SECONDS)) unhealthy
  while true; do
    unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name} {.status.robustness}{"\n"}{end}' \
      | awk '$2 == "degraded" || $2 == "faulted"')"
    [ -z "$unhealthy" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || { echo "Unhealthy Longhorn volumes:" >&2; echo "$unhealthy" >&2; return 1; }
    sleep "$POLL_SECONDS"
  done
}

router_answers() {
  local config="$SHORT_TMPDIR/router-ssh-config" deadline=$((SECONDS + ROUTER_TIMEOUT_SECONDS))
  until ssh -F "$config" -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" "root@$ROUTER_ADDRESS" true \
    && ssh -F "$config" -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" "root@$CONTROL_PLANE_ADDRESS" getent hosts "$DNS_PROBE_NAME" >/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "Router did not answer ssh and DNS" >&2; return 1; }
    sleep "$POLL_SECONDS"
  done
}

for entry in "${NODES[@]}"; do
  host="${entry%%:*}"
  step rebuild "$host" "${entry#*:}"
  step kubectl wait --for=condition=Ready "node/$host" --timeout "$NODE_READY_TIMEOUT"
  step volumes_healthy
done

step rebuild_router
step router_answers
