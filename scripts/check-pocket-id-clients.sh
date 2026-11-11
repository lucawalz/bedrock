#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools python3

python3 -I -B -m unittest discover -s kubernetes/infrastructure/controllers/pocket-id/clients -p 'test_*.py' -v
