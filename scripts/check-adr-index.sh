#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adr_dir="$repo_root/docs/adr"
index="$adr_dir/README.md"

front_matter_status() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

index_status() {
  grep -F "($1)" "$index" | sed -n 's/.*(\(.*\))[[:space:]]*$/\1/p'
}

records="$(find "$adr_dir" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' -exec basename {} \; | sort)"
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

status_drift=""
for l in $linked; do
  if [ ! -f "$adr_dir/$l" ]; then
    continue
  fi
  recorded="$(front_matter_status "$adr_dir/$l")"
  indexed="$(index_status "$l")"
  if [ -z "$recorded" ]; then
    status_drift="$status_drift$l declares no status in its front matter"$'\n'
  elif [ "$recorded" != "$indexed" ]; then
    status_drift="$status_drift$l records \"$recorded\" but the index says \"$indexed\""$'\n'
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
if [ -n "$status_drift" ]; then
  echo "ADR statuses that disagree with docs/adr/README.md:"
  printf '%s' "$status_drift" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ADR index is in sync."
fi
exit "$status"
