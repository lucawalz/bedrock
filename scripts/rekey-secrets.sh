#!/usr/bin/env bash
set -euo pipefail
umask 077

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 0 ] || { echo "usage: rekey-secrets.sh" >&2; exit 2; }

PATH="$PATH:/opt/homebrew/bin"
require_tools nix jq age agenix ssh-keygen hdiutil diskutil mdutil git cmp age-plugin-se

RAM_DISK_SECTORS=524288
RAM_DISK_NAME="bedrock-rekey-$$"
TOKENS=(k3s-token k3s-agent-token)
SERVER_FILES=(k3s-token.age k3s-ca.age)
AGENT_FILE=k3s-agent-token.age

stick="$(stick_root)"
keys="$(rebuild_keys_dir)"
breakglass="$stick/ssh/estate-breakglass"

[ -r "$breakglass" ] || fail "$breakglass is missing; mount the bedrock-keys stick"
[ -d "$keys/hosts" ] || fail "$keys/hosts is missing; run just generate-rebuild-keys"
for token in "${TOKENS[@]}"; do
  [ -r "$keys/$token" ] || fail "$keys/$token is missing; run just generate-rebuild-keys"
done

rules="$(secret_rules)"
hosts=()
while IFS= read -r host; do hosts+=("$host"); done < <(stick_hosts)
[ "${#hosts[@]}" -gt 0 ] || fail "$keys/hosts holds no host"
for host in "${hosts[@]}"; do
  listed="$(jq -r --arg comment " root@$host" '[.[].publicKeys[]] | unique[] | select(endswith($comment))' <<< "$rules" | cut -d' ' -f1,2 | sort -u)"
  [ "$listed" = "$(cut -d' ' -f1,2 "$(stick_host_key "$host").pub")" ] \
    || fail "secrets/secrets.nix does not list exactly the stick host key for $host; copy it from $(stick_host_key "$host").pub"
done

control_plane="$(nix eval --raw --file lib/inventory.nix bootstrapControlPlane)"
nodes=()
while IFS= read -r node; do nodes+=("$node"); done < <(nix eval --json --file lib/inventory.nix nodes | jq -r 'keys[]')
for host in "$control_plane" "${nodes[@]}"; do
  [ -r "$(stick_host_key "$host")" ] || fail "$(stick_host_key "$host") is missing; run just generate-rebuild-keys"
done

ram_device=""
ram=""
release_ram_disk() {
  local status=$? cleared=true detached=true
  if [ -n "$ram" ] && [ -d "$ram" ]; then rm -rf "${ram:?}"/* || cleared=false; fi
  if [ -n "$ram_device" ]; then hdiutil detach -force "$ram_device" > /dev/null || detached=false; fi
  if ! $cleared; then
    echo "FAIL: clearing the RAM disk $ram_device at $ram failed; check by hand that it is detached: hdiutil detach -force $ram_device" >&2
    status=1
  fi
  if ! $detached; then
    echo "FAIL: detaching the RAM disk $ram_device failed; detach it by hand with: hdiutil detach -force $ram_device" >&2
    status=1
  fi
  exit "$status"
}
trap release_ram_disk EXIT
ram_device="$(hdiutil attach -nomount "ram://$RAM_DISK_SECTORS" | awk 'NR == 1 { print $1 }')"
[ -n "$ram_device" ] || fail "attaching a RAM disk failed"
diskutil erasevolume APFS "$RAM_DISK_NAME" "$ram_device" > /dev/null
ram="$(diskutil info "$RAM_DISK_NAME" | awk -F': *' '/Mount Point/ { print $2 }')"
[ -d "$ram" ] || fail "the RAM disk $RAM_DISK_NAME is not mounted"
mdutil -i off "$ram" > /dev/null
export TMPDIR="$ram/tmp"
mkdir -m 700 "$TMPDIR"

identity="$ram/estate-breakglass"
cp "$breakglass" "$identity"
echo "Unlocking the break-glass key onto the RAM disk."
ssh-keygen -q -p -N "" -f "$identity" > /dev/null

(cd secrets && agenix -r -i "$identity")

for token in "${TOKENS[@]}"; do
  age -R <(secret_recipients "$rules" "$token.age") -o "$TMPDIR/$token.age" "$keys/$token"
  mv "$TMPDIR/$token.age" "secrets/$token.age"
done

BEDROCK_AGENIX_IDENTITY="$identity" BEDROCK_ROOT_CA_DIR="$stick/k3s-root-ca" bash scripts/generate-cluster-ca.sh

check_decrypt() {
  local file="$1" key="$2" name="$3" plaintext="$4"
  if [ -n "$plaintext" ]; then
    age -d -i "$key" "secrets/$file" | cmp -s - "$plaintext" || fail "secrets/$file does not decrypt to $plaintext with the $name key"
  else
    age -d -i "$key" "secrets/$file" > /dev/null || fail "secrets/$file does not decrypt with the $name key"
  fi
}

while IFS= read -r file; do
  [ -f "secrets/$file" ] || continue
  expected="$(secret_recipients "$rules" "$file" | wc -l | tr -d ' ')"
  [ "$(age_stanza_count "secrets/$file")" -eq "$expected" ] \
    || fail "secrets/$file does not hold one stanza for each of its $expected recipients in secrets/secrets.nix"
  plaintext=""
  if [[ " ${TOKENS[*]} " == *" ${file%.age} "* ]]; then plaintext="$keys/${file%.age}"; fi
  check_decrypt "$file" "$identity" break-glass "$plaintext"
  for host in "${hosts[@]}"; do
    if stick_host_is_recipient "$rules" "$file" "$host"; then
      check_decrypt "$file" "$(stick_host_key "$host")" "$host" "$plaintext"
    fi
  done
done < <(jq -r 'keys[]' <<< "$rules")

for file in "${SERVER_FILES[@]}"; do
  check_decrypt "$file" "$(stick_host_key "$control_plane")" "$control_plane" ""
done
for node in "${nodes[@]}"; do
  check_decrypt "$AGENT_FILE" "$(stick_host_key "$node")" "$node" ""
done

echo "Re-keyed and verified every file in secrets/. Changed, not staged:"
git status --short -- secrets
