#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is not on PATH; enter the dev shell or install it" >&2
  exit 1
fi

python3 <<'PY'
import json
import re
import subprocess
import sys

config_path = "renovate.json"
tracked = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout
paths = [p for p in tracked.decode().split("\0") if p]

with open(config_path) as handle:
    config = json.load(handle)

status = 0


def to_python_regex(pattern):
    return re.compile(pattern.replace("(?<", "(?P<").replace("(?P<=", "(?<="))


def strip_delimiters(pattern):
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 1:
        return pattern[1:-1]
    return pattern


for index, manager in enumerate(config.get("customManagers", [])):
    label = manager.get("description", f"custom manager {index}")
    file_patterns = [to_python_regex(strip_delimiters(p)) for p in manager["managerFilePatterns"]]
    matched = [p for p in paths if any(r.search(p) for r in file_patterns)]

    if not matched:
        print(f"No file matches managerFilePatterns of: {label}")
        status = 1
        continue

    contents = {}
    for path in matched:
        try:
            contents[path] = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue

    for match_string in manager["matchStrings"]:
        expression = to_python_regex(match_string)
        if not any(expression.search(text) for text in contents.values()):
            print(f"No matched file contains a string for: {label}")
            print(f"  pattern: {match_string}")
            status = 1

if status == 0:
    print("Every Renovate custom manager matches a file and a version string.")

sys.exit(status)
PY
