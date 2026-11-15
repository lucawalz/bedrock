#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 1 ] || { echo "usage: reenrol-node-tpm.sh <node>" >&2; exit 2; }
node="$1"

require_tools nix ssh

host_public_key="$(rebuild_keys_dir)/hosts/$node/etc/ssh/ssh_host_ed25519_key.pub"
recovery_file="$(stick_root)/luks-recovery/$node"
CONTROL_PERSIST=10m
ROOT_DEVICE=/dev/disk/by-partlabel/disk-main-root
TPM2_PCRS="$(tpm2_unlock_pcrs)"
SECURE_BOOT_USER_MODE='Secure Boot: enabled (user)'
TPM2_TOKEN=systemd-tpm2
RECOVERY_TOKEN=systemd-recovery

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$host_public_key" "$recovery_file"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick"
done
fallback="type the recovery key from $recovery_file at the console prompt, then run on $node: systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=$TPM2_PCRS $ROOT_DEVICE"

open_ssh_session reenrol-node "$CONTROL_PERSIST"
known_hosts="$ssh_session_dir/known_hosts"
printf '%s %s\n' "$address" "$(cut -d' ' -f1,2 "$host_public_key")" > "$known_hosts"
ssh_args=("${ssh_session_args[@]}" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
trap 'close_ssh_session "root@$address"' EXIT

node_run=(ssh "${ssh_args[@]}" "root@$address")
has_token() { grep -Eq "^[[:space:]]+[0-9]+: $1\$" <<< "$2"; }

boot_status="$("${node_run[@]}" bootctl status)"
grep -qF "$SECURE_BOOT_USER_MODE" <<< "$boot_status" || fail "$node does not report '$SECURE_BOOT_USER_MODE'; enable Secure Boot in the firmware first"

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
has_token "$RECOVERY_TOKEN" "$tokens" || fail "$ROOT_DEVICE has no $RECOVERY_TOKEN token; not re-enrolling without a recovery key"
has_token "$TPM2_TOKEN" "$tokens" || fail "$ROOT_DEVICE has no $TPM2_TOKEN token to unlock with; $fallback"

"${node_run[@]}" systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$ROOT_DEVICE" \
  || fail "the current TPM slot did not unlock $ROOT_DEVICE or the enrolment failed; $fallback"

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
awk '/^Keyslots:/ { on = 1 } /^Digests:/ { on = 0 } on && (/^[A-Z][a-z]+:$/ || /^  [0-9]+: / || /^[[:space:]]+Keyslot:/)' <<< "$tokens"
for token in "$TPM2_TOKEN" "$RECOVERY_TOKEN"; do
  has_token "$token" "$tokens" || fail "$ROOT_DEVICE has no $token token after the re-enrolment; $fallback"
done

echo "$node now unseals with PCRs $TPM2_PCRS. Reboot it to apply the policy: ssh root@$address systemctl reboot"
echo "If it stops at the passphrase prompt, $fallback"
