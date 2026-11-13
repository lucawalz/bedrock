#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools age age-keygen ssh-keygen nix jq git openssl shasum

hosts=(control-plane-1 worker-1 worker-2 router)
token_secret_bytes=32
ca_hash_bytes=32

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
stick="$work/stick"
keys="$stick/rebuild-keys"
ramdisk="$work/ramdisk"
mkdir -p "$repo/scripts/lib" "$repo/secrets" "$work/bin" "$work/old" "$stick/ssh"
cp scripts/rekey-secrets.sh "$repo/scripts/"
cp scripts/lib/common.sh "$repo/scripts/lib/"

for host in "${hosts[@]}"; do
  mkdir -p "$keys/hosts/$host/etc/ssh"
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$keys/hosts/$host/etc/ssh/ssh_host_ed25519_key"
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$work/old/$host"
done
ssh-keygen -q -t ed25519 -N "" -C estate-breakglass -f "$stick/ssh/estate-breakglass"
age-keygen -o "$work/admin.txt" 2>/dev/null
ca_hash="$(openssl rand -hex "$ca_hash_bytes")"
printf 'K10%s::server:%s\n' "$ca_hash" "$(openssl rand -hex "$token_secret_bytes")" > "$keys/k3s-token"
printf 'K10%s::node:%s\n' "$ca_hash" "$(openssl rand -hex "$token_secret_bytes")" > "$keys/k3s-agent-token"

host_key() { printf '%s\n' "$keys/hosts/$1/etc/ssh/ssh_host_ed25519_key"; }

write_rules() {
  local key_dir="$1" expression=() host
  for host in "${hosts[@]}"; do
    expression+=(-e "s|^  $host = \".*\";\$|  $host = \"$(cat "$key_dir/$host.pub")\";|")
  done
  sed "${expression[@]}" \
    -e "s|^  luca-secure-enclave = \".*\";\$|  luca-secure-enclave = \"$(age-keygen -y "$work/admin.txt")\";|" \
    -e "s|^  estate-breakglass = \".*\";\$|  estate-breakglass = \"$(cat "$stick/ssh/estate-breakglass.pub")\";|" \
    secrets/secrets.nix > "$repo/secrets/secrets.nix"
}

mkdir "$work/new"
for host in "${hosts[@]}"; do cp "$(host_key "$host").pub" "$work/new/$host.pub"; done

write_rules "$work/old"
for file in $(nix eval --json --file "$repo/secrets/secrets.nix" | jq -r 'keys[]'); do
  printf 'old %s\n' "$file" | age -R <(nix eval --json --file "$repo/secrets/secrets.nix" | jq -r --arg file "$file" '.[$file].publicKeys[]') \
    -o "$repo/secrets/$file"
done
cp -R "$repo/secrets" "$work/pristine"

cat > "$work/bin/agenix" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "agenix $* TMPDIR=$TMPDIR" >> "$FAKE_LOG"
[ "$1" = -r ] && [ "$2" = -i ] || exit 1
rules="$(nix eval --json --file secrets.nix)"
for file in $(jq -r 'keys[]' <<< "$rules"); do
  [ -f "$file" ] || continue
  age -d -i "$3" "$file" | age -R <(jq -r --arg file "$file" '.[$file].publicKeys[]' <<< "$rules") -o "$file.new"
  mv "$file.new" "$file"
done
FAKE
cat > "$work/bin/hdiutil" <<'FAKE'
#!/bin/sh
echo "hdiutil $*" >> "$FAKE_LOG"
case "$1" in attach) echo "/dev/disk99          " ;; esac
FAKE
cat > "$work/bin/diskutil" <<'FAKE'
#!/bin/sh
echo "diskutil $*" >> "$FAKE_LOG"
case "$1" in
  erasevolume) mkdir -p "$FAKE_RAMDISK" ;;
  info) echo "   Mount Point:               $FAKE_RAMDISK" ;;
esac
FAKE
: > "$work/bin/age-plugin-se"
cat > "$repo/scripts/generate-cluster-ca.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "generate-cluster-ca identity=$BEDROCK_AGENIX_IDENTITY TMPDIR=$TMPDIR" >> "$FAKE_LOG"
rules="$(nix eval --json --file secrets/secrets.nix)"
recipients() { jq -r --arg file "$1" '.[$file].publicKeys[]' <<< "$rules"; }
echo ca | age -R <(recipients k3s-ca.age | head -n "${FAKE_CA_RECIPIENTS:-99}") -o secrets/k3s-ca.age
if [ -n "${FAKE_CORRUPT_TOKEN:-}" ]; then
  echo corrupt | age -R <(recipients k3s-token.age) -o secrets/k3s-token.age
fi
FAKE
chmod +x "$work"/bin/* "$repo/scripts/generate-cluster-ca.sh"
git -C "$repo" init -q
git -C "$repo" add secrets
git -C "$repo" ls-files -s > "$work/index"

reset() {
  rm -rf "$repo/secrets" "$ramdisk"
  cp -R "$work/pristine" "$repo/secrets"
  write_rules "$work/new"
}

run() {
  : > "$work/log"
  FAKE_LOG="$work/log" FAKE_RAMDISK="$ramdisk" BEDROCK_STICK_ROOT="$stick" PATH="$work/bin:$PATH" \
    bash "$repo/scripts/rekey-secrets.sh" < /dev/null > "$work/output" 2>&1
}

snapshot() { find "$repo/secrets" -type f -exec shasum {} + | sort; }

decrypts() { age -d -i "$1" "$repo/secrets/$2" > /dev/null 2>&1; }

stanzas() { awk '/^---/ { exit } /^-> / { count++ } END { print count + 0 }' "$repo/secrets/$1"; }

listed() { nix eval --json --file "$repo/secrets/secrets.nix" | jq --arg file "$1" '.[$file].publicKeys | length'; }

reset
cp "$work/old/worker-2.pub" "$work/new/worker-2.pub"
write_rules "$work/new"
cp "$(host_key worker-2).pub" "$work/new/worker-2.pub"
snapshot > "$work/before"
if run; then fail "a secrets.nix with an old worker-2 host key was not refused"; fi
grep -q worker-2 "$work/output" || fail "the host key refusal does not name worker-2"
snapshot | grep -v secrets.nix > "$work/after"
grep -v secrets.nix "$work/before" | cmp -s - "$work/after" || fail "a refused run changed secrets/"
if grep -q '^agenix\|^hdiutil' "$work/log"; then fail "a refused run reached agenix or the RAM disk"; fi

reset
run || { cat "$work/output" >&2; fail "a valid re-key failed"; }
grep -q "^hdiutil attach -nomount ram://" "$work/log" || fail "no RAM disk was attached"
grep -q "^diskutil erasevolume APFS " "$work/log" || fail "the RAM disk was not formatted"
grep -q "^hdiutil detach.* /dev/disk99" "$work/log" || fail "the RAM disk was not detached"
grep -q "^agenix -r -i $ramdisk/.* TMPDIR=$ramdisk/" "$work/log" || fail "agenix did not re-key with an identity and TMPDIR on the RAM disk"
grep -q "^generate-cluster-ca identity=$ramdisk/.* TMPDIR=$ramdisk/" "$work/log" \
  || fail "generate-cluster-ca did not run with an identity and TMPDIR on the RAM disk"
[ "$(grep -n -m 1 '^agenix' "$work/log" | cut -d: -f1)" -lt "$(grep -n -m 1 '^generate-cluster-ca' "$work/log" | cut -d: -f1)" ] \
  || fail "the cluster CA was issued before the re-key"

for file in $(nix eval --json --file "$repo/secrets/secrets.nix" | jq -r 'keys[]'); do
  [ "$(stanzas "$file")" -eq "$(listed "$file")" ] || fail "$file does not hold one stanza per recipient in secrets.nix"
  decrypts "$stick/ssh/estate-breakglass" "$file" || fail "$file does not decrypt with the break-glass key"
  for host in "${hosts[@]}"; do
    if decrypts "$work/old/$host" "$file"; then fail "$file still decrypts with the old $host key"; fi
  done
done
for identity in "$stick/ssh/estate-breakglass" "$work/admin.txt" "$(host_key control-plane-1)"; do
  age -d -i "$identity" "$repo/secrets/k3s-token.age" | cmp -s - "$keys/k3s-token" || fail "k3s-token.age does not match the stick token"
done
for host in control-plane-1 worker-1 worker-2; do
  age -d -i "$(host_key "$host")" "$repo/secrets/k3s-agent-token.age" | cmp -s - "$keys/k3s-agent-token" \
    || fail "k3s-agent-token.age does not decrypt to the stick token with the $host key"
done
if decrypts "$(host_key worker-1)" k3s-token.age; then fail "a worker decrypts the server token"; fi
decrypts "$(host_key router)" tailscale-authkey.age || fail "tailscale-authkey.age was not re-keyed to the new router key"

grep -q "^.M secrets/k3s-token.age" "$work/output" || fail "the changed files were not listed"
git -C "$repo" ls-files -s | cmp -s - "$work/index" || fail "the re-key staged a file"

{
  cut -d: -f3 "$keys/k3s-token" "$keys/k3s-agent-token"
  grep -hv -- ----- "$stick/ssh/estate-breakglass" "$work/admin.txt" | grep -v '^#'
  for host in "${hosts[@]}"; do grep -v -- ----- "$(host_key "$host")"; done
} > "$work/secrets"
if grep -qFf "$work/secrets" "$work/output"; then fail "the re-key printed a secret"; fi

reset
if FAKE_CA_RECIPIENTS=2 run; then fail "a k3s-ca.age missing a recipient was accepted"; fi
grep -q k3s-ca.age "$work/output" || fail "the recipient count failure does not name k3s-ca.age"
grep -q "^hdiutil detach" "$work/log" || fail "a failed run left the RAM disk attached"

reset
if FAKE_CORRUPT_TOKEN=1 run; then fail "a k3s-token.age that differs from the stick token was accepted"; fi
grep -q k3s-token.age "$work/output" || fail "the token mismatch does not name k3s-token.age"

echo "rekey-secrets refuses old host keys, writes the stick tokens to the secrets.nix recipients and verifies every file on a RAM disk."
