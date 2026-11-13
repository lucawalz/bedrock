#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools age age-keygen ssh-keygen nix jq shasum

hosts=(control-plane-1 worker-1 worker-2 router)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
stick="$work/stick"
keys="$stick/rebuild-keys"
mkdir -p "$repo/scripts/lib" "$repo/secrets" "$work/bin" "$work/other"
cp scripts/tailscale-authkeys.sh "$repo/scripts/"
cp scripts/lib/common.sh "$repo/scripts/lib/"

host_key() { printf '%s\n' "$keys/hosts/$1/etc/ssh/ssh_host_ed25519_key"; }

for host in "${hosts[@]}"; do
  mkdir -p "$keys/hosts/$host/etc/ssh"
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$(host_key "$host")"
done
ssh-keygen -q -t ed25519 -N "" -C root@router -f "$work/other/router"
ssh-keygen -q -t ed25519 -N "" -C estate-breakglass -f "$work/breakglass"
age-keygen -o "$work/admin.txt" 2>/dev/null

write_rules() {
  local router_pub="$1" expression=() host
  for host in control-plane-1 worker-1 worker-2; do
    expression+=(-e "s|^  $host = \".*\";\$|  $host = \"$(cat "$(host_key "$host").pub")\";|")
  done
  sed "${expression[@]}" \
    -e "s|^  router = \".*\";\$|  router = \"$(cat "$router_pub")\";|" \
    -e "s|^  luca-secure-enclave = \".*\";\$|  luca-secure-enclave = \"$(age-keygen -y "$work/admin.txt")\";|" \
    -e "s|^  estate-breakglass = \".*\";\$|  estate-breakglass = \"$(cat "$work/breakglass.pub")\";|" \
    secrets/secrets.nix > "$repo/secrets/secrets.nix"
}

cat > "$work/bin/pbcopy" <<'FAKE'
#!/bin/sh
cat > "$FAKE_CLIPBOARD"
echo "pbcopy $(cat "$FAKE_CLIPBOARD")" >> "$FAKE_LOG"
FAKE
: > "$work/bin/age-plugin-se"
chmod +x "$work"/bin/*

run() {
  : > "$work/log"
  echo stale > "$work/clipboard"
  printf '%s\n' "$@" | FAKE_LOG="$work/log" FAKE_CLIPBOARD="$work/clipboard" BEDROCK_STICK_ROOT="$stick" PATH="$work/bin:$PATH" \
    bash "$repo/scripts/tailscale-authkeys.sh" > "$work/output" 2>&1
}

written() { find "$repo/secrets" -name 'tailscale-authkey*.age' | wc -l | tr -d ' '; }

stanzas() { awk '/^---/ { exit } /^-> / { count++ } END { print count + 0 }' "$repo/secrets/$1"; }

listed() { nix eval --json --file "$repo/secrets/secrets.nix" | jq --arg file "$1" '.[$file].publicKeys | length'; }

secret_file() {
  case "$1" in
    router) echo tailscale-authkey.age ;;
    *) echo "tailscale-authkey-$1.age" ;;
  esac
}

typed=()
for host in "${hosts[@]}"; do typed+=("tskey-auth-k$host-$RANDOM$RANDOM"); done

write_rules "$work/other/router.pub"
if run "${typed[@]}"; then fail "a secrets.nix without the stick router key was not refused"; fi
grep -q "tailscale-authkey.age;" "$work/output" || fail "the host key refusal does not name tailscale-authkey.age"
[ "$(written)" -eq 0 ] || fail "a refused run wrote a key"

write_rules "$(host_key router).pub"
for bad in "" "tskey-client-k123" "tskey-auth"; do
  if run "$bad" "${typed[@]:1}"; then fail "the key '$bad' was not refused"; fi
  [ "$(written)" -eq 0 ] || fail "a refused key '$bad' was written"
  [ ! -s "$work/clipboard" ] || fail "the clipboard was not cleared after a refused key"
done

run "${typed[@]}" || { cat "$work/output" >&2; fail "a valid run failed"; }
for index in "${!hosts[@]}"; do
  host="${hosts[$index]}"
  file="$(secret_file "$host")"
  [ -f "$repo/secrets/$file" ] || fail "$file was not written"
  [ "$(stanzas "$file")" -eq "$(listed "$file")" ] || fail "$file does not hold one stanza per recipient in secrets.nix"
  age -d -i "$(host_key "$host")" "$repo/secrets/$file" | cmp -s - <(printf '%s' "${typed[$index]}") \
    || fail "$file does not decrypt to the key typed for $host with the $host key"
  age -d -i "$work/breakglass" "$repo/secrets/$file" > /dev/null 2>&1 || fail "$file does not decrypt with the break-glass key"
done
if age -d -i "$(host_key worker-1)" "$repo/secrets/tailscale-authkey-control-plane-1.age" > /dev/null 2>&1; then
  fail "worker-1 decrypts the control-plane-1 auth key"
fi
grep -q '^pbcopy $' "$work/log" || fail "the clipboard was not cleared"
[ ! -s "$work/clipboard" ] || fail "the clipboard still holds data"
for key in "${typed[@]}"; do
  if grep -qF "$key" "$work/output"; then fail "the run printed an auth key"; fi
done

echo "tailscale-authkeys refuses bad keys and missing host keys, and writes each key to its secrets.nix recipients."
