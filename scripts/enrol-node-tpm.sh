#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 1 ] || { echo "usage: enrol-node-tpm.sh <node>" >&2; exit 2; }
node="$1"

require_tools nix ssh

keys="$(rebuild_keys_dir)"
passphrase_file="$keys/luks-install-passphrase"
host_public_key="$keys/hosts/$node/etc/ssh/ssh_host_ed25519_key.pub"
recovery_dir="$(stick_root)/luks-recovery"
recovery_file="$recovery_dir/$node"
partial_file="$recovery_dir/.$node.partial"
CONTROL_PERSIST=10m
ROOT_DEVICE=/dev/disk/by-partlabel/disk-main-root
TPM2_PCRS=0+7
SECURE_BOOT_USER_MODE='Secure Boot: enabled (user)'
TPM2_TOKEN=systemd-tpm2
REQUIRED_TOKENS=("$TPM2_TOKEN" systemd-recovery)

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$passphrase_file" "$host_public_key"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick"
done
[ ! -e "$recovery_file" ] || fail "$recovery_file already exists; $node was enrolled before, so move it aside only if that enrolment is gone"

mkdir -p "$recovery_dir"
(umask 077; set -o noclobber; : > "$partial_file") || fail "$partial_file exists from an earlier run; check it for a recovery key before removing it"
partial_owned=true

open_ssh_session enrol-node "$CONTROL_PERSIST"
known_hosts="$ssh_session_dir/known_hosts"
printf '%s %s\n' "$address" "$(cut -d' ' -f1,2 "$host_public_key")" > "$known_hosts"
ssh_args=()
for option in "${ssh_session_options[@]}"; do ssh_args+=(-o "$option"); done
ssh_args+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")

cleanup() {
  if $partial_owned; then rm -f "$partial_file"; fi
  close_ssh_session "root@$address"
}
trap cleanup EXIT

node_run=(ssh "${ssh_args[@]}" "root@$address")
has_token() { grep -Eq "^[[:space:]]+[0-9]+: $1\$" <<< "$2"; }

boot_status="$("${node_run[@]}" bootctl status)"
grep -qF "$SECURE_BOOT_USER_MODE" <<< "$boot_status" || fail "$node does not report '$SECURE_BOOT_USER_MODE'; enable Secure Boot in the firmware first"

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
if has_token "$TPM2_TOKEN" "$tokens"; then
  echo "$ROOT_DEVICE already has a $TPM2_TOKEN token; not enrolling the TPM again."
else
  "${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$ROOT_DEVICE" < "$passphrase_file"
fi

"${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --recovery-key "$ROOT_DEVICE" < "$passphrase_file" >> "$partial_file" \
  || fail "the recovery key enrolment failed; the password slot stays"
[ -s "$partial_file" ] || fail "the recovery key came back empty; the password slot stays"
mv -n "$partial_file" "$recovery_file"
if [ -e "$partial_file" ]; then
  partial_owned=false
  fail "$recovery_file appeared during the run; the new recovery key stays in $partial_file and the password slot stays"
fi

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
for token in "${REQUIRED_TOKENS[@]}"; do
  has_token "$token" "$tokens" || fail "$ROOT_DEVICE has no $token token; the password slot stays"
done

"${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --wipe-slot=password "$ROOT_DEVICE" < "$passphrase_file"
echo "$node unlocks from the TPM with PCRs $TPM2_PCRS; its recovery key is in $recovery_file and the install passphrase slot is wiped."
