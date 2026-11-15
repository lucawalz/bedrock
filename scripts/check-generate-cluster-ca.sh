#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools age age-keygen nix-instantiate jq openssl tar shasum

token_secret_bytes=32
ca_hash_bytes=32
secrets=(k3s-ca.age k3s-token.age k3s-agent-token.age)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
ram="$work/ram"
mkdir -p "$repo/scripts/lib" "$repo/secrets" "$work/bin" "$work/stick" "$ram"
cp scripts/generate-cluster-ca.sh "$repo/scripts/"
cp scripts/lib/common.sh "$repo/scripts/lib/"

age-keygen -o "$work/identity.txt" 2>/dev/null
recipient="$(age-keygen -y "$work/identity.txt")"
{
  echo "{"
  for secret in "${secrets[@]}"; do echo "  \"$secret\".publicKeys = [ \"$recipient\" ];"; done
  echo "}"
} > "$repo/secrets/secrets.nix"
server_password="$(openssl rand -hex "$token_secret_bytes")"
agent_password="$(openssl rand -hex "$token_secret_bytes")"
old_hash="$(openssl rand -hex "$ca_hash_bytes")"
printf 'old ca\n' | age -r "$recipient" -o "$repo/secrets/k3s-ca.age"
printf 'K10%s::server:%s\n' "$old_hash" "$server_password" | age -r "$recipient" -o "$repo/secrets/k3s-token.age"
printf 'K10%s::node:%s\n' "$old_hash" "$agent_password" | age -r "$recipient" -o "$work/agent-token.age"

real_openssl="$(command -v openssl)"
real_tar="$(command -v tar)"
cat > "$work/bin/openssl" <<FAKE
#!/bin/sh
if [ "\$1" = version ] && [ -n "\${FAKE_OPENSSL_VERSION:-}" ]; then echo "\$FAKE_OPENSSL_VERSION"; exit 0; fi
exec "$real_openssl" "\$@"
FAKE
cat > "$work/bin/tar" <<FAKE
#!/bin/sh
echo "tar \$*" >> "\$FAKE_LOG"
exec "$real_tar" "\$@"
FAKE
: > "$work/bin/age-plugin-se"
chmod +x "$work"/bin/*

reset() {
  cp "$work/agent-token.age" "$repo/secrets/k3s-agent-token.age"
}

run() {
  : > "$work/log"
  FAKE_LOG="$work/log" PATH="$work/bin:$PATH" BEDROCK_AGENIX_IDENTITY="$work/identity.txt" \
    BEDROCK_ROOT_CA_DIR="$work/stick/k3s-root-ca" BEDROCK_CREATE_ROOT_CA=1 \
    bash "$repo/scripts/generate-cluster-ca.sh" < /dev/null > "$work/output" 2>&1
}

snapshot() { find "$repo/secrets" -type f -exec shasum {} + | sort; }

reset
snapshot > "$work/before"
if run; then fail "a run without a RAM disk was accepted"; fi
snapshot | cmp -s - "$work/before" || fail "a run without a RAM disk changed secrets/"
[ ! -e "$work/stick/k3s-root-ca" ] || fail "a run without a RAM disk minted a root CA"

BEDROCK_RAM_DISK="$ram" run || { cat "$work/output" >&2; fail "a valid run failed"; }
grep -q "^tar .*-cf $ram/" "$work/log" || fail "the CA tarball was not built on the RAM disk"
[ -z "$(ls -A "$ram")" ] || fail "the run left its work dir on the RAM disk"
ca_hash="$(k3s_ca_hash "$work/stick/k3s-root-ca/root-ca.pem")"
[ "$(age -d -i "$work/identity.txt" "$repo/secrets/k3s-token.age")" = "K10$ca_hash::server:$server_password" ] \
  || fail "k3s-token.age was not re-pinned to the root CA with its password kept"
[ "$(age -d -i "$work/identity.txt" "$repo/secrets/k3s-agent-token.age")" = "K10$ca_hash::node:$agent_password" ] \
  || fail "k3s-agent-token.age was not re-pinned to the root CA with its password kept"
age -d -i "$work/identity.txt" "$repo/secrets/k3s-ca.age" | "$real_tar" -t | grep -qx server-ca.crt || fail "k3s-ca.age does not hold the CA tarball"

reset
FAKE_OPENSSL_VERSION="OpenSSL 4.0.0 1 Jan 2027" BEDROCK_RAM_DISK="$ram" run \
  || { cat "$work/output" >&2; fail "OpenSSL 4 was refused"; }
if FAKE_OPENSSL_VERSION="LibreSSL 3.3.6" BEDROCK_RAM_DISK="$ram" run; then fail "LibreSSL was accepted"; fi

printf 'not a token\n' | age -r "$recipient" -o "$repo/secrets/k3s-agent-token.age"
snapshot > "$work/before"
if BEDROCK_RAM_DISK="$ram" run; then fail "a malformed agent token was accepted"; fi
grep -q k3s-agent-token.age "$work/output" || fail "the malformed token refusal does not name k3s-agent-token.age"
snapshot | cmp -s - "$work/before" || fail "a failed re-pin changed secrets/"

echo "generate-cluster-ca works on the RAM disk, accepts OpenSSL 3 or later and writes secrets/ only after both tokens re-pin."
