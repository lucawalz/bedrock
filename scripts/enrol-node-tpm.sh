#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -eq 1 ] || { echo "usage: enrol-node-tpm.sh <node>" >&2; exit 2; }
node="$1"

require_tools nix ssh

stick_root="${BEDROCK_STICK_ROOT:-/Volumes/bedrock-keys/bedrock}"
keys="$stick_root/rebuild-keys"
passphrase_file="$keys/luks-install-passphrase"
host_public_key="$keys/hosts/$node/etc/ssh/ssh_host_ed25519_key.pub"
recovery_dir="$stick_root/luks-recovery"
recovery_file="$recovery_dir/$node"
estate_root="$repo_root/hosts/common/estate-root.pub"
SECRETIVE_SOCKET="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
SHORT_TMP_ROOT=/tmp
CONTROL_PERSIST=10m
ROOT_DEVICE=/dev/disk/by-partlabel/disk-main-root
TPM2_PCRS=0+7
SECURE_BOOT_USER_MODE='Secure Boot: enabled (user)'

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$passphrase_file" "$host_public_key"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick"
done
[ ! -e "$recovery_file" ] || fail "$recovery_file already exists; $node was enrolled before, so move it aside only if that enrolment is gone"

work="$(mktemp -d "$SHORT_TMP_ROOT/enrol-node.XXXXXX")"
printf '%s %s\n' "$address" "$(cut -d' ' -f1,2 "$host_public_key")" > "$work/known_hosts"
ssh_args=(
  -o "IdentityAgent=$SECRETIVE_SOCKET"
  -o "IdentityFile=$estate_root"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$work/known_hosts"
  -o ControlMaster=auto
  -o "ControlPath=$work/%C"
  -o "ControlPersist=$CONTROL_PERSIST"
)
cleanup() {
  ssh "${ssh_args[@]}" -O exit "root@$address" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

node_run=(ssh "${ssh_args[@]}" "root@$address")

boot_status="$("${node_run[@]}" bootctl status)"
grep -qF "$SECURE_BOOT_USER_MODE" <<< "$boot_status" || fail "$node does not report '$SECURE_BOOT_USER_MODE'; enable Secure Boot in the firmware first"

"${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$ROOT_DEVICE" < "$passphrase_file"

mkdir -p "$recovery_dir"
if ! (umask 077; set -o noclobber; "${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --recovery-key "$ROOT_DEVICE" \
  < "$passphrase_file" > "$recovery_file"); then
  rm -f "$recovery_file"
  fail "the recovery key enrolment failed; the password slot stays"
fi
[ -s "$recovery_file" ] || { rm -f "$recovery_file"; fail "the recovery key came back empty; the password slot stays"; }

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
for token in systemd-tpm2 systemd-recovery; do
  grep -Eq "^[[:space:]]+[0-9]+: $token\$" <<< "$tokens" || fail "$ROOT_DEVICE has no $token token; the password slot stays"
done

"${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --wipe-slot=password "$ROOT_DEVICE" < "$passphrase_file"
echo "$node unlocks from the TPM with PCRs $TPM2_PCRS; its recovery key is in $recovery_file and the install passphrase slot is wiped."
