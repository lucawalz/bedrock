#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools jq

install=scripts/install-node.sh
enrol=scripts/enrol-node-tpm.sh
node=worker-1
address=10.20.0.11
passphrase=test-install-passphrase
recovery_key=test-recovery-key
estate_root="$PWD/hosts/common/estate-root.pub"
secretive_socket="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
root_device=/dev/disk/by-partlabel/disk-main-root

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
stick="$work/stick"
keys="$stick/rebuild-keys"
tree="$keys/hosts/$node"
mkdir -p "$tree/etc/ssh" "$tree/var/lib/sbctl/keys"
printf '%s' 0b6c7c1e-1111-4222-8333-444455556666 > "$tree/var/lib/sbctl/GUID"
: > "$tree/etc/ssh/ssh_host_ed25519_key"
echo "ssh-ed25519 AAAAtestkey root@$node" > "$tree/etc/ssh/ssh_host_ed25519_key.pub"
printf '%s' "$passphrase" > "$keys/luks-install-passphrase"

cat > "$work/bin/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >> "$FAKE_LOG"
[ -z "$FAKE_UNREACHABLE" ] || exit 255
case "$*" in
  *systemd-cryptenroll*) echo "stdin=$(cat)" >> "$FAKE_LOG" ;;
esac
case "$*" in
  *" hostname") echo "${FAKE_HOSTNAME:-worker-1}" ;;
  *"sbctl status --json"*) printf '{"installed": true, "guid": "x", "setup_mode": %s, "secure_boot": false}\n' "${FAKE_SETUP_MODE:-false}" ;;
  *"systemctl reboot"*) exit "${FAKE_REBOOT_EXIT:-255}" ;;
  *"bootctl status"*) echo "  Secure Boot: ${FAKE_SECURE_BOOT:-enabled (user)}" ;;
  *--tpm2-device*) [ "$FAKE_LOST_TOKEN" = systemd-tpm2 ] || echo systemd-tpm2 >> "$FAKE_TOKENS" ;;
  *--recovery-key*) echo test-recovery-key; [ "$FAKE_LOST_TOKEN" = systemd-recovery ] || echo systemd-recovery >> "$FAKE_TOKENS"; exit "${FAKE_RECOVERY_EXIT:-0}" ;;
  *luksDump*) printf 'Tokens:\n'; n=0; while read -r token; do printf '  %s: %s\n' "$n" "$token"; n=$((n + 1)); done < "$FAKE_TOKENS" ;;
esac
FAKE
cat > "$work/bin/nix" <<'FAKE'
#!/bin/sh
echo "nix $*" >> "$FAKE_LOG"
case "$1" in
  eval) printf 'control-plane-1 10.20.0.10\nworker-1 10.20.0.11\nworker-2 10.20.0.12' ;;
  develop) shift; while [ "$1" != --command ]; do shift; done; shift; exec "$@" ;;
esac
FAKE
cat > "$work/bin/nixos-anywhere" <<'FAKE'
#!/bin/sh
echo "nixos-anywhere $*" >> "$FAKE_LOG"
FAKE
cat > "$work/bin/git" <<'FAKE'
#!/bin/sh
case "$*" in
  "branch --show-current") echo "${FAKE_BRANCH:-main}" ;;
  "status --porcelain") [ -z "$FAKE_DIRTY" ] || echo " M README.md" ;;
esac
FAKE
cat > "$work/bin/pbcopy" <<'FAKE'
#!/bin/sh
cat > "$FAKE_CLIPBOARD"
echo "pbcopy $(cat "$FAKE_CLIPBOARD")" >> "$FAKE_LOG"
FAKE
chmod +x "$work"/bin/*

run() {
  local script="$1"; shift
  : > "$work/log"
  printf '%s' "${FAKE_INITIAL_TOKENS:-}" | tr ' ' '\n' | grep . > "$work/tokens" || true
  printf '%s\n' "${FAKE_ANSWER-$1}" | FAKE_LOG="$work/log" FAKE_CLIPBOARD="$work/clipboard" FAKE_TOKENS="$work/tokens" \
    BEDROCK_STICK_ROOT="$stick" PATH="$work/bin:$PATH" bash "$script" "$@" > "$work/output" 2>&1
}

line_of() { grep -n -m 1 -e "$1" "$work/log" | cut -d: -f1; }

run "$install" "$node" || { cat "$work/output" >&2; fail "a valid install failed"; }
na="$(grep '^nixos-anywhere ' "$work/log")" || fail "nixos-anywhere did not run"
for expected in "--flake .#$node" "--phases kexec,disko,install" "--extra-files $tree" \
  "--ssh-option IdentityAgent=$secretive_socket" "--ssh-option IdentityFile=$estate_root" \
  "--ssh-option IdentitiesOnly=yes" "--ssh-option ControlMaster=auto" "--ssh-option ControlPersist=" "root@$address"; do
  [[ "$na" == *"$expected"* ]] || fail "nixos-anywhere lacks $expected: $na"
done
[[ "$na" != *"--phases "*reboot* ]] || fail "nixos-anywhere reboots before Secure Boot enrolment"
grep -q "^pbcopy $passphrase\$" "$work/log" || fail "the install passphrase was not put on the clipboard"
[ ! -s "$work/clipboard" ] || fail "the clipboard was not cleared on exit"
cleared="$(grep -n -m 1 '^pbcopy $' "$work/log" | cut -d: -f1)"
[ -n "$cleared" ] && [ "$cleared" -gt "$(line_of '^nixos-anywhere')" ] && [ "$cleared" -lt "$(line_of 'enroll-keys')" ] \
  || fail "the clipboard was not cleared between nixos-anywhere and the Secure Boot enrolment"
if grep -qF "$passphrase" "$work/output"; then fail "the install printed the passphrase"; fi
grep -o -e '^nixos-anywhere' -e 'cp -a /mnt/var/lib/sbctl /var/lib/sbctl' -e 'sbctl enroll-keys --microsoft' -e 'systemctl reboot' "$work/log" \
  | tr '\n' ' ' | grep -qx 'nixos-anywhere cp -a /mnt/var/lib/sbctl /var/lib/sbctl sbctl enroll-keys --microsoft systemctl reboot ' \
  || fail "the install, copy of the stick bundle, Secure Boot enrolment and reboot did not run in that order"
grep 'sbctl\|systemctl reboot' "$work/log" | grep -v "ControlPath=/tmp/install-node\." \
  && fail "an installer command does not reuse the control master"

FAKE_HOSTNAME=nixos run "$install" "$node" phases=disko,install || fail "a resumed install failed"
grep -q -- '--phases disko,install ' "$work/log" || fail "the phases argument did not reach nixos-anywhere"
grep -q "This wipes the disk of $node" "$work/output" || fail "the confirmation for a disko run does not mention the wipe"
FAKE_HOSTNAME=nixos run "$install" "$node" install || fail "a target already in the installer was refused"
if grep -q "wipes the disk" "$work/output"; then fail "the confirmation claims a wipe without the disko phase"; fi
FAKE_HOSTNAME=nixos run "$install" "$node" "" || fail "an empty phases argument did not fall back to the default"
grep -q -- '--phases kexec,disko,install ' "$work/log" || fail "an empty phases argument did not use the default phases"

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -q -e '^nixos-anywhere' -e 'systemd-cryptenroll' "$work/log"; then fail "$reason still installed or enrolled"; fi
}

refused "an unknown node" "$install" worker-9
refused "a reboot phase" "$install" "$node" kexec,disko,install,reboot
refused "an unknown phase" "$install" "$node" kexec,format
FAKE_DIRTY=1 refused "a dirty repository" "$install" "$node"
FAKE_BRANCH=feat/x refused "a branch other than main" "$install" "$node"
FAKE_HOSTNAME=worker-2 refused "a target answering as another node" "$install" "$node"
refused "disko without kexec on a running node" "$install" "$node" phases=disko,install
FAKE_UNREACHABLE=1 refused "an unreachable target" "$install" "$node"
FAKE_ANSWER=worker-2 refused "a wrong wipe confirmation" "$install" "$node"
mv "$tree/var/lib/sbctl" "$work/sbctl"
refused "missing stick keys" "$install" "$node"
mv "$work/sbctl" "$tree/var/lib/sbctl"

if FAKE_SETUP_MODE=true run "$install" "$node"; then fail "firmware left in setup mode was not refused"; fi
grep -q 'systemctl reboot' "$work/log" && fail "the installer rebooted with the firmware in setup mode"
if FAKE_REBOOT_EXIT=1 run "$install" "$node"; then fail "a failed unmount and reboot command was reported as success"; fi

recovery="$stick/luks-recovery/$node"
run "$enrol" "$node" || { cat "$work/output" >&2; fail "a valid enrolment failed"; }
[ "$(cat "$recovery")" = "$recovery_key" ] || fail "the recovery key was not written to $recovery"
[ -z "$(find "$recovery" ! -perm 600)" ] || fail "$recovery is not mode 600"
[ "$(find "$stick/luks-recovery" -type f | wc -l)" -eq 1 ] || fail "the enrolment left a partial file next to $recovery"
if grep -qF "$recovery_key" "$work/output"; then fail "the enrolment printed the recovery key"; fi
grep -q -- "--tpm2-device=auto --tpm2-pcrs=0+7 $root_device" "$work/log" || fail "the TPM was not enrolled with PCRs 0+7"
[ "$(grep -c "^stdin=$passphrase\$" "$work/log")" = 3 ] || fail "the passphrase was not handed to each cryptenroll on stdin"
grep -o -e 'tpm2-device' -e 'recovery-key' -e 'luksDump' -e 'wipe-slot=password' "$work/log" | tr '\n' ' ' \
  | grep -Eqx '(luksDump )?tpm2-device recovery-key luksDump wipe-slot=password ' || fail "the password slot was not wiped last"
grep '^ssh ' "$work/log" | grep -v -e "StrictHostKeyChecking=yes" -e ' -O exit ' && fail "an enrolment ssh call does not pin the host key"

refused "an existing recovery file" "$enrol" "$node"
rm "$recovery"
FAKE_SECURE_BOOT="disabled (setup)" refused "Secure Boot in setup mode" "$enrol" "$node"
refused "an unknown node" "$enrol" worker-9
FAKE_UNREACHABLE=1 refused "an unreachable node" "$enrol" "$node"
[ -z "$(find "$stick/luks-recovery" -type f)" ] || fail "an enrolment refused early left a file in luks-recovery"

if FAKE_RECOVERY_EXIT=255 run "$enrol" "$node"; then fail "a recovery enrolment whose ssh exited 255 succeeded"; fi
[ "$(cat "$stick/luks-recovery/.$node.partial" 2>/dev/null)" = "$recovery_key" ] \
  || fail "a recovery key printed before ssh failed was not kept in the partial file"
grep -qF "luks-recovery/.$node.partial" "$work/output" || fail "the failure does not say where the recovery key was kept"
if grep -q -- '--wipe-slot' "$work/log"; then fail "the password slot was wiped after a failed recovery enrolment"; fi
rm "$stick/luks-recovery/.$node.partial"

FAKE_INITIAL_TOKENS=systemd-tpm2 run "$enrol" "$node" || { cat "$work/output" >&2; fail "a re-run after the TPM enrolment failed"; }
if grep -q -- '--tpm2-device' "$work/log"; then fail "a re-run added a second TPM slot"; fi
grep -q -- '--wipe-slot=password' "$work/log" || fail "a re-run after the TPM enrolment did not finish"

for lost in systemd-tpm2 systemd-recovery; do
  rm -f "$recovery"
  if FAKE_LOST_TOKEN="$lost" run "$enrol" "$node"; then fail "enrolment without a $lost token succeeded"; fi
  if grep -q -- '--wipe-slot' "$work/log"; then fail "the password slot was wiped without a $lost token"; fi
done

rm -f "$recovery"
mkdir -p "$stick/luks-recovery"
: > "$stick/luks-recovery/.$node.partial"
if run "$enrol" "$node"; then fail "a leftover partial recovery file was not refused"; fi
[ -e "$stick/luks-recovery/.$node.partial" ] || fail "the enrolment removed a partial file it did not create"
rm "$stick/luks-recovery/.$node.partial"

echo "install-node and enrol-node-tpm refuse every unsafe start, pass the expected arguments and never wipe the password slot early."
