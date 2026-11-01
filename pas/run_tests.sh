#!/bin/bash
# The whole suite, layer by layer: each test is built with range and
# overflow checks on (the reference build) and demands its own minimum cell
# count: a test that runs zero cells is not green.
#
# Paths are relative to the repository's root: on Windows a native fpc does
# not understand MSYS's absolute paths (/d/a/...).
#
# set -e on purpose: if something does not compile or does not run, it stops here.
set -euo pipefail
FPC=${FPC:-fpc}
cd "$(dirname "$0")/.."
OUT=${PAS_OUT:-pas/build/tests}
mkdir -p "$OUT"

echo "== source guards"
python3 pas/collisions.py pas

echo "== build"
for prog in test_blake3 test_arith test_pnm; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT" -FE"$OUT" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" pas/tests/kat.txt | tail -1
"$OUT/test_arith" | tail -1
"$OUT/test_pnm" | tail -1
echo "all green"
