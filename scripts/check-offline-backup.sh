#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools jq

script=scripts/offline-backup.sh
block=aabbccdd
volume_path=backupstore/volumes/12/34/pvc-one/
enough_free_kib=1000000
short_free_kib=1
selected_bytes=1000

work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/mount" "$work/directory" "$work/read-only"
chmod 555 "$work/read-only"
: > "$work/rclone.conf"
mounted="$(cd "$work/mount" && pwd -P)"
read_only="$(cd "$work/read-only" && pwd -P)"

cat > "$work/bin/rclone" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "\$FAKE_RCLONE_LOG"
case "\$*" in
  "lsf -R --files-only --include *.gpg postgres:bedrock-postgres/dumps/")
    printf 'paperless/2026-11-11T033000Z.gpg\npocket-id/2026-11-11T033000Z.gpg\npaperless/2026-11-10T033000Z.gpg\n' ;;
  "lsf --files-only --format tp --separator ; etcd:bedrock-etcd/etcd-snapshots/")
    printf '2026-11-11 00:00:04;etcd-snapshot-control-plane-1-2\n2026-11-11 12:00:04;etcd-snapshot-control-plane-1-1\n' ;;
  "lsf -R --files-only --include volume.cfg longhorn:bedrock-longhorn/backupstore/volumes/") printf '12/34/pvc-one/volume.cfg\n' ;;
  "cat longhorn:bedrock-longhorn/${volume_path}volume.cfg") printf '{"LastBackupName":"backup-new"}' ;;
  "cat longhorn:bedrock-longhorn/${volume_path}backups/backup_backup-new.cfg")
    printf '{"Blocks":[{"Offset":0,"BlockChecksum":"$block"},{"Offset":2,"BlockChecksum":"$block"}]}' ;;
  "size --json --files-from-raw "*) printf '{"count":1,"bytes":$selected_bytes}' ;;
  "copy --no-traverse --files-from-raw "*) cat "\$4" >> "\$FAKE_COPY_LOG" ;;
  *) echo "unexpected rclone call: \$*" >&2; exit 2 ;;
esac
FAKE
cat > "$work/bin/df" <<'FAKE'
#!/bin/sh
for path; do :; done
point=/
case " $FAKE_MOUNTED " in *" $path "*) point="$path" ;; esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nstick 1 1 %s 1%% %s\n' "$FAKE_FREE_KIB" "$point"
FAKE
chmod +x "$work/bin/rclone" "$work/bin/df"

status=0

run_case() {
  local name="$1" mount="$2" config="$3" free="$4" expected="$5"
  : > "$work/rclone.log"
  : > "$work/copies"
  local code=0
  PATH="$work/bin:$PATH" FAKE_RCLONE_LOG="$work/rclone.log" FAKE_COPY_LOG="$work/copies" FAKE_FREE_KIB="$free" \
    FAKE_MOUNTED="$mounted $read_only /" RCLONE_CONFIG="$config" bash "$script" "$mount" > /dev/null 2> "$work/stderr" || code=$?
  if [ -z "$expected" ]; then
    [ "$code" -eq 0 ] || { echo "FAIL: $name: exited $code: $(cat "$work/stderr")"; status=1; }
    return
  fi
  if [ "$code" -eq 0 ]; then
    echo "FAIL: $name: copied instead of refusing"
    status=1
  elif ! grep -q "$expected" "$work/stderr"; then
    echo "FAIL: $name: stderr lacks '$expected': $(cat "$work/stderr")"
    status=1
  fi
  if [ -s "$work/copies" ] || [ -d "$mount/bedrock-offline" ]; then
    echo "FAIL: $name: copied something before refusing"
    status=1
  fi
}

run_case "missing mountpoint" "$work/absent" "$work/rclone.conf" "$enough_free_kib" "is not a mounted volume"
run_case "directory that is not a mountpoint" "$work/directory" "$work/rclone.conf" "$enough_free_kib" "is not a mounted volume"
run_case "root filesystem" / "$work/rclone.conf" "$enough_free_kib" "is not a mounted volume"
run_case "read-only mountpoint" "$work/read-only" "$work/rclone.conf" "$enough_free_kib" "is not writable"
run_case "missing token config" "$work/mount" "$work/absent.conf" "$enough_free_kib" "is missing"
run_case "space short" "$work/mount" "$work/rclone.conf" "$short_free_kib" "free"
run_case "copy fits" "$work/mount/" "$work/rclone.conf" "$enough_free_kib" ""

expected_copies="dumps/paperless/2026-11-11T033000Z.gpg
dumps/pocket-id/2026-11-11T033000Z.gpg
etcd-snapshots/etcd-snapshot-control-plane-1-1
${volume_path}volume.cfg
${volume_path}backups/backup_backup-new.cfg
${volume_path}blocks/aa/bb/$block.blk"
if [ "$(cat "$work/copies")" != "$expected_copies" ]; then
  echo "FAIL: copy fits: copied $(cat "$work/copies"), expected $expected_copies"
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "offline-backup copies the newest set and refuses a missing, unmounted, root or read-only target, a missing token config and a short target."
fi
exit "$status"
