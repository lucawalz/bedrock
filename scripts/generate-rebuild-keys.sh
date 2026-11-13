#!/usr/bin/env bash
set -euo pipefail
umask 077

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools openssl ssh-keygen python3

[ "$#" -eq 0 ] || { echo "usage: generate-rebuild-keys.sh" >&2; exit 1; }

stick_root="${BEDROCK_STICK_ROOT:-/Volumes/bedrock-keys/bedrock}"
root_cert="$stick_root/k3s-root-ca/root-ca.pem"
out="$stick_root/rebuild-keys"
hosts=(control-plane-1 worker-1 worker-2 router)
nodes=(control-plane-1 worker-1 worker-2)
secure_boot_keys=("PK:Platform Key" "KEK:Key Exchange Key" "db:Database Key")
secure_boot_rsa_bits=4096
secure_boot_days=1826
token_secret_bytes=32
longhorn_key_bytes=32
luks_passphrase_bytes=16
private_mode=600
system_dir_mode=755

openssl version | grep -q '^OpenSSL 3' || { echo "openssl must be OpenSSL 3, got: $(openssl version)" >&2; exit 1; }
[ -d "$stick_root" ] || { echo "$stick_root is not mounted; plug in the bedrock-keys stick or set BEDROCK_STICK_ROOT" >&2; exit 1; }
[ -f "$root_cert" ] || { echo "$root_cert is missing; the tokens pin its hash" >&2; exit 1; }
mkdir "$out" || { echo "$out already exists; keys are generated once per rebuild, so move it aside first" >&2; exit 1; }

secret() {
  openssl rand -hex "$1"
}

ca_hash="$(k3s_ca_hash "$root_cert")"
server_secret="$(secret "$token_secret_bytes")"
agent_secret="$(secret "$token_secret_bytes")"
longhorn_key="$(secret "$longhorn_key_bytes")"
luks_passphrase="$(secret "$luks_passphrase_bytes")"
printf 'K10%s::server:%s\n' "$ca_hash" "$server_secret" > "$out/k3s-token"
printf 'K10%s::node:%s\n' "$ca_hash" "$agent_secret" > "$out/k3s-agent-token"
printf '%s' "$longhorn_key" > "$out/longhorn-crypto.key"
printf '%s' "$luks_passphrase" > "$out/luks-install-passphrase"
unset server_secret agent_secret longhorn_key luks_passphrase

for host in "${hosts[@]}"; do
  tree="$out/hosts/$host"
  mkdir -p "$tree/etc/ssh"
  chmod "$system_dir_mode" "$tree/etc" "$tree/etc/ssh"
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$tree/etc/ssh/ssh_host_ed25519_key"
done

for node in "${nodes[@]}"; do
  tree="$out/hosts/$node"
  bundle="$tree/var/lib/sbctl"
  mkdir -p "$bundle/keys"
  chmod "$system_dir_mode" "$tree/var" "$tree/var/lib"
  python3 -I -c 'import uuid; print(uuid.uuid4(), end="")' > "$bundle/GUID"
  for entry in "${secure_boot_keys[@]}"; do
    key="${entry%%:*}"
    mkdir "$bundle/keys/$key"
    openssl req -x509 -newkey "rsa:$secure_boot_rsa_bits" -noenc -sha256 -days "$secure_boot_days" \
      -subj "/CN=${entry#*:}" -keyout "$bundle/keys/$key/$key.key" -out "$bundle/keys/$key/$key.pem" 2>/dev/null
  done
done

find "$out" -type f -exec chmod "$private_mode" {} +

echo "Wrote $out"
echo "The k3s tokens pin CA hash $ca_hash"
for host in "${hosts[@]}"; do
  echo "$host: $(cat "$out/hosts/$host/etc/ssh/ssh_host_ed25519_key.pub")"
done
