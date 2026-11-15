#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

reenrol=scripts/reenrol-node-tpm.sh
node=worker-1
root_device=/dev/disk/by-partlabel/disk-main-root
tpm2_policy="0:sha256+7:sha256+15:sha256=$(printf '%0*d' "$SHA256_HEX_LENGTH" 0)"
recovery_key=test-recovery-key-abcdef

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
stick="$work/stick"
tree="$stick/rebuild-keys/hosts/$node"
mkdir -p "$tree/etc/ssh" "$stick/luks-recovery"
echo "ssh-ed25519 AAAAtestkey root@$node" > "$tree/etc/ssh/ssh_host_ed25519_key.pub"
recovery="$stick/luks-recovery/$node"
echo "$recovery_key" > "$recovery"

cat > "$work/bin/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >> "$FAKE_LOG"
[ -z "$FAKE_UNREACHABLE" ] || exit 255
case "$*" in
  *"bootctl status"*) echo "  Secure Boot: ${FAKE_SECURE_BOOT:-enabled (user)}" ;;
  *"cat /proc/cmdline"*) echo "initrd=x ${FAKE_CMDLINE-systemd.tpm2_measured_os=1} root=fstab loglevel=4" ;;
  *"cat /run/log/systemd/tpm2-measure.log"*)
    [ -n "$FAKE_NO_MEASURE" ] || printf '\036{"pcr":15,"digests":[],"content_type":"systemd","content":{"string":"cryptsetup:cryptroot:1234","eventType":"volume-key"}}\n' ;;
  *"systemd-analyze pcrs 15"*) printf 'NR NAME            SHA256\n15 system-identity %s\n' "${FAKE_PCR15:-9c905bd9b9891bfb889b90a54c4b537b889cfa817c4389cc25754823a9443255}" ;;
  *"--unlock-tpm2-device"*) cat > /dev/null; [ -n "$FAKE_TPM_UNSEALS" ] || exit 1 ;;
  *systemd-cryptenroll*)
    cat > "$FAKE_STDIN"
    [ -z "$FAKE_ENROL_EXIT" ] || exit "$FAKE_ENROL_EXIT"
    grep -qx systemd-tpm2 "$FAKE_TOKENS" || echo systemd-tpm2 >> "$FAKE_TOKENS"
    if [ -n "$FAKE_LOST_TOKEN" ]; then grep -vx "$FAKE_LOST_TOKEN" "$FAKE_TOKENS" > "$FAKE_TOKENS.new"; mv "$FAKE_TOKENS.new" "$FAKE_TOKENS"; fi ;;
  *luksDump*)
    printf 'LUKS header information\nKeyslots:\n'
    n=0; while read -r token; do printf '  %s: luks2\n\tKey:        512 bits\n' "$n"; n=$((n + 1)); done < "$FAKE_TOKENS"
    printf 'Tokens:\n'
    n=0; while read -r token; do printf '  %s: %s\n\tKeyslot:    %s\n' "$n" "$token" "$n"; n=$((n + 1)); done < "$FAKE_TOKENS"
    printf 'Digests:\n  0: pbkdf2\n' ;;
esac
FAKE
cat > "$work/bin/nix" <<'FAKE'
#!/bin/sh
printf 'control-plane-1 10.20.0.10\nworker-1 10.20.0.11\nworker-2 10.20.0.12'
FAKE
chmod +x "$work"/bin/*

run() {
  : > "$work/log"
  rm -f "$work/stdin"
  printf '%s' "${FAKE_INITIAL_TOKENS-systemd-tpm2 systemd-recovery}" | tr ' ' '\n' > "$work/tokens"; echo >> "$work/tokens"
  FAKE_LOG="$work/log" FAKE_STDIN="$work/stdin" FAKE_TOKENS="$work/tokens" BEDROCK_STICK_ROOT="$stick" PATH="$work/bin:$PATH" \
    bash "$reenrol" "$@" > "$work/output" 2>&1
}

key_leaked() { grep -qF "$recovery_key" "$work/log" "$work/output"; }

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -q 'systemd-cryptenroll' "$work/log"; then fail "$reason still ran cryptenroll"; fi
  if key_leaked; then fail "$reason leaked the recovery key"; fi
}

run "$node" || { cat "$work/output" >&2; fail "a valid re-enrolment failed"; }
[ "$(grep -c 'systemd-cryptenroll' "$work/log")" = 1 ] || fail "the re-enrolment did not run exactly one cryptenroll"
grep -q -- "systemd-cryptenroll --unlock-key-file=/dev/stdin --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=$tpm2_policy $root_device\$" "$work/log" \
  || fail "the TPM slot was not replaced with $tpm2_policy using the recovery key"
printf '%s' "$recovery_key" | cmp -s - "$work/stdin" || fail "cryptenroll did not get the recovery key without its newline on stdin"
if key_leaked; then fail "the recovery key appeared in an ssh argument or the output"; fi
grep -o -e '--wipe-slot=[^ ]*' "$work/log" | grep -vx -- '--wipe-slot=tpm2' && fail "the re-enrolment wiped a slot other than tpm2"
if grep -q -e 'recovery-key' -e 'reboot' "$work/log"; then fail "the re-enrolment enrolled a recovery key or rebooted"; fi
grep '^ssh ' "$work/log" | grep -v -e "StrictHostKeyChecking=yes" -e ' -O exit ' && fail "a re-enrolment ssh call does not pin the host key"
for summary in '^Keyslots:$' '^Tokens:$' '^  [0-9]*: systemd-tpm2$' '^  [0-9]*: systemd-recovery$' 'Keyslot:'; do
  grep -q "$summary" "$work/output" || fail "the re-enrolment summary lacks $summary"
done
if grep -q 'Digests:' "$work/output"; then fail "the summary printed more than the slots and tokens"; fi
grep -q 'systemctl reboot' "$work/output" || fail "the re-enrolment did not print the reboot step"
grep -q "just reenrol-node-tpm $node verify" "$work/output" || fail "the re-enrolment did not print the verify step"

FAKE_INITIAL_TOKENS=systemd-recovery run "$node" || fail "a volume that lost its TPM slot was not re-enrolled"

refused "an unknown node" worker-9
refused "a missing node argument"
refused "an unknown mode" "$node" migrate
FAKE_UNREACHABLE=1 refused "an unreachable node" "$node"
FAKE_SECURE_BOOT="disabled (setup)" refused "Secure Boot in setup mode" "$node"
FAKE_INITIAL_TOKENS=systemd-tpm2 refused "a volume without a recovery slot" "$node"
FAKE_CMDLINE="" refused "a boot without systemd.tpm2_measured_os=1" "$node"
FAKE_NO_MEASURE=1 refused "a boot whose stage 1 did not measure the volume key" "$node"
grep -q 'just deploy-nodes' "$work/output" || fail "an unmeasured boot does not name the deploy and reboot"
mv "$recovery" "$work/recovery"
refused "a stick without the node's recovery key" "$node"
mv "$work/recovery" "$recovery"

if FAKE_ENROL_EXIT=1 run "$node"; then fail "a re-enrolment whose unlock failed succeeded"; fi
grep -qF "$recovery" "$work/output" || fail "a failed unlock does not name the recovery key file"
if key_leaked; then fail "a failed unlock leaked the recovery key"; fi
for lost in systemd-tpm2 systemd-recovery; do
  if FAKE_LOST_TOKEN="$lost" run "$node"; then fail "a re-enrolment that left no $lost token succeeded"; fi
done

run "$node" verify || { cat "$work/output" >&2; fail "verifying a protected node failed"; }
grep -q -- "systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=$tpm2_policy $root_device\$" "$work/log" \
  || fail "the verify did not attempt a TPM-only unseal"
if grep -q -e 'unlock-key-file' "$work/log" || [ -e "$work/stdin" ]; then fail "the verify used the recovery key"; fi
if key_leaked; then fail "the verify leaked the recovery key"; fi
if FAKE_TPM_UNSEALS=1 run "$node" verify; then fail "a TPM that still unseals on the running system passed the verify"; fi
if FAKE_PCR15="$(printf '%0*d' "$SHA256_HEX_LENGTH" 0)" run "$node" verify; then fail "an all-zero PCR 15 passed the verify"; fi
if FAKE_NO_MEASURE=1 run "$node" verify; then fail "a boot without a volume key measurement passed the verify"; fi
if FAKE_CMDLINE="" run "$node" verify; then fail "a boot without systemd.tpm2_measured_os=1 passed the verify"; fi
if FAKE_INITIAL_TOKENS=systemd-recovery run "$node" verify; then fail "a volume without a TPM slot passed the verify"; fi

echo "reenrol-node-tpm replaces only the TPM slot with the PCR 15 policy over ssh, refuses unmeasured boots and verifies the TPM no longer unseals."
