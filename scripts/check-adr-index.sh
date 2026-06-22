#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adr_dir="$repo_root/docs/adr"
index="$adr_dir/README.md"

records="$(cd "$adr_dir" && ls [0-9][0-9][0-9][0-9]-*.md | sort)"
linked="$(grep -oE '\(([0-9]{4}-[^)]+\.md)\)' "$index" | tr -d '()' | sort -u)"

missing_from_index=""
for f in $records; do
  if ! printf '%s\n' "$linked" | grep -qxF "$f"; then
    missing_from_index="$missing_from_index$f"$'\n'
  fi
done

dangling_index_entry=""
for l in $linked; do
  if [ ! -f "$adr_dir/$l" ]; then
    dangling_index_entry="$dangling_index_entry$l"$'\n'
  fi
done

status=0
if [ -n "$missing_from_index" ]; then
  echo "ADR files not linked in docs/adr/README.md:"
  printf '%s' "$missing_from_index" | sed 's/^/  - /'
  status=1
fi
if [ -n "$dangling_index_entry" ]; then
  echo "Index entries pointing to missing files:"
  printf '%s' "$dangling_index_entry" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ADR index is in sync."
fi
exit "$status"
