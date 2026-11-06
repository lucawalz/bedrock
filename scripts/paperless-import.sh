#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools kubectl find

namespace=paperless
pod_label=app.kubernetes.io/name=paperless-ngx
consume_dir=/usr/src/paperless/consume
extensions="pdf png jpg jpeg tif tiff"

[ "$#" -eq 1 ] || { echo "usage: paperless-import.sh <dir>" >&2; exit 1; }
source_dir="$1"
[ -d "$source_dir" ] || { echo "$source_dir is not a directory" >&2; exit 1; }

name_args=()
for ext in $extensions; do
  [ "${#name_args[@]}" -eq 0 ] || name_args+=(-o)
  name_args+=(-iname "*.$ext")
done

pod="$(kubectl -n "$namespace" get pods -l "$pod_label" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$pod" ] || { echo "no running pod with label $pod_label in namespace $namespace" >&2; exit 1; }

count=0
while IFS= read -r -d '' file; do
  count=$((count + 1))
  kubectl -n "$namespace" cp "$file" "$pod:$consume_dir/$count-$(basename "$file")"
done < <(find "$source_dir" -type f \( "${name_args[@]}" \) -print0 | sort -z)

[ "$count" -gt 0 ] || { echo "no pdf, png, jpg or tiff files under $source_dir" >&2; exit 1; }
echo "copied $count files to $pod:$consume_dir"
