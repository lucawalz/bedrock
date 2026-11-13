#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "usage: deploy-nodes.sh [--dry-run]" >&2; exit 2 ;;
esac

require_tools nix kubectl ssh dig

NODES=(worker-2:10.20.0.12 worker-1:10.20.0.11 control-plane-1:10.20.0.10)
ROUTER_ADDRESS=10.20.0.1
CONTROL_PLANE_ADDRESS=10.20.0.10
BUILD_HOST="root@$CONTROL_PLANE_ADDRESS"
CONTROL_PLANE_TAILNET_ADDRESS=100.105.211.67
SHORT_TMPDIR="${SHORT_TMPDIR:-/tmp/nr}"
NODE_READY_TIMEOUT=10m
VOLUME_TIMEOUT_SECONDS="${VOLUME_TIMEOUT_SECONDS:-1800}"
ROUTER_TIMEOUT_SECONDS="${ROUTER_TIMEOUT_SECONDS:-300}"
SSH_CONNECT_TIMEOUT_SECONDS=5
POLL_SECONDS="${POLL_SECONDS:-5}"
DNS_PROBE_NAME=registry.syslabs.dev
ADMIN_KEY_DIR="$repo_root/hosts/common"
ADMIN_AGENT_SOCKET="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
NO_AGENT=none

if [ -n "${BEDROCK_SSH_IDENTITY:-}" ]; then
  [ -r "$BEDROCK_SSH_IDENTITY" ] || fail "BEDROCK_SSH_IDENTITY=$BEDROCK_SSH_IDENTITY is not readable; mount the key stick"
  ADMIN_IDENTITIES=("$BEDROCK_SSH_IDENTITY")
  ADMIN_AGENT="$NO_AGENT"
  ADMIN_IDENTITIES_ONLY=yes
  PROBE_BATCH_MODE=no
else
  ADMIN_IDENTITIES=("$ADMIN_KEY_DIR/estate-root.pub")
  [ ! -f "$ADMIN_KEY_DIR/estate-root-next.pub" ] || ADMIN_IDENTITIES+=("$ADMIN_KEY_DIR/estate-root-next.pub")
  ADMIN_AGENT="$ADMIN_AGENT_SOCKET"
  ADMIN_IDENTITIES_ONLY=no
  PROBE_BATCH_MODE=yes
fi

ADMIN_SSH_OPTS=()
for identity in "${ADMIN_IDENTITIES[@]}"; do ADMIN_SSH_OPTS+=(-i "$identity"); done
ADMIN_SSH_OPTS+=(-o "IdentityAgent=$ADMIN_AGENT" -o "IdentitiesOnly=$ADMIN_IDENTITIES_ONLY")

step() {
  echo "+ $*"
  if ! $dry_run; then "$@"; fi
}

rebuild() {
  local host="$1" address="$2"
  mkdir -p "$SHORT_TMPDIR"
  TMPDIR="$SHORT_TMPDIR" NIX_SSHOPTS="${ADMIN_SSH_OPTS[*]}" nix develop --command env TMPDIR="$SHORT_TMPDIR" \
    nixos-rebuild switch --flake ".#$host" --target-host "root@$address" --build-host "$BUILD_HOST"
}

identity_config() {
  local identity
  for identity in "${ADMIN_IDENTITIES[@]}"; do echo "  IdentityFile $identity"; done
  echo "  IdentityAgent $ADMIN_AGENT"
  echo "  IdentitiesOnly $ADMIN_IDENTITIES_ONLY"
}

rebuild_router() {
  local config="$SHORT_TMPDIR/router-ssh-config"
  mkdir -p "$SHORT_TMPDIR"
  cat > "$config" <<CONFIG
Host cp1-direct
  HostName $CONTROL_PLANE_TAILNET_ADDRESS
  HostKeyAlias $CONTROL_PLANE_ADDRESS
  User root
$(identity_config)
Host $ROUTER_ADDRESS $CONTROL_PLANE_ADDRESS
  ProxyJump cp1-direct
$(identity_config)
CONFIG
  TMPDIR="$SHORT_TMPDIR" NIX_SSHOPTS="-F $config" nix develop --command env TMPDIR="$SHORT_TMPDIR" \
    nixos-rebuild switch --flake .#router --target-host "root@$ROUTER_ADDRESS" --build-host "$BUILD_HOST"
}

# A detached volume reports robustness unknown and is skipped; every other state must be healthy.
volumes_healthy() {
  local deadline=$((SECONDS + VOLUME_TIMEOUT_SECONDS)) unhealthy
  while true; do
    unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[*]}{.metadata.name}|{.status.state}|{.status.robustness}{"\n"}{end}' \
      | awk -F'|' '$2 != "detached" && $3 != "healthy"')"
    [ -z "$unhealthy" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || { echo "Unhealthy Longhorn volumes:" >&2; echo "$unhealthy" >&2; return 1; }
    sleep "$POLL_SECONDS"
  done
}

router_answers() {
  local config="$SHORT_TMPDIR/router-ssh-config" deadline=$((SECONDS + ROUTER_TIMEOUT_SECONDS))
  until ssh -F "$config" "${ADMIN_SSH_OPTS[@]}" -o BatchMode="$PROBE_BATCH_MODE" -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" "root@$ROUTER_ADDRESS" true \
    && [ -n "$(dig +short "@$ROUTER_ADDRESS" "$DNS_PROBE_NAME")" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "Router did not answer ssh and DNS" >&2; return 1; }
    sleep "$POLL_SECONDS"
  done
}

warn_if_kernel_pending() {
  local host="$1" target="$2"; shift 2
  local kernels booted current
  kernels="$(ssh "${ADMIN_SSH_OPTS[@]}" "$@" -o BatchMode="$PROBE_BATCH_MODE" -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" "$target" \
    readlink /run/booted-system/kernel /run/current-system/kernel)"
  booted="$(printf '%s\n' "$kernels" | sed -n 1p)"
  current="$(printf '%s\n' "$kernels" | sed -n 2p)"
  if [ "$booted" != "$current" ]; then
    echo "WARNING: $host runs an older kernel than its current system; drain and reboot it" >&2
  fi
}

for entry in "${NODES[@]}"; do
  host="${entry%%:*}"
  step rebuild "$host" "${entry#*:}"
  step kubectl wait --for=condition=Ready "node/$host" --timeout "$NODE_READY_TIMEOUT"
  step volumes_healthy
  step warn_if_kernel_pending "$host" "root@${entry#*:}"
done

step rebuild_router
step router_answers
step warn_if_kernel_pending router "root@$ROUTER_ADDRESS" -F "$SHORT_TMPDIR/router-ssh-config"
