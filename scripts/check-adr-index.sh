#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

adr_dir="$repo_root/docs/adr"
index="$adr_dir/README.md"

front_matter_status() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

index_entry() {
  awk -v link="]($1)" '
    substr($0, 1, 2) != "- " { next }
    index($0, link) == 0 { next }
    {
      pos = index($0, link)
      before = substr($0, 1, pos - 1)
      bstart = index(before, "[")
      title = substr(before, bstart + 1)
      sub(/^[0-9][0-9][0-9][0-9]\. /, "", title)

      rest = substr($0, pos + length(link))
      sub(/^[[:space:]]+/, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      status = ""
      if (substr(rest, 1, 1) == "(" && substr(rest, length(rest), 1) == ")") {
        status = substr(rest, 2, length(rest) - 2)
      }

      print title "\t" status
      exit
    }
  ' "$index"
}

file_title() {
  awk '
    /^# [0-9][0-9][0-9][0-9]\. / {
      sub(/^# [0-9][0-9][0-9][0-9]\. /, "")
      print
      exit
    }
  ' "$1"
}

normalize_status() {
  printf '%s' "$1" | sed \
    -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"\(.*\)"$/\1/' \
    -e "s/^'\(.*\)'\$/\1/"
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
title_drift=""
for l in $linked; do
  if [ ! -f "$adr_dir/$l" ]; then
    continue
  fi
  recorded="$(front_matter_status "$adr_dir/$l")"
  IFS=$'\t' read -r indexed_title indexed < <(index_entry "$l") || true
  if [ -z "$(normalize_status "$recorded")" ]; then
    status_drift="$status_drift$l declares no status in its front matter"$'\n'
  elif [ "$(normalize_status "$recorded")" != "$(normalize_status "$indexed")" ]; then
    status_drift="$status_drift$l records \"$recorded\" but the index says \"$indexed\""$'\n'
  fi

  file_heading="$(file_title "$adr_dir/$l")"
  if [ -z "$file_heading" ]; then
    title_drift="$title_drift$l has no \"# NNNN. Title\" heading to compare"$'\n'
  elif [ "$file_heading" != "$indexed_title" ]; then
    title_drift="$title_drift$l heading reads \"$file_heading\" but the index says \"$indexed_title\""$'\n'
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
if [ -n "$title_drift" ]; then
  echo "ADR titles that disagree with docs/adr/README.md:"
  printf '%s' "$title_drift" | sed 's/^/  - /'
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "ADR index is in sync."
fi
exit "$status"
