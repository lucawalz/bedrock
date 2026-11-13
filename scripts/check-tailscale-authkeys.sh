#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixtures.sh"

require_tools age age-keygen ssh-keygen nix jq shasum

hosts=(control-plane-1 worker-1 worker-2 router)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
stick="$work/stick"
export BEDROCK_STICK_ROOT="$stick"
mkdir -p "$repo/scripts/lib" "$repo/secrets" "$work/bin" "$work/bindings"
cp scripts/tailscale-authkeys.sh "$repo/scripts/"
cp scripts/lib/common.sh "$repo/scripts/lib/"
cp secrets/secrets.nix "$work/template.nix"
repo_root="$repo"

fixture_host_keys "$(rebuild_keys_dir)" "${hosts[@]}"
fixture_host_keys "$work/other" router
ssh-keygen -q -t ed25519 -N "" -C estate-breakglass -f "$work/breakglass"
age-keygen -o "$work/admin.txt" 2>/dev/null
for host in "${hosts[@]}"; do cp "$(stick_host_key "$host").pub" "$work/bindings/$host.pub"; done
age-keygen -y "$work/admin.txt" > "$work/bindings/luca-secure-enclave.pub"
cp "$work/breakglass.pub" "$work/bindings/estate-breakglass.pub"

write_rules() { fixture_rules "$work/bindings" "$work/template.nix" "$repo/secrets/secrets.nix"; }

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
  printf '%s\n' "$@" | FAKE_LOG="$work/log" FAKE_CLIPBOARD="$work/clipboard" PATH="$work/bin:$PATH" \
    bash "$repo/scripts/tailscale-authkeys.sh" > "$work/output" 2>&1
}

written() { find "$repo/secrets" -name 'tailscale-authkey*.age' | wc -l | tr -d ' '; }

secret_file() {
  case "$1" in
    router) echo tailscale-authkey.age ;;
    *) echo "tailscale-authkey-$1.age" ;;
  esac
}

typed=()
for host in "${hosts[@]}"; do typed+=("tskey-auth-k$host-$RANDOM$RANDOM"); done

cp "$work/other/hosts/router/etc/ssh/ssh_host_ed25519_key.pub" "$work/bindings/router.pub"
write_rules
if run "${typed[@]}"; then fail "a secrets.nix without the stick router key was not refused"; fi
grep -q "tailscale-authkey.age;" "$work/output" || fail "the host key refusal does not name tailscale-authkey.age"
[ "$(written)" -eq 0 ] || fail "a refused run wrote a key"
cp "$(stick_host_key router).pub" "$work/bindings/router.pub"

write_rules
sed -i.orig '/"tailscale-authkey-worker-1.age".publicKeys/,/];/s/^    worker-1$/    worker-1 worker-2/' "$repo/secrets/secrets.nix"
rm "$repo/secrets/secrets.nix.orig"
if run "${typed[@]}"; then fail "an auth key file with two stick host recipients was not refused"; fi
grep -q "tailscale-authkey-worker-1.age" "$work/output" || fail "the shared recipient refusal does not name tailscale-authkey-worker-1.age"
if grep -q "Tailscale auth key for" "$work/output"; then fail "the shared recipient refusal came after a prompt"; fi
[ "$(written)" -eq 0 ] || fail "a refused run wrote a key"

write_rules
for bad in "" "tskey-client-k123" "tskey-auth"; do
  if run "$bad" "${typed[@]:1}"; then fail "the key '$bad' was not refused"; fi
  [ "$(written)" -eq 0 ] || fail "a refused key '$bad' was written"
  [ ! -s "$work/clipboard" ] || fail "the clipboard was not cleared after a refused key"
done

run "${typed[@]}" || { cat "$work/output" >&2; fail "a valid run failed"; }
rules="$(secret_rules)"
for index in "${!hosts[@]}"; do
  host="${hosts[$index]}"
  file="$(secret_file "$host")"
  [ -f "$repo/secrets/$file" ] || fail "$file was not written"
  [ "$(age_stanza_count "$repo/secrets/$file")" -eq "$(secret_recipients "$rules" "$file" | wc -l)" ] \
    || fail "$file does not hold one stanza per recipient in secrets.nix"
  age -d -i "$(stick_host_key "$host")" "$repo/secrets/$file" | cmp -s - <(printf '%s' "${typed[$index]}") \
    || fail "$file does not decrypt to the key typed for $host with the $host key"
  age -d -i "$work/breakglass" "$repo/secrets/$file" > /dev/null 2>&1 || fail "$file does not decrypt with the break-glass key"
done
if age -d -i "$(stick_host_key worker-1)" "$repo/secrets/tailscale-authkey-control-plane-1.age" > /dev/null 2>&1; then
  fail "worker-1 decrypts the control-plane-1 auth key"
fi
grep -q '^pbcopy $' "$work/log" || fail "the clipboard was not cleared"
[ ! -s "$work/clipboard" ] || fail "the clipboard still holds data"
for key in "${typed[@]}"; do
  if grep -qF "$key" "$work/output"; then fail "the run printed an auth key"; fi
done

echo "tailscale-authkeys refuses bad keys, missing or shared host keys, and writes each key to its secrets.nix recipients."
