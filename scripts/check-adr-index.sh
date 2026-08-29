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
  awk -v link="]($1)" '
    substr($0, 1, 2) != "- " { next }
    index($0, link) == 0 { next }
    {
      rest = substr($0, index($0, link) + length(link))
      sub(/^[[:space:]]+/, "", rest)
      sub(/[[:space:]]+$/, "", rest)
      if (substr(rest, 1, 1) == "(" && substr(rest, length(rest), 1) == ")") {
        print substr(rest, 2, length(rest) - 2)
      }
      exit
    }
  ' "$index"
}

index_title() {
  awk -v link="]($1)" '
    substr($0, 1, 2) != "- " { next }
    index($0, link) == 0 { next }
    {
      pos = index($0, link)
      before = substr($0, 1, pos - 1)
      bstart = index(before, "[")
      title = substr(before, bstart + 1)
      sub(/^[0-9][0-9][0-9][0-9]\. /, "", title)
      print title
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
  indexed="$(index_status "$l")"
  if [ -z "$(normalize_status "$recorded")" ]; then
    status_drift="$status_drift$l declares no status in its front matter"$'\n'
  elif [ "$(normalize_status "$recorded")" != "$(normalize_status "$indexed")" ]; then
    status_drift="$status_drift$l records \"$recorded\" but the index says \"$indexed\""$'\n'
  fi

  file_heading="$(file_title "$adr_dir/$l")"
  index_link_text="$(index_title "$l")"
  if [ -z "$file_heading" ]; then
    title_drift="$title_drift$l has no \"# NNNN. Title\" heading to compare"$'\n'
  elif [ "$file_heading" != "$index_link_text" ]; then
    title_drift="$title_drift$l heading reads \"$file_heading\" but the index says \"$index_link_text\""$'\n'
  fi
done

allowlisted_gaps="0056"
numbering_gaps=""
prev_num=""
for f in $records; do
  num="${f%%-*}"
  num_dec=$((10#$num))
  if [ -n "$prev_num" ]; then
    expected=$((prev_num + 1))
    while [ "$expected" -lt "$num_dec" ]; do
      gap="$(printf '%04d' "$expected")"
      case " $allowlisted_gaps " in
        *" $gap "*) ;;
        *) numbering_gaps="$numbering_gaps$gap"$'\n' ;;
      esac
      expected=$((expected + 1))
    done
  fi
  prev_num="$num_dec"
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
if [ -n "$numbering_gaps" ]; then
  echo "ADR numbering gaps not on the allowlist ($allowlisted_gaps):"
  printf '%s' "$numbering_gaps" | sed 's/^/  - /'
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "ADR index is in sync."
fi
exit "$status"
