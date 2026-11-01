#!/bin/bash
# The pra command, from the outside: round trips, and each refusal with
# nothing written where it must not be. Adapted from PJA's.
#
#   pas/tests/cli.sh <pra binary> <work directory> <dir with samples>...
set -uo pipefail
PRA=$(realpath "$1"); W=$2; shift 2
cells=0; failures=0
check() {   # check <description> <command...>: the command has to succeed
  local what=$1; shift
  cells=$((cells + 1))
  if "$@" > /dev/null 2>&1; then printf '  %-66s ok\n' "$what"
  else printf '  %-66s FAIL\n' "$what"; failures=$((failures + 1)); fi
}
rc() { "$@" > /dev/null 2>&1; echo $?; }

rm -rf "$W"; mkdir -p "$W/in" "$W/out"
for d in "$@"; do cp "$d"/* "$W/in/"; done
n=$(ls "$W/in" | wc -l)
check "samples: $n files" test "$n" -ge 10

echo "--- round trip of every sample"
check "a, all at once, into a directory" "$PRA" a -q "$W"/in/* -o "$W/pra/"
check "  one .pra per input" test "$(ls "$W/pra" | wc -l)" -eq "$n"
check "x, all at once" "$PRA" x -q "$W"/pra/*.pra -o "$W/out/"
same=0
for f in "$W"/in/*; do cmp -s "$f" "$W/out/$(basename "$f")" && same=$((same + 1)); done
check "  every file back byte for byte, with its extension ($same of $n)" test "$same" -eq "$n"
check "the same .pra with 1 thread and with 4" bash -c "
  '$PRA' a -q -th 1 '$W/in/color.ppm' -o '$W/t1.pra' && '$PRA' a -q --threads=4 '$W/in/color.ppm' -o '$W/t4.pra' &&
  cmp -s '$W/t1.pra' '$W/t4.pra'"
check "with -th 4 and several files, the lines follow the input order" bash -c "
  '$PRA' a -th 4 -f '$W'/in/*.p?m -o '$W/ord/' | sed 's/ ->.*//' > '$W/ord.txt' &&
  ls '$W'/in/*.p?m > '$W/ord_in.txt' && cmp -s '$W/ord.txt' '$W/ord_in.txt'"
check "a file the codec cannot shrink is stored as is, and says so" bash -c "
  '$PRA' a -f '$W/in/noise.pgm' -o '$W/st.pra' | grep -q 'stored as is' && '$PRA' list '$W/st.pra' | grep -q 'stored as is' &&
  '$PRA' x -q '$W/st.pra' -o '$W/st.pgm' && cmp -s '$W/in/noise.pgm' '$W/st.pgm'"
check "the extension comes back as written (image.PPM, scan.Pgm)" bash -c "
  cp '$W/in/color.ppm' '$W/image.PPM' && cp '$W/in/gray8.pgm' '$W/scan.Pgm' &&
  '$PRA' a -q -f '$W/image.PPM' '$W/scan.Pgm' -o '$W/ext/' && '$PRA' x -q '$W'/ext/*.pra -o '$W/extx/' &&
  cmp -s '$W/image.PPM' '$W/extx/image.PPM' && cmp -s '$W/scan.Pgm' '$W/extx/scan.Pgm'"
check "an extension the format does not keep: by the content" bash -c "
  cp '$W/in/rgba.pam' '$W/odd.x.y z' && '$PRA' a -q -f '$W/odd.x.y z' -o '$W/odd.pra' &&
  '$PRA' x -q '$W/odd.pra' -o '$W/oddx/' && cmp -s '$W/in/rgba.pam' '$W/oddx/odd.pam'"
check "list shows the original size" bash -c "'$PRA' list '$W/pra/color.pra' | grep -q 'original $(stat -c %s "$W/in/color.ppm") B'"

echo "--- existing outputs"
cp "$W/in/gray8.pgm" "$W/g.pgm"; "$PRA" a -q "$W/g.pgm"
echo old > "$W/g.pgm"
check "x over an existing file: refused (rc 1)" test "$(rc "$PRA" x "$W/g.pra")" -eq 1
check "  and the file is untouched" test "$(cat "$W/g.pgm")" = old
check "with -f: replaced" "$PRA" x -q -f "$W/g.pra"
check "  by the original" cmp -s "$W/g.pgm" "$W/in/gray8.pgm"
echo victim > "$W/victim"; rm -f "$W/g.pgm"; ln -s "$W/victim" "$W/g.pgm"
check "a symbolic link with the output's name: refused" test "$(rc "$PRA" x "$W/g.pra")" -eq 1
check "  with -f, the link is replaced" bash -c "'$PRA' x -q -f '$W/g.pra' && [ ! -L '$W/g.pgm' ]"
check "  and its target never written through" test "$(cat "$W/victim")" = victim
rm -f "$W/g.pgm"; ln -s "$W/nowhere" "$W/g.pgm"
check "a dangling link also takes the name" test "$(rc "$PRA" x "$W/g.pra")" -eq 1
check "  and nothing is created where it points" test ! -e "$W/nowhere"
rm -f "$W/g.pgm"

echo plain > "$W/plain"
check "a write the system refuses: its own words, not just a number" bash -c "
  ! '$PRA' a '$W/in/gray8.pgm' -o '$W/plain/x.pra' 2> '$W/err.txt' && grep -q 'could not write it: [A-Za-z]' '$W/err.txt'"
echo "--- what does not verify"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[20] ^= 1; open(sys.argv[2], 'wb').write(d)" "$W/g.pra" "$W/h.pra"
check "a .pra with one hash bit changed: rc 1" test "$(rc "$PRA" x "$W/h.pra")" -eq 1
check "  nothing written under the name" test ! -e "$W/h.pgm"
check "with --keep-corrupt: still rc 1" test "$(rc "$PRA" x --keep-corrupt "$W/h.pra")" -eq 1
check "  kept as h.pgm.corrupt, not as h.pgm" bash -c "[ -e '$W/h.pgm.corrupt' ] && [ ! -e '$W/h.pgm' ]"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[-20] ^= 4; open(sys.argv[2], 'wb').write(d)" "$W/g.pra" "$W/p.pra"
check "one bit in the pixels: rc 1, nothing written" bash -c "! '$PRA' x '$W/p.pra' 2>/dev/null && [ ! -e '$W/p.pgm' ]"
check "--max-output below the original: refused" test "$(rc "$PRA" x --max-output=100 "$W/g.pra" -o "$W/m.pgm")" -eq 1
check "  nothing written" test ! -e "$W/m.pgm"
check "--max-output=2K is enough for a 1549-byte original" "$PRA" x -q --max-output=2K "$W/g.pra" -o "$W/m.pgm"

echo "--- what is not for this command"
check "a on a .pra: rc 1" test "$(rc "$PRA" a "$W/g.pra" -o "$W/gg.pra")" -eq 1
check "x on an image: rc 1" test "$(rc "$PRA" x "$W/in/gray8.pgm" -o "$W/xx.pgm")" -eq 1
echo "not an image" > "$W/text.pgm"
check "a on something else: rc 1, says why, nothing written" bash -c "
  ! '$PRA' a '$W/text.pgm' 2> '$W/err2.txt' && grep -q 'not an image PRA takes' '$W/err2.txt' && [ ! -e '$W/text.pra' ]"
printf 'P1\n2 2\n0 1\n1 0\n' > "$W/plain.pbm"
check "a plain PBM: rc 1, named as unsupported" bash -c "
  ! '$PRA' a '$W/plain.pbm' 2> '$W/err3.txt' && grep -q 'unsupported variant' '$W/err3.txt'"
check "one bad among good ones: rc 1" test "$(rc "$PRA" a "$W/text.pgm" "$W/in/gray8.pgm" -o "$W/mix/")" -eq 1
check "  and the good one is written" test -e "$W/mix/gray8.pra"
check "a directory as input: rc 1" test "$(rc "$PRA" a "$W/in")" -eq 1
check "a missing input: rc 1" test "$(rc "$PRA" a "$W/missing.pgm")" -eq 1

echo "--- options"
check "-n writes nothing" bash -c "'$PRA' a -q -n '$W/in/gray8.pgm' -o '$W/dry.pra' && [ ! -e '$W/dry.pra' ]"
cp "$W/in/gray8.pgm" "$W/-dash.pgm"
check "-- and a file that starts with a dash" bash -c "cd '$W' && '$PRA' a -q -- -dash.pgm && [ -e '-dash.pra' ]"
check "-o with several inputs and no directory: rc 2" test "$(rc "$PRA" a "$W/in/gray8.pgm" "$W/in/color.ppm" -o "$W/one.pra")" -eq 2
cp "$W/in/gray8.pgm" "$W/写真ñ.pgm"
check "a non-ASCII name, both ways" bash -c "'$PRA' a -q '$W/写真ñ.pgm' -o '$W/u.pra' && '$PRA' x -q '$W/u.pra' -o '$W/写真ñ2.pgm' &&
  cmp -s '$W/写真ñ.pgm' '$W/写真ñ2.pgm'"
check "--output-dir" bash -c "'$PRA' a -q '$W/in/gray8.pgm' --output-dir='$W/od' && [ -e '$W/od/gray8.pra' ]"
check "an unknown option: rc 2" test "$(rc "$PRA" a --frobnicate "$W/in/gray8.pgm")" -eq 2
check "a glued -th4: rc 2, naming the spelling" bash -c "'$PRA' a -th4 x.pgm 2>&1 | grep -q 'write -th 4'"
check "an unknown command: rc 2" test "$(rc "$PRA" mix "$W/in/gray8.pgm")" -eq 2
check "no files: rc 2" test "$(rc "$PRA" a)" -eq 2
check "--help: rc 0" "$PRA" --help

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 40 ]
