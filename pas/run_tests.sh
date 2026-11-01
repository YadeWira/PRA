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
for prog in test_blake3 test_arith test_pnm test_codec; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT" -FE"$OUT" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" pas/tests/kat.txt | tail -1
"$OUT/test_arith" | tail -1
"$OUT/test_pnm" | tail -1
"$OUT/test_codec" > "$OUT/codec.txt" || { cat "$OUT/codec.txt"; exit 1; }
tail -1 "$OUT/codec.txt"

echo "== the fast build makes the same streams"
mkdir -p "$OUT/fast"
$FPC -O3 -dPRA_FAST -Fupas -Fipas -FU"$OUT/fast" -FE"$OUT/fast" pas/tests/test_codec.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/fast/test_codec" > "$OUT/codec_fast.txt" || { cat "$OUT/codec_fast.txt"; exit 1; }
a=$(grep '^streams ' "$OUT/codec.txt"); b=$(grep '^streams ' "$OUT/codec_fast.txt")
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "FAIL: checked $a, fast $b"; exit 1; }
echo "$a"
echo "all green"
