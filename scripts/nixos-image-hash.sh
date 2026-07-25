#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Changing this list or its order changes every snapshot name and forces a full rebuild.
inputs=(
  HEAD:flake.nix
  HEAD:flake.lock
  HEAD:modules/k3s/cluster-node.nix
  HEAD:modules/k3s/hetzner-scaffolding.nix
  HEAD:infra/packer
)

if command -v sha256sum >/dev/null 2>&1; then
  digest=(sha256sum)
else
  digest=(shasum -a 256)
fi

readonly HASH_LENGTH=40

git rev-parse "${inputs[@]}" | "${digest[@]}" | cut -c"1-${HASH_LENGTH}"
