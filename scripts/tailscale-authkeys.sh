#!/usr/bin/env bash
set -euo pipefail
umask 077

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 0 ] || { echo "usage: tailscale-authkeys.sh" >&2; exit 2; }

PATH="$PATH:/opt/homebrew/bin"
require_tools nix jq age pbcopy cmp age-plugin-se

KEY_PREFIX=tskey-auth-
SECRET_PATTERN='^tailscale-authkey.*\.age$'

[ -d "${TMPDIR:-/tmp}" ] || fail "TMPDIR $TMPDIR does not exist; unset it"
[ -d "$(rebuild_keys_dir)/hosts" ] || fail "$(rebuild_keys_dir)/hosts is missing; mount the bedrock-keys stick"

rules="$(secret_rules)"
hosts=()
while IFS= read -r host; do hosts+=("$host"); done < <(stick_hosts)

files=()
owners=()
while IFS= read -r file; do
  owner=""
  for host in "${hosts[@]}"; do
    if stick_host_is_recipient "$rules" "$file" "$host"; then
      [ -z "$owner" ] || fail "secrets/$file lists both $owner and $host; each auth key belongs to one host"
      owner="$host"
    fi
  done
  [ -n "$owner" ] || fail "secrets/secrets.nix lists no stick host key for $file; copy the router and node keys from $(rebuild_keys_dir)/hosts first"
  files+=("$file")
  owners+=("$owner")
done < <(jq -r --arg pattern "$SECRET_PATTERN" 'keys[] | select(test($pattern))' <<< "$rules")
[ "${#files[@]}" -gt 0 ] || fail "secrets/secrets.nix has no tailscale-authkey entry"

work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  pbcopy < /dev/null
  echo "Clipboard cleared."
}
trap cleanup EXIT

for index in "${!files[@]}"; do
  file="${files[$index]}"
  host="${owners[$index]}"
  read -rsp "Tailscale auth key for $host (secrets/$file): " key
  echo >&2
  [ -n "$key" ] || fail "the key for $host is empty"
  [[ "$key" == "$KEY_PREFIX"?* ]] || fail "the key for $host does not start with $KEY_PREFIX"
  printf '%s' "$key" | age -R <(secret_recipients "$rules" "$file") -o "$work/$file"
  [ "$(age_stanza_count "$work/$file")" -eq "$(secret_recipients "$rules" "$file" | wc -l)" ] \
    || fail "$file does not hold one stanza per recipient in secrets/secrets.nix"
  age -d -i "$(stick_host_key "$host")" "$work/$file" | cmp -s - <(printf '%s' "$key") \
    || fail "$file does not decrypt to the typed key with the $host key"
  unset key
  mv "$work/$file" "secrets/$file"
  echo "Wrote secrets/$file for $host."
done
