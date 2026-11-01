#!/bin/bash
# Everything that can be checked locally.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
bash "$HERE/pas/run_tests.sh"
