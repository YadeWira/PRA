#!/bin/sh
# The C part PRA links: PPA's deflate layer (vendor/ppa, copied as it is from
# PPA 0.3.0), as objects FreePascal finds through -Fo<dir>. The flags are
# PPA's pas/build_c.sh's.
#
#   scripts/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
#
# The objects call no library and need no runtime: no stack protector, no
# loop turned into memset (gcc's -fno-tree-loop-distribute-patterns, clang's
# -fno-builtin), no position-independent code where the executable is not
# (32-bit x86). -fwrapv and -ffp-contract=off keep the arithmetic the same
# everywhere.
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")/.." && pwd)/vendor/ppa/pas
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
case "$CC $*" in
  *-m32*|*i686*|*i386*) FLAGS="$FLAGS -fno-pic" ;;
esac
mkdir -p "$OUT"
for f in ppadeflatec ppazlibc ppaminizc ppacorrc; do
  # shellcheck disable=SC2086
  $CC $FLAGS "$@" -c "$HERE/$f.c" -o "$OUT/$f.o"
done
