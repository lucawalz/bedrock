#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools openssl ssh-keygen shasum

script=scripts/generate-rebuild-keys.sh
hosts=(control-plane-1 worker-1 worker-2 router)
nodes=(control-plane-1 worker-1 worker-2)
secure_boot_keys=(PK KEK db)
secure_boot_rsa_bits=4096
test_root_rsa_bits=2048
test_root_days=1
token_pattern='^K10[0-9a-f]{64}::(server|node):[0-9a-f]{64}$'
longhorn_key_length=64
longhorn_key_pattern="^[0-9a-f]{$longhorn_key_length}\$"
uuid_length=36
guid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stick="$work/stick"
out="$stick/rebuild-keys"
mkdir -p "$stick/k3s-root-ca"
openssl req -x509 -newkey "rsa:$test_root_rsa_bits" -noenc -days "$test_root_days" -subj /CN=test-root \
  -keyout "$work/root-ca.key" -out "$stick/k3s-root-ca/root-ca.pem" 2>/dev/null
hash="$(openssl x509 -in "$stick/k3s-root-ca/root-ca.pem" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)"

BEDROCK_STICK_ROOT="$stick" bash "$script" > "$work/output" 2>&1 || { cat "$work/output" >&2; fail "first run failed"; }

expected=(k3s-token k3s-agent-token longhorn-crypto.key luks-install-passphrase)
for host in "${hosts[@]}"; do
  expected+=("hosts/$host/etc/ssh/ssh_host_ed25519_key" "hosts/$host/etc/ssh/ssh_host_ed25519_key.pub")
done
for node in "${nodes[@]}"; do
  expected+=("hosts/$node/var/lib/sbctl/GUID")
  for key in "${secure_boot_keys[@]}"; do
    expected+=("hosts/$node/var/lib/sbctl/keys/$key/$key.key" "hosts/$node/var/lib/sbctl/keys/$key/$key.pem")
  done
done
for file in "${expected[@]}"; do
  [ -f "$out/$file" ] || fail "$file is missing"
done
[ "$(find "$out" -type f | wc -l)" -eq "${#expected[@]}" ] || fail "the generator wrote files beyond the expected set"
[ -z "$(find "$out" -type f ! -perm 600)" ] || fail "a generated file is not mode 600"
[ -z "$(find "$out" -maxdepth 0 ! -perm 700)" ] || fail "$out is not mode 700"
for host in "${hosts[@]}"; do
  for dir in etc etc/ssh; do
    [ -z "$(find "$out/hosts/$host/$dir" -maxdepth 0 ! -perm 755)" ] || fail "$host/$dir is not mode 755, so the install would narrow /$dir"
  done
done
for node in "${nodes[@]}"; do
  for dir in var var/lib; do
    [ -z "$(find "$out/hosts/$node/$dir" -maxdepth 0 ! -perm 755)" ] || fail "$node/$dir is not mode 755, so the install would narrow /$dir"
  done
  [ -z "$(find "$out/hosts/$node/var/lib/sbctl" -type d ! -perm 700)" ] || fail "a directory under $node/var/lib/sbctl is not mode 700"
done

server_token="$(cat "$out/k3s-token")"
agent_token="$(cat "$out/k3s-agent-token")"
[[ "$server_token" =~ $token_pattern ]] && [ "${server_token:3:64}" = "$hash" ] && [[ "$server_token" == *::server:* ]] \
  || fail "k3s-token is not a server token pinning the test root"
[[ "$agent_token" =~ $token_pattern ]] && [ "${agent_token:3:64}" = "$hash" ] && [[ "$agent_token" == *::node:* ]] \
  || fail "k3s-agent-token is not a node token pinning the test root"
[ "${server_token##*:}" != "${agent_token##*:}" ] || fail "the server and agent tokens share a secret"

[[ "$(cat "$out/longhorn-crypto.key")" =~ $longhorn_key_pattern ]] && [ "$(wc -c < "$out/longhorn-crypto.key")" -eq "$longhorn_key_length" ] \
  || fail "longhorn-crypto.key is not $longhorn_key_length hex characters without a newline"
[ -s "$out/luks-install-passphrase" ] || fail "luks-install-passphrase is empty"

for host in "${hosts[@]}"; do
  ssh-keygen -l -f "$out/hosts/$host/etc/ssh/ssh_host_ed25519_key" | grep -q '(ED25519)$' || fail "$host host key is not ed25519"
  [ "$(ssh-keygen -y -f "$out/hosts/$host/etc/ssh/ssh_host_ed25519_key" | cut -d' ' -f2)" = \
    "$(cut -d' ' -f2 "$out/hosts/$host/etc/ssh/ssh_host_ed25519_key.pub")" ] || fail "$host public key does not match its private key"
done

for node in "${nodes[@]}"; do
  bundle="$out/hosts/$node/var/lib/sbctl"
  [[ "$(cat "$bundle/GUID")" =~ $guid_pattern ]] && [ "$(wc -c < "$bundle/GUID")" -eq "$uuid_length" ] \
    || fail "$node GUID is not a lowercase UUID without a newline"
  for key in "${secure_boot_keys[@]}"; do
    [ "$(head -n 1 "$bundle/keys/$key/$key.key")" = "-----BEGIN PRIVATE KEY-----" ] || fail "$node $key.key is not PKCS#8 PEM"
    openssl x509 -in "$bundle/keys/$key/$key.pem" -noout -text | grep -q "Public-Key: ($secure_boot_rsa_bits bit)" \
      || fail "$node $key.pem is not an RSA $secure_boot_rsa_bits certificate"
    [ "$(openssl pkey -in "$bundle/keys/$key/$key.key" -pubout)" = "$(openssl x509 -in "$bundle/keys/$key/$key.pem" -noout -pubkey)" ] \
      || fail "$node $key.key does not match $key.pem"
  done
done
[ "$(for node in "${nodes[@]}"; do cat "$out/hosts/$node/var/lib/sbctl/GUID"; echo; done | sort -u | wc -l)" -eq "${#nodes[@]}" ] \
  || fail "two nodes share a GUID"

{
  printf '%s\n' "${server_token##*:}" "${agent_token##*:}"
  printf '%s\n' "$(cat "$out/longhorn-crypto.key")" "$(cat "$out/luks-install-passphrase")"
  find "$out" -type f \( -name '*.key' -o -name ssh_host_ed25519_key \) ! -name longhorn-crypto.key -exec grep -hv -- ----- {} +
} > "$work/secrets"
if grep -qFf "$work/secrets" "$work/output"; then fail "the generator printed a secret value"; fi
grep -qF "$hash" "$work/output" || fail "the generator did not print the CA hash"
grep -qF "$(cat "$out/hosts/router/etc/ssh/ssh_host_ed25519_key.pub")" "$work/output" || fail "the generator did not print the host public keys"

snapshot() { find "$stick" -exec ls -ld {} + | awk '{ print $1, $NF }'; find "$stick" -type f -exec shasum {} +; }
snapshot > "$work/before"
if BEDROCK_STICK_ROOT="$stick" bash "$script" > "$work/second" 2>&1; then fail "a second run did not refuse"; fi
snapshot > "$work/after"
cmp -s "$work/before" "$work/after" || fail "a refused second run changed the stick"

echo "generate-rebuild-keys writes every key with the expected modes and formats, prints no secret and refuses a second run."
