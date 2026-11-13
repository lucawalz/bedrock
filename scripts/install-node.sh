#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: install-node.sh <node> [phases]" >&2; exit 2; }
node="$1"
DEFAULT_PHASES=kexec,disko,install
phases="${2:-$DEFAULT_PHASES}"
phases="${phases#phases=}"
KNOWN_PHASES=(kexec disko install)

IFS=, read -ra requested_phases <<< "$phases"
[ "${#requested_phases[@]}" -gt 0 ] || fail "no phases given"
for phase in "${requested_phases[@]}"; do
  [[ " ${KNOWN_PHASES[*]} " == *" $phase "* ]] \
    || fail "phase '$phase' is not one of ${KNOWN_PHASES[*]}; the script reboots itself after Secure Boot enrolment"
done

require_tools git nix ssh pbcopy jq

keys="$(rebuild_keys_dir)"
tree="$keys/hosts/$node"
passphrase_file="$keys/luks-install-passphrase"
CONTROL_PERSIST=60m
CONNECT_TIMEOUT_SECONDS=10
SSH_CONNECTION_DROPPED=255
INSTALLER_HOSTNAMES=(nixos-installer nixos)

has_phase() { [[ ",$phases," == *",$1,"* ]]; }

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$tree/var/lib/sbctl/GUID" "$tree/etc/ssh/ssh_host_ed25519_key" "$passphrase_file"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick and run just generate-rebuild-keys"
done
[ "$(git branch --show-current)" = main ] || fail "$repo_root is not on main"
[ -z "$(git status --porcelain)" ] || fail "$repo_root has uncommitted changes"

open_ssh_session install-node "$CONTROL_PERSIST"
ssh_args=()
na_ssh_args=()
for option in "${ssh_session_options[@]}"; do
  ssh_args+=(-o "$option")
  na_ssh_args+=(--ssh-option "$option")
done
ssh_args+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
clipboard_used=false

clear_clipboard() {
  if $clipboard_used; then pbcopy < /dev/null; clipboard_used=false; echo "Clipboard cleared."; fi
}
cleanup() {
  clear_clipboard
  close_ssh_session "root@$address"
}
trap cleanup EXIT

target_name="$(ssh -n -o ControlPath=none "${ssh_args[@]}" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT_SECONDS" "root@$address" hostname)" \
  || fail "root@$address does not answer over ssh"
if [[ " ${INSTALLER_HOSTNAMES[*]} " == *" $target_name "* ]]; then
  echo "$address already runs the installer; continuing."
elif [ "$target_name" != "$node" ]; then
  fail "$address answers as $target_name, not $node"
elif ! has_phase kexec; then
  fail "$address runs $node, not the installer; phases without kexec would partition its disk in use"
fi

action="runs phases $phases on"
if has_phase disko; then action="wipes the disk of"; fi
printf 'This %s %s at %s. Type the node name to continue: ' "$action" "$node" "$address" >&2
read -r answer
[ "$answer" = "$node" ] || fail "aborted"

if has_phase disko; then
  clipboard_used=true
  pbcopy < "$passphrase_file"
  echo "The LUKS install passphrase is on the clipboard: paste it at both passphrase prompts."
fi

nix develop --command nixos-anywhere --flake ".#$node" --build-on remote \
  --phases "$phases" \
  --extra-files "$tree" \
  "${na_ssh_args[@]}" \
  "root@$address"
clear_clipboard

if ! has_phase install; then
  echo "Phases $phases finished on $node; run the install phase next."
  exit 0
fi

installer=(ssh "${ssh_args[@]}" "root@$address")
sbctl='nix --extra-experimental-features "nix-command flakes" shell nixpkgs#sbctl --command sbctl'
"${installer[@]}" 'rm -rf /var/lib/sbctl && mkdir -p /var/lib && cp -a /mnt/var/lib/sbctl /var/lib/sbctl'
"${installer[@]}" "$sbctl enroll-keys --microsoft"
status="$("${installer[@]}" "$sbctl status --json")"
[ "$(jq -r .setup_mode <<< "$status")" = false ] || fail "the firmware is still in setup mode after enrolment; not rebooting"

reboot_status=0
"${installer[@]}" 'umount -R /mnt && cryptsetup close cryptroot && systemctl reboot' || reboot_status=$?
[ "$reboot_status" -eq 0 ] || [ "$reboot_status" -eq "$SSH_CONNECTION_DROPPED" ] \
  || fail "unmounting and rebooting the installer failed with status $reboot_status"
echo "Installed $node and enrolled its Secure Boot keys. At the console, enable Secure Boot, type the install passphrase, then run: just enrol-node-tpm $node"
