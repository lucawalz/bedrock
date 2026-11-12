#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: offline-backup.sh <mountpoint>"

RCLONE_CONFIG_FILE="${OFFLINE_BACKUP_RCLONE_CONFIG:-/Volumes/bedrock-keys/bedrock/rclone/offline-backup.conf}"
TARGET_DIRECTORY=bedrock-offline
FREE_SPACE_HEADROOM_PERCENT=10
BYTES_PER_KIBIBYTE=1024

DUMPS_SOURCE=postgres:bedrock-postgres
DUMPS_PREFIX=dumps
DUMPS_SUFFIX=.gpg
ETCD_SOURCE=etcd:bedrock-etcd
ETCD_PREFIX=etcd-snapshots
LONGHORN_SOURCE=longhorn:bedrock-longhorn
LONGHORN_VOLUMES_PREFIX=backupstore/volumes
LONGHORN_VOLUME_DEPTH=3

[ "$#" -eq 1 ] || { echo "$usage" >&2; exit 2; }
mount="$1"

require_tools rclone jq df
[ -d "$mount" ] || fail "$mount is not mounted"
[ -w "$mount" ] || fail "$mount is not writable"
[ -f "$RCLONE_CONFIG_FILE" ] || fail "$RCLONE_CONFIG_FILE is missing; plug in the bedrock-keys stick and create the read-only remotes"
export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
staged="$work/staged"

newest_dumps() {
  local database newest
  while IFS= read -r database; do
    newest="$(rclone lsf --files-only --include "*$DUMPS_SUFFIX" "$DUMPS_SOURCE/$DUMPS_PREFIX/$database" | sort | tail -n 1)"
    [ -z "$newest" ] || echo "$DUMPS_PREFIX/$database$newest"
  done < <(rclone lsf --dirs-only "$DUMPS_SOURCE/$DUMPS_PREFIX/")
}

newest_etcd_snapshot() {
  rclone lsf --files-only --format tp --separator ';' "$ETCD_SOURCE/$ETCD_PREFIX/" \
    | sort | tail -n 1 | cut -d ';' -f 2- | sed "s|^|$ETCD_PREFIX/|"
}

newest_longhorn_backups() {
  local volume volume_config backup backup_config
  while IFS= read -r volume; do
    volume="$LONGHORN_VOLUMES_PREFIX/$volume"
    volume_config="$(rclone cat "$LONGHORN_SOURCE/${volume}volume.cfg")"
    backup="$(jq -r '.LastBackupName // empty' <<< "$volume_config")"
    if [ -z "$backup" ]; then
      echo "skipping $volume: volume.cfg names no last backup" >&2
      continue
    fi
    backup_config="${volume}backups/backup_$backup.cfg"
    mkdir -p "$staged/$volume/backups"
    printf '%s' "$volume_config" > "$staged/${volume}volume.cfg"
    rclone cat "$LONGHORN_SOURCE/$backup_config" > "$staged/$backup_config"
    jq -r '(.Blocks // [])[].BlockChecksum' "$staged/$backup_config" | sort -u \
      | awk -v volume="$volume" '{ printf "%sblocks/%s/%s/%s.blk\n", volume, substr($0, 1, 2), substr($0, 3, 2), $0 }'
  done < <(rclone lsf -R --dirs-only --max-depth "$LONGHORN_VOLUME_DEPTH" "$LONGHORN_SOURCE/$LONGHORN_VOLUMES_PREFIX/" \
    | awk -F / -v depth="$LONGHORN_VOLUME_DEPTH" 'NF == depth + 1')
}

selected_bytes() {
  rclone size --json --files-from-raw "$2" "$1" | jq -r '.bytes'
}

newest_dumps > "$work/dumps"
[ -s "$work/dumps" ] || fail "found no dumps in $DUMPS_SOURCE/$DUMPS_PREFIX/"
newest_etcd_snapshot > "$work/etcd"
[ -s "$work/etcd" ] || fail "found no etcd snapshot in $ETCD_SOURCE/$ETCD_PREFIX/"
newest_longhorn_backups > "$work/longhorn"
[ -s "$work/longhorn" ] || fail "found no Longhorn backup in $LONGHORN_SOURCE/$LONGHORN_VOLUMES_PREFIX/"

total=$(( $(selected_bytes "$DUMPS_SOURCE" "$work/dumps") \
  + $(selected_bytes "$ETCD_SOURCE" "$work/etcd") \
  + $(selected_bytes "$LONGHORN_SOURCE" "$work/longhorn") \
  + $(du -sk "$staged" | cut -f 1) * BYTES_PER_KIBIBYTE ))
needed=$(( total + total * FREE_SPACE_HEADROOM_PERCENT / 100 ))
free=$(( $(df -Pk "$mount" | awk 'NR == 2 { print $4 }') * BYTES_PER_KIBIBYTE ))
[ "$needed" -le "$free" ] || fail "the copy needs $needed bytes with headroom and $mount has $free free"

target="$mount/$TARGET_DIRECTORY/$(date -u +%Y-%m-%dT%H%M%SZ)"
[ ! -e "$target" ] || fail "$target already exists"
mkdir -p "$target"
rclone copy --no-traverse --files-from-raw "$work/dumps" "$DUMPS_SOURCE" "$target/${DUMPS_SOURCE#*:}"
rclone copy --no-traverse --files-from-raw "$work/etcd" "$ETCD_SOURCE" "$target/${ETCD_SOURCE#*:}"
rclone copy --no-traverse --files-from-raw "$work/longhorn" "$LONGHORN_SOURCE" "$target/${LONGHORN_SOURCE#*:}"
cp -R "$staged/." "$target/${LONGHORN_SOURCE#*:}/"
echo "Copied $total bytes to $target"
