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
for prog in test_blake3 test_arith test_model test_pnm test_parsers test_codec test_format test_prafs; do
  $FPC -O2 -Fupas -Fipas -FU"$OUT" -FE"$OUT" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== tests"
"$OUT/test_blake3" pas/tests/kat.txt | tail -1
"$OUT/test_arith" | tail -1
"$OUT/test_model" | tail -1
"$OUT/test_pnm" | tail -1
"$OUT/test_parsers" tests/bmp tests/hdr tests/other tests/multi tests/sci | tail -1
"$OUT/test_codec" tests/bmp tests/hdr tests/other tests/multi tests/sci > "$OUT/codec.txt" || { cat "$OUT/codec.txt"; exit 1; }
tail -1 "$OUT/codec.txt"

"$OUT/test_format" tests/pnm tests/bmp tests/hdr tests/other tests/multi tests/sci | tail -1
# prafs touches the disk: a directory of its own
rm -rf "$OUT/tmp_fs"; mkdir -p "$OUT/tmp_fs"; "$OUT/test_prafs" "$(realpath "$OUT/tmp_fs")" | tail -1

echo "== the command"
mkdir -p "$OUT/cli"
$FPC -O3 -dPRA_FAST -Fupas -Fipas -FU"$OUT/cli" -o"$OUT/pra" pas/pracli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
pas/tests/cli.sh "$OUT/pra" "$OUT/tmp_cli" tests/pnm tests/bmp tests/hdr tests/other tests/multi tests/sci | tail -1

echo "== the fast build makes the same streams"
mkdir -p "$OUT/fast"
$FPC -O3 -dPRA_FAST -Fupas -Fipas -FU"$OUT/fast" -FE"$OUT/fast" pas/tests/test_codec.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/fast/test_codec" tests/bmp tests/hdr tests/other tests/multi tests/sci > "$OUT/codec_fast.txt" || { cat "$OUT/codec_fast.txt"; exit 1; }
a=$(grep '^streams ' "$OUT/codec.txt"); b=$(grep '^streams ' "$OUT/codec_fast.txt")
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "FAIL: checked $a, fast $b"; exit 1; }
echo "$a"
echo "== the assembly makes the same streams as the Pascal (PRA_NOASM=1)"
PRA_NOASM=1 "$OUT/fast/test_codec" tests/bmp tests/hdr tests/other tests/multi tests/sci > "$OUT/codec_noasm.txt" || { cat "$OUT/codec_noasm.txt"; exit 1; }
c=$(grep '^streams ' "$OUT/codec_noasm.txt")
[ "$a" = "$c" ] || { echo "FAIL: assembly $a, Pascal $c"; exit 1; }
echo "$c"
echo "all green"
