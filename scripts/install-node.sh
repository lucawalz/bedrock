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

stick_root="${BEDROCK_STICK_ROOT:-/Volumes/bedrock-keys/bedrock}"
keys="$stick_root/rebuild-keys"
tree="$keys/hosts/$node"
passphrase_file="$keys/luks-install-passphrase"
guid_file="$tree/var/lib/sbctl/GUID"
host_key="$tree/etc/ssh/ssh_host_ed25519_key"
estate_root="$repo_root/hosts/common/estate-root.pub"
SECRETIVE_SOCKET="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
SHORT_TMP_ROOT=/tmp
CONTROL_PERSIST=60m
CONNECT_TIMEOUT_SECONDS=10
INSTALLER_HOSTNAMES=(nixos-installer nixos)

address="$(node_address "$node")"
[ -n "$address" ] || fail "$node is not a node in lib/inventory.nix"
for file in "$guid_file" "$host_key" "$passphrase_file"; do
  [ -r "$file" ] || fail "$file is missing; mount the bedrock-keys stick and run just generate-rebuild-keys"
done
[ "$(git branch --show-current)" = main ] || fail "$repo_root is not on main"
[ -z "$(git status --porcelain)" ] || fail "$repo_root has uncommitted changes"

control_dir="$(mktemp -d "$SHORT_TMP_ROOT/install-node.XXXXXX")"
ssh_options=(
  "IdentityAgent=$SECRETIVE_SOCKET"
  "IdentityFile=$estate_root"
  IdentitiesOnly=yes
  ControlMaster=auto
  "ControlPath=$control_dir/%C"
  "ControlPersist=$CONTROL_PERSIST"
)
ssh_args=()
for option in "${ssh_options[@]}"; do ssh_args+=(-o "$option"); done
ssh_args+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
clipboard_used=false

cleanup() {
  if $clipboard_used; then pbcopy < /dev/null; echo "Clipboard cleared."; fi
  ssh "${ssh_args[@]}" -O exit "root@$address" 2>/dev/null || true
  rm -rf "$control_dir"
}
trap cleanup EXIT

target_name="$(ssh -o ControlPath=none "${ssh_args[@]}" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT_SECONDS" "root@$address" hostname)" \
  || fail "root@$address does not answer over ssh"
if [ "$target_name" != "$node" ]; then
  [[ " ${INSTALLER_HOSTNAMES[*]} " == *" $target_name "* ]] || fail "$address answers as $target_name, not $node"
  echo "$address already runs the installer; continuing."
fi

if [[ ",$phases," == *,disko,* ]]; then
  clipboard_used=true
  pbcopy < "$passphrase_file"
  echo "The LUKS install passphrase is on the clipboard: paste it at both passphrase prompts."
fi

na_ssh_args=()
for option in "${ssh_options[@]}"; do na_ssh_args+=(--ssh-option "$option"); done
nix develop --command nixos-anywhere --flake ".#$node" --build-on remote \
  --phases "$phases" \
  --extra-files "$tree" \
  "${na_ssh_args[@]}" \
  "root@$address"

if [[ ",$phases," != *,install,* ]]; then
  echo "Phases $phases finished on $node; run the install phase next."
  exit 0
fi

installer=(ssh "${ssh_args[@]}" "root@$address")
sbctl='nix --extra-experimental-features "nix-command flakes" shell nixpkgs#sbctl --command sbctl'
"${installer[@]}" 'rm -rf /var/lib/sbctl && mkdir -p /var/lib && cp -a /mnt/var/lib/sbctl /var/lib/sbctl'
"${installer[@]}" "$sbctl enroll-keys --microsoft"
status="$("${installer[@]}" "$sbctl status --json")"
[ "$(jq -r .guid <<< "$status")" = "$(cat "$guid_file")" ] \
  || fail "the installer's sbctl owner GUID is not the one in $guid_file; not rebooting"
[ "$(jq -r .setup_mode <<< "$status")" = false ] || fail "the firmware is still in setup mode after enrolment; not rebooting"

"${installer[@]}" 'umount -R /mnt; cryptsetup close cryptroot; systemctl reboot' || true
echo "Installed $node and enrolled its Secure Boot keys. At the console, enable Secure Boot, type the install passphrase, then run: just enrol-node-tpm $node"
