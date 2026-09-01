#!/bin/bash
# One command, one verdict. This is the development loop.
set -euo pipefail
cd "$(dirname "$0")"
./dev.sh --fast
exec ./harness/run.sh "$@"
