#!/bin/bash
# The whole suite, layer by layer: each test is built with range and
# overflow checks on (the reference build) and demands its own minimum cell
# count: a test that runs zero cells is not green.
#
# set -e on purpose: if something does not compile or does not run, it stops here.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")" && pwd); OUT=${PAS_OUT:-$PAS/build/tests}
mkdir -p "$OUT"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"

echo "== build"
for prog in test_blake3 test_arith; do
  $FPC -O2 -Fu"$PAS" -Fi"$PAS" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" "$PAS/tests/kat.txt" | tail -1
"$OUT/test_arith" | tail -1
echo "all green"
