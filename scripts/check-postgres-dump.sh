#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools python3 gpg gpgconf

dump_dir=kubernetes/infrastructure/configs/cnpg/dumps

python3 -I -B -m unittest discover -s "$dump_dir" -p 'test_*.py' -v
