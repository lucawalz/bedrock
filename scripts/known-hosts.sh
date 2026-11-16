#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools nix jq

known_hosts_file="${BEDROCK_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts.d/bedrock}"

# shellcheck disable=SC2016
host_names='
  .tailnetDomain as $domain | .gateway as $gateway
  | (.nodes | to_entries | map({host: .key, address: .value.address})) + [{host: "router", address: $gateway}]
  | .[] | [.host, ([.host, .address, (.host + "." + $domain)] | join(","))] | @tsv'

rules="$(secret_rules)"
inventory="$(nix eval --json --file "$repo_root/lib/inventory.nix")"

lines=""
while IFS=$'\t' read -r host names; do
  keys="$(jq -r --arg host "$host" '[.[].publicKeys[] | select(endswith(" root@" + $host)) | split(" ")[:2] | join(" ")] | unique | .[]' <<< "$rules")"
  [ -n "$keys" ] || fail "secrets/secrets.nix has no host key for $host"
  [ "$(wc -l <<< "$keys")" -eq 1 ] || fail "secrets/secrets.nix has more than one host key for $host"
  lines+="$names $keys"$'\n'
done < <(jq -r "$host_names" <<< "$inventory")

mkdir -p "$(dirname "$known_hosts_file")"
temporary="$(mktemp "$known_hosts_file.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
printf '%s' "$lines" > "$temporary"
mv "$temporary" "$known_hosts_file"
echo "Wrote $known_hosts_file"
