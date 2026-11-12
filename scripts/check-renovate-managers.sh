#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools python3

python3 <<'PY'
import fnmatch
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


PYTHON_FLAGS = {"i": "i", "m": "m", "s": "s"}


def strip_delimiters(pattern):
    delimited = re.fullmatch(r"/(.*)/([a-z]*)", pattern, re.DOTALL)
    if not delimited:
        return pattern
    body, flags = delimited.groups()
    unknown = [f for f in flags if f not in PYTHON_FLAGS]
    if unknown:
        raise SystemExit(f"Unsupported regex flag {''.join(unknown)!r} in pattern: {pattern}")
    return f"(?{''.join(PYTHON_FLAGS[f] for f in flags)}){body}" if flags else body


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

ADR_PATH = "docs/adr/0014-pin-versions-and-update-them-with-renovate.md"
HELD_HEADING = "### Held for review"
HELD_UPDATE_TYPES = {"minor", "patch"}
TAG_OR_DIGEST = re.compile(r"(?::[^:/@]+)?(?:@sha256:[0-9a-f]+)?$")


def held_names():
    names, inside = [], False
    for line in open(ADR_PATH, encoding="utf-8"):
        if line.startswith("#"):
            inside = line.strip() == HELD_HEADING
            continue
        if inside and line.startswith("|"):
            names += re.findall(r"`([^`]+)`", line.rsplit("|", 2)[1])
    return names


def repository_names():
    names = {manager.get("depNameTemplate") for manager in config.get("customManagers", [])}
    for path in (p for p in paths if re.search(r"\.ya?ml$", p)):
        registry = None
        for line in open(path, encoding="utf-8"):
            names.update(re.findall(r"depName=(\S+)", line))
            field = re.match(r"\s*-?\s*(chart|registry|repository|image):\s*[\"']?([^\"'\s#]+)", line)
            key, value = field.groups() if field else (None, None)
            if key == "chart":
                names.add(value)
            elif key == "repository":
                names.add(f"{registry}/{value}" if registry else value)
            elif key == "image":
                names.add(TAG_OR_DIGEST.sub("", value))
            registry = value if key == "registry" else None
    return names


def matches(pattern, name):
    if re.fullmatch(r"/.*/[a-z]*", pattern):
        return re.search(to_python_regex(strip_delimiters(pattern)), name) is not None
    return fnmatch.fnmatchcase(name, pattern)


def holds(rule, name):
    if rule.get("automerge") is not False or "matchFileNames" in rule:
        return False
    if not HELD_UPDATE_TYPES <= set(rule.get("matchUpdateTypes", HELD_UPDATE_TYPES)):
        return False
    patterns = rule.get("matchPackageNames", []) + rule.get("matchDepNames", [])
    return any(matches(p, name) for p in patterns)


held = held_names()
if not held:
    print(f"No dependency names under {HELD_HEADING} in {ADR_PATH}")
    status = 1
present = repository_names()
for name in held:
    if name not in present:
        print(f"Held dependency {name} from {ADR_PATH} appears nowhere in the repository")
        status = 1
    elif not any(holds(rule, name) for rule in config.get("packageRules", [])):
        print(f"No packageRule holds minor and patch updates of {name} for review")
        status = 1

if status == 0:
    print(f"Every held dependency in {ADR_PATH} exists and matches a hold rule.")

sys.exit(status)
PY
