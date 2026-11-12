#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

bin="$(mktemp -d)"
trap 'rm -rf "$bin"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$bin/helm"
chmod +x "$bin/helm"

if PATH="$bin:$PATH" bash scripts/list-images.sh > /dev/null 2>&1; then
  fail "list-images.sh exits zero when helm fails"
fi
echo "list-images.sh fails when rendering fails."
