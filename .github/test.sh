#!/bin/sh
# The check every platform runs (CI). For now, the layer suite; it grows
# with the command, the samples and the hash of the codec's streams.
#
#   FPC=<compiler> sh .github/test.sh
set -eu
bash pas/run_tests.sh
