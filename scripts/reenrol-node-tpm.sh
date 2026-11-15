#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VERIFY_MODE=verify
usage="usage: reenrol-node-tpm.sh <node> [$VERIFY_MODE]"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "$usage" >&2; exit 2; }
node="$1"
mode="${2:-}"
[ -z "$mode" ] || [ "$mode" = "$VERIFY_MODE" ] || { echo "$usage" >&2; exit 2; }

require_tools nix ssh

host_public_key="$(stick_host_key "$node").pub"
recovery_file="$(stick_root)/luks-recovery/$node"
CONTROL_PERSIST=10m
ROOT_DEVICE=/dev/disk/by-partlabel/disk-main-root
TPM2_PCRS="$(tpm2_unlock_pcrs)"
SECURE_BOOT_USER_MODE='Secure Boot: enabled (user)'
MEASURED_OS_PARAMETER=systemd.tpm2_measured_os=1
MEASURE_LOG=/run/log/systemd/tpm2-measure.log
ROOT_VOLUME_RECORD='"string" *: *"cryptsetup:cryptroot:'
TPM2_TOKEN=systemd-tpm2
RECOVERY_TOKEN=systemd-recovery
STATE_MISMATCH='No TPM2 metadata matching the current system state'
DRAIN_STEPS='the Planned drain steps in docs/disaster-recovery.md'

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$host_public_key" "$recovery_file"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick"
done

open_ssh_session reenrol-node "$CONTROL_PERSIST"
pin_node_host_key "$address" "$host_public_key"
trap 'close_ssh_session "root@$address"' EXIT
node_run=(ssh "${ssh_session_args[@]}" "root@$address")

boot_status="$("${node_run[@]}" bootctl status)"
grep -qF "$SECURE_BOOT_USER_MODE" <<< "$boot_status" || fail "$node does not report '$SECURE_BOOT_USER_MODE'; enable Secure Boot in the firmware first"

unmeasured="reboot $node through $DRAIN_STEPS onto the generation from just deploy-nodes, which carries $MEASURED_OS_PARAMETER and tpm2-measure-pcr=yes"
cmdline="$("${node_run[@]}" cat /proc/cmdline)"
grep -qw -- "$MEASURED_OS_PARAMETER" <<< "$cmdline" || fail "the running kernel of $node lacks $MEASURED_OS_PARAMETER; $unmeasured"
measure_log="$("${node_run[@]}" cat "$MEASURE_LOG")" || fail "$MEASURE_LOG is missing on $node; $unmeasured"
grep -Eq "$ROOT_VOLUME_RECORD" <<< "$measure_log" || fail "stage 1 of $node did not measure the cryptroot volume key into PCR $TPM2_VOLUME_KEY_PCR; $unmeasured"
pcr="$("${node_run[@]}" systemd-analyze pcrs "$TPM2_VOLUME_KEY_PCR" | awk -v pcr="$TPM2_VOLUME_KEY_PCR" '$1 == pcr { print $3 }')"
[[ "$pcr" =~ ^[0-9a-f]+$ ]] && [[ "$pcr" =~ [1-9a-f] ]] || fail "PCR $TPM2_VOLUME_KEY_PCR on $node is '$pcr', not a measured value; $unmeasured"

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
luks_has_token "$RECOVERY_TOKEN" "$tokens" || fail "$ROOT_DEVICE has no $RECOVERY_TOKEN token; not re-enrolling without a recovery key"

if [ "$mode" = "$VERIFY_MODE" ]; then
  luks_has_token "$TPM2_TOKEN" "$tokens" || fail "$ROOT_DEVICE has no $TPM2_TOKEN token; run just reenrol-node-tpm $node"
  if unseal="$("${node_run[@]}" systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$ROOT_DEVICE" < /dev/null 2>&1)"; then
    fail "the TPM of $node still unseals on the running system, so its slot is not bound to PCR $TPM2_VOLUME_KEY_PCR; run just reenrol-node-tpm $node"
  fi
  grep -qF "$STATE_MISMATCH" <<< "$unseal" || fail "the TPM-only unseal on $node failed for another reason than the PCR state: $unseal"
  echo "$node measured its root volume key into PCR $TPM2_VOLUME_KEY_PCR ($pcr) and its TPM no longer unseals on the running system."
  exit 0
fi

tr -d '\n' < "$recovery_file" \
  | "${node_run[@]}" systemd-cryptenroll --unlock-key-file=/dev/stdin --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$ROOT_DEVICE" \
  || fail "the recovery key in $recovery_file did not unlock $ROOT_DEVICE or the enrolment failed; the existing slots stay"

tokens="$("${node_run[@]}" cryptsetup luksDump "$ROOT_DEVICE")"
awk '/^Keyslots:/ { on = 1 } /^Digests:/ { on = 0 } on && (/^[A-Z][a-z]+:$/ || /^  [0-9]+: / || /^[[:space:]]+Keyslot:/)' <<< "$tokens"
for token in "$TPM2_TOKEN" "$RECOVERY_TOKEN"; do
  luks_has_token "$token" "$tokens" || fail "$ROOT_DEVICE has no $token token after the re-enrolment; the recovery key in $recovery_file still opens it"
done

echo "$node is enrolled on PCRs $TPM2_PCRS. Reboot it through $DRAIN_STEPS."
echo "After it unlocks unattended, run: just reenrol-node-tpm $node verify"
echo "If it stops at the passphrase prompt, type the recovery key from $recovery_file at the console, then run: just reenrol-node-tpm $node"
