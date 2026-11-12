#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${RCLONE_CONFIG:=/Volumes/bedrock-keys/bedrock/rclone/offline-backup.conf}"
export RCLONE_CONFIG
TARGET_DIRECTORY=bedrock-offline
FREE_SPACE_HEADROOM_PERCENT=10
BYTES_PER_KIBIBYTE=1024

DUMPS_SOURCE=postgres:bedrock-postgres
DUMPS_PREFIX=dumps
ETCD_SOURCE=etcd:bedrock-etcd
ETCD_PREFIX=etcd-snapshots
LONGHORN_SOURCE=longhorn:bedrock-longhorn
LONGHORN_VOLUMES_PREFIX=backupstore/volumes
SOURCES=("dumps:$DUMPS_SOURCE" "etcd:$ETCD_SOURCE" "longhorn:$LONGHORN_SOURCE")

: "${1:?usage: offline-backup.sh <mountpoint>}"
require_tools rclone jq df

mount_point_of() {
  df -P "$1" | awk 'NR == 2 { point = $6; for (field = 7; field <= NF; field++) point = point " " $field; print point }'
}

mount="$(cd "$1" 2>/dev/null && pwd -P)" || fail "$1 is not a mounted volume"
[ "$(mount_point_of "$mount")" = "$mount" ] && [ "$mount" != "$(mount_point_of /)" ] \
  || fail "$1 is not a mounted volume"
[ -w "$mount" ] || fail "$mount is not writable"
[ -f "$RCLONE_CONFIG" ] || fail "$RCLONE_CONFIG is missing; plug in the bedrock-keys stick and create the read-only remotes"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

newest_longhorn_backups() {
  local volume backup backup_config
  while IFS= read -r volume; do
    volume="$LONGHORN_VOLUMES_PREFIX/$(dirname "$volume")/"
    backup="$(rclone cat "$LONGHORN_SOURCE/${volume}volume.cfg" | jq -r '.LastBackupName // empty')"
    if [ -z "$backup" ]; then
      echo "skipping $volume: volume.cfg names no last backup" >&2
      continue
    fi
    backup_config="${volume}backups/backup_$backup.cfg"
    printf '%s\n' "${volume}volume.cfg" "$backup_config"
    rclone cat "$LONGHORN_SOURCE/$backup_config" | jq -r '(.Blocks // [])[].BlockChecksum' | sort -u \
      | awk -v volume="$volume" '{ printf "%sblocks/%s/%s/%s.blk\n", volume, substr($0, 1, 2), substr($0, 3, 2), $0 }'
  done < <(rclone lsf -R --files-only --include volume.cfg "$LONGHORN_SOURCE/$LONGHORN_VOLUMES_PREFIX/")
}

rclone lsf -R --files-only --include "*.gpg" "$DUMPS_SOURCE/$DUMPS_PREFIX/" | sort \
  | awk -F / -v prefix="$DUMPS_PREFIX" '{ newest[$1] = $0 } END { for (database in newest) print prefix "/" newest[database] }' \
  | sort > "$work/dumps"
rclone lsf --files-only --format tp --separator ';' "$ETCD_SOURCE/$ETCD_PREFIX/" \
  | sort | tail -n 1 | sed "s|^[^;]*;|$ETCD_PREFIX/|" > "$work/etcd"
newest_longhorn_backups > "$work/longhorn"

total=0
for source in "${SOURCES[@]}"; do
  [ -s "$work/${source%%:*}" ] || fail "found no ${source%%:*} backup in ${source#*:}"
  total=$(( total + $(rclone size --json --files-from-raw "$work/${source%%:*}" "${source#*:}" | jq -r '.bytes') ))
done
needed=$(( total + total * FREE_SPACE_HEADROOM_PERCENT / 100 ))
free=$(( $(df -Pk "$mount" | awk 'NR == 2 { print $4 }') * BYTES_PER_KIBIBYTE ))
[ "$needed" -le "$free" ] || fail "the copy needs $needed bytes with headroom and $mount has $free free"

target="$mount/$TARGET_DIRECTORY/$(date -u +%Y-%m-%dT%H%M%SZ)"
mkdir -p "$mount/$TARGET_DIRECTORY"
mkdir "$target"
progress=()
[ -t 1 ] && progress=(--progress)
for source in "${SOURCES[@]}"; do
  rclone copy --no-traverse --files-from-raw "$work/${source%%:*}" "${source#*:}" "$target/${source##*:}" "${progress[@]}"
done
echo "Copied $total bytes to $target"
