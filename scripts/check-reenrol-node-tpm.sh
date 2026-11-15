#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

reenrol=scripts/reenrol-node-tpm.sh
node=worker-1
root_device=/dev/disk/by-partlabel/disk-main-root
tpm2_policy="0+7+15:sha256=$(printf '0%.0s' {1..64})"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
stick="$work/stick"
tree="$stick/rebuild-keys/hosts/$node"
mkdir -p "$tree/etc/ssh" "$stick/luks-recovery"
echo "ssh-ed25519 AAAAtestkey root@$node" > "$tree/etc/ssh/ssh_host_ed25519_key.pub"
recovery="$stick/luks-recovery/$node"
echo test-recovery-key > "$recovery"

cat > "$work/bin/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >> "$FAKE_LOG"
[ -z "$FAKE_UNREACHABLE" ] || exit 255
case "$*" in
  *"bootctl status"*) echo "  Secure Boot: ${FAKE_SECURE_BOOT:-enabled (user)}" ;;
  *systemd-cryptenroll*)
    [ -z "$FAKE_ENROL_EXIT" ] || exit "$FAKE_ENROL_EXIT"
    if [ "$FAKE_LOST_TOKEN" = systemd-tpm2 ]; then grep -v systemd-tpm2 "$FAKE_TOKENS" > "$FAKE_TOKENS.new"; mv "$FAKE_TOKENS.new" "$FAKE_TOKENS"; fi ;;
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
  printf '%s' "${FAKE_INITIAL_TOKENS-systemd-tpm2 systemd-recovery}" | tr ' ' '\n' > "$work/tokens"; echo >> "$work/tokens"
  FAKE_LOG="$work/log" FAKE_TOKENS="$work/tokens" BEDROCK_STICK_ROOT="$stick" PATH="$work/bin:$PATH" \
    bash "$reenrol" "$@" > "$work/output" 2>&1
}

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -q 'systemd-cryptenroll' "$work/log"; then fail "$reason still re-enrolled"; fi
}

run "$node" || { cat "$work/output" >&2; fail "a valid re-enrolment failed"; }
[ "$(grep -c 'systemd-cryptenroll' "$work/log")" = 1 ] || fail "the re-enrolment did not run exactly one cryptenroll"
grep -q -- "systemd-cryptenroll --unlock-tpm2-device=auto --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=$tpm2_policy $root_device\$" "$work/log" \
  || fail "the TPM slot was not replaced with $tpm2_policy using the current TPM slot"
grep -o -e '--wipe-slot=[^ ]*' "$work/log" | grep -vx -- '--wipe-slot=tpm2' && fail "the re-enrolment wiped a slot other than tpm2"
if grep -q -e 'recovery-key' -e 'unlock-key-file' -e 'reboot' "$work/log"; then fail "the re-enrolment touched the recovery slot, the passphrase or rebooted"; fi
grep '^ssh ' "$work/log" | grep -v -e "StrictHostKeyChecking=yes" -e ' -O exit ' && fail "a re-enrolment ssh call does not pin the host key"
for summary in '^Keyslots:$' '^Tokens:$' '^  [0-9]*: systemd-tpm2$' '^  [0-9]*: systemd-recovery$' 'Keyslot:'; do
  grep -q "$summary" "$work/output" || fail "the re-enrolment summary lacks $summary"
done
if grep -q 'Digests:' "$work/output"; then fail "the summary printed more than the slots and tokens"; fi
grep -q 'reboot' "$work/output" || fail "the re-enrolment did not print the reboot step"
grep -qF "$recovery" "$work/output" || fail "the reboot step does not name the recovery key fallback"

refused "an unknown node" worker-9
refused "a missing node argument"
FAKE_UNREACHABLE=1 refused "an unreachable node" "$node"
FAKE_SECURE_BOOT="disabled (setup)" refused "Secure Boot in setup mode" "$node"
FAKE_INITIAL_TOKENS=systemd-recovery refused "a volume without a TPM slot" "$node"
grep -qF "$recovery" "$work/output" || fail "a volume without a TPM slot does not name the recovery key fallback"
FAKE_INITIAL_TOKENS=systemd-tpm2 refused "a volume without a recovery slot" "$node"
mv "$recovery" "$work/recovery"
refused "a stick without the node's recovery key" "$node"
mv "$work/recovery" "$recovery"

if FAKE_ENROL_EXIT=1 run "$node"; then fail "a re-enrolment whose TPM unlock failed succeeded"; fi
grep -qF "$recovery" "$work/output" || fail "a failed TPM unlock does not name the recovery key fallback"
if FAKE_LOST_TOKEN=systemd-tpm2 run "$node"; then fail "a re-enrolment that left no TPM slot succeeded"; fi
grep -qF "$recovery" "$work/output" || fail "a lost TPM slot does not name the recovery key fallback"

echo "reenrol-node-tpm replaces only the TPM slot with the PCR 15 policy, refuses every unsafe start and never reboots."
