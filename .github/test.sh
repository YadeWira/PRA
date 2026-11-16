#!/bin/sh
# The check every platform runs (CI): the portable layer tests (checked
# build), the pra command built as it is shipped, every sample compressed
# and extracted by it (each must come back byte for byte), and the SHA-256
# of all the .pra files written to hash.txt: the format makes the same bytes
# on every platform, which the last CI job checks. The suite that needs a
# Unix filesystem (links, the command from the outside) is
# pas/run_tests.sh, run on Linux.
#
#   FPC=<compiler> PRA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PRA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/t" "$OUT/p" "$OUT/x"
# the commit `pra --version` and `report` show (release.yml sets it from the tag)
PRA_COMMIT=${PRA_COMMIT:-$(git rev-parse --short=7 HEAD 2>/dev/null || true)}
export PRA_COMMIT

echo "== the C part (vendor/ppa: PPA's deflate layer)"
# CC: the platform's C compiler. One given by its full path (MSYS2's
# MinGW-w64 gcc on Windows) needs its own folder on PATH for its DLLs and
# its cc1/as.
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
sh scripts/build_c.sh "$OUT/c" || { echo "the C part did not build (CC=${CC:-cc})"; exit 1; }
# the objects call no library: on Linux, nm must find no undefined symbol
if [ "$(uname -s)" = Linux ] && command -v nm > /dev/null; then
  if nm "$OUT"/c/*.o | grep ' U '; then echo "FAIL: the C objects need a library"; exit 1; fi
fi
VP="-Fuvendor/ppa/pas -Fivendor/ppa/pas -Fo$OUT/c"

echo "== layer tests"
for prog in test_blake3 test_arith test_model test_pnm test_parsers test_codec test_format; do
  # shellcheck disable=SC2086
  $FPC -O2 -Fupas -Fipas $VP -FU"$OUT/t" -FE"$OUT/t" "pas/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
"$OUT/t/test_blake3$EXE" pas/tests/kat.txt | tail -1
"$OUT/t/test_arith$EXE" | tail -1
"$OUT/t/test_model$EXE" | tail -1
"$OUT/t/test_pnm$EXE" | tail -1
"$OUT/t/test_parsers$EXE" tests/bmp tests/hdr tests/other tests/multi tests/sci tests/cont | tail -1
"$OUT/t/test_codec$EXE" tests/bmp tests/hdr tests/other tests/multi tests/sci tests/cont | tail -2
"$OUT/t/test_format$EXE" tests/pnm tests/bmp tests/hdr tests/other tests/multi tests/sci tests/cont | tail -1

echo "== the command"
# shellcheck disable=SC2086
$FPC -O3 -dPRA_FAST -dPPA_FAST -Fupas -Fipas $VP -FU"$OUT/u" -o"$OUT/pra$EXE" pas/pracli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/pra$EXE" --version
"$OUT/pra$EXE" selftest
"$OUT/pra$EXE" a -q --output-dir="$OUT/p" tests/pnm/* tests/bmp/* tests/hdr/* tests/other/* tests/multi/* tests/sci/* tests/cont/*
"$OUT/pra$EXE" x -q --output-dir="$OUT/x" "$OUT"/p/*.pra
n=0
for f in tests/pnm/* tests/bmp/* tests/hdr/* tests/other/* tests/multi/* tests/sci/* tests/cont/*; do
  n=$((n + 1))
  cmp -s "$f" "$OUT/x/$(basename "$f")" || { echo "FAIL: $(basename "$f") does not come back"; exit 1; }
done
[ "$n" -ge 120 ] || { echo "FAIL: only $n samples"; exit 1; }
echo "$n samples back byte for byte"

echo "== the .pra files"
(cd "$OUT/p" && $SHA * | sed 's/ [ *]/  /' | sort) > "$OUT/pra.txt"
$SHA "$OUT/pra.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/pra.txt" | tr -d ' ') files, SHA-256 of their list: $(cat hash.txt)"
