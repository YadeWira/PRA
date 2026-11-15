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
printf 'P2 2 1 255\n7 300\n' > "$W/plain.pgm"
check "a plain PGM with 300 in 8 bits: rc 1, named as unsupported" bash -c "
  ! '$PRA' a '$W/plain.pgm' 2> '$W/err3.txt' && grep -q 'unsupported variant' '$W/err3.txt'"
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
echo "--- interrupted runs, and the disk"
# strace with fault injection holds the write at its fsync, between a
# complete temporary and its rename, for as long as the test needs: the
# signal lands exactly there. Without it, the signal is sent as soon as a
# temporary shows up (a race the write usually wins: a weaker check).
mkdir -p "$W/sig"
for i in $(seq 24); do cp "$W/pra/color.pra" "$W/sig/c$i.pra"; done
HOLD=0
if command -v strace > /dev/null 2>&1 &&
   strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:delay_enter=1ms true > /dev/null 2>&1; then HOLD=1; fi
cat > "$W/sig.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
pra, d, sig, hold, ignore = sys.argv[1], sys.argv[2], getattr(signal, sys.argv[3]), sys.argv[4] == '1', sys.argv[5] == '1'
out = os.path.join(d, 'o')
# ignored, the run goes to the end: one file, held twice (its data, its directory)
files = sorted(glob.glob(os.path.join(d, 'c*.pra')))[:1 if ignore else None]
cmd = [pra, 'x', '-q', '-f', '-th', '1'] + files + ['-o', out + '/']
if hold:
    cmd = ['strace', '-f', '-qq', '-o', '/dev/null', '-e', 'trace=fsync', '-e', 'inject=fsync:delay_enter=3s'] + cmd
# like nohup: an ignored signal stays ignored. Otherwise its default, set
# here: a suite started in the background by a script (cli.sh &) has
# SIGINT ignored, which pra would rightly keep (the cell failed so, never
# from the load itself)
def pre():
    signal.signal(sig, signal.SIG_IGN if ignore else signal.SIG_DFL)
p = subprocess.Popen(cmd, preexec_fn=pre)
def state(pid):
    try: return open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()[0]
    except (OSError, IndexError): return ''
# a temporary there (polled, not a fixed delay: the load only makes it later)
seen, t0 = False, time.time()
while time.time() - t0 < 120 and p.poll() is None:
    if glob.glob(os.path.join(out, '.pra-tmp-*')): seen = True; break
    time.sleep(0.005)
target = p.pid
if hold and seen and p.poll() is None:
    target = int(open('/proc/%d/task/%d/children' % (p.pid, p.pid)).read().split()[0])
    # and the write held at its fsync: stopped by the tracer (state t) on
    # five reads in a row, 20 ms apart (its other stops last microseconds)
    run, t1 = 0, time.time()
    while run < 5 and time.time() - t1 < 60 and p.poll() is None:
        run = run + 1 if state(target) == 't' else 0
        time.sleep(0.02)
if p.poll() is None: os.kill(target, sig)
rc = p.wait()
rc = 128 - rc if rc < 0 else rc
left = glob.glob(os.path.join(out, '.pra-tmp-*'))
print(rc, 'seen' if seen else 'missed', len(left))
EOF
sigcheck() {   # sigcheck <signal> <rc> [ignore]: no temporary left, and the conventional rc
  rm -rf "$W/sig/o"
  local r; r=$(python3 -I "$W/sig.py" "$PRA" "$W/sig" "$1" "$HOLD" "${3:-0}") || return 1
  set -- $r "$2"
  [ "$3" -eq 0 ] || return 1                         # a temporary left behind
  if [ "$HOLD" = 1 ]; then [ "$2" = seen ] && [ "$1" -eq "$4" ]
  else [ "$1" -eq "$4" ] || [ "$1" -eq 0 ]; fi        # the write may have won the race
}
if [ "$HOLD" = 1 ]; then how="held at its fsync"; else how="strace not here: racy"; fi
check "SIGINT while a temporary is written: deleted, rc 130 ($how)" sigcheck SIGINT 130
check "SIGTERM: the same, rc 143" sigcheck SIGTERM 143
check "SIGHUP: the same, rc 129" sigcheck SIGHUP 129
check "SIGPIPE: the same, rc 141" sigcheck SIGPIPE 141
# the real way to get it: the reader of the listing goes away (| head)
cat > "$W/pipe.py" <<'EOF2'
import glob, os, subprocess, sys
pra, d = sys.argv[1], sys.argv[2]
out = os.path.join(d, 'p')
bad = 0
for _ in range(3):
    subprocess.run(['rm', '-rf', out])
    r, w = os.pipe()
    os.close(r)                               # nobody reads: the first line written gets SIGPIPE
    p = subprocess.Popen([pra, 'x', '-f', '-th', '8'] + sorted(glob.glob(os.path.join(d, 'c*.pra'))) + ['-o', out + '/'],
                         stdout=w, preexec_fn=lambda: __import__('signal').signal(13, __import__('signal').SIG_DFL))
    os.close(w)
    rc = p.wait()
    rc = 128 - rc if rc < 0 else rc
    left = glob.glob(os.path.join(out, '.pra-tmp-*'))
    if left or rc not in (0, 141): bad += 1; print(rc, left)
sys.exit(1 if bad else 0)
EOF2
check "  the reader of its output gone (pra x | head): no temporary left, 3 runs" python3 -I "$W/pipe.py" "$PRA" "$W/sig"
if [ "$HOLD" = 1 ]; then
  check "a SIGINT ignored by whoever started it (nohup) stays ignored: rc 0" bash -c "
    r=\$(python3 -I '$W/sig.py' '$PRA' '$W/sig' SIGINT 1 1) && [ \"\$r\" = '0 seen 0' ] && [ -e '$W/sig/o/c1.ppm' ]"
  check "the data and then the directory reach the disk: fsync, rename, fsync" bash -c "
    strace -f -qq -o '$W/sync.txt' -e trace=fsync,rename,renameat2,link '$PRA' a -q -f '$W/in/gray8.pgm' -o '$W/sync.pra' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2|link)\(' '$W/sync.txt' | sed -E 's/^[0-9]+ +//; s/renameat2|link/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync '"
  check "  and with -f, through the rename on top" bash -c "
    strace -f -qq -o '$W/sync2.txt' -e trace=fsync,rename,renameat2 '$PRA' x -q -f '$W/sync.pra' -o '$W/sync.pgm' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2)\(' '$W/sync2.txt' | sed -E 's/^[0-9]+ +//; s/renameat2/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync ' && cmp -s '$W/sync.pgm' '$W/in/gray8.pgm'"
  check "the directory flush fails: rc 1, and the message says the file is there" bash -c "
    rm -f '$W/sync4.pra'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=2 '$PRA' a -q '$W/in/gray8.pgm' -o '$W/sync4.pra' 2> '$W/sync4.txt' &&
    grep -q 'sync4.pra: written, but its directory could not be flushed to the disk' '$W/sync4.txt' &&
    ! grep -q 'could not write it' '$W/sync4.txt' && [ -s '$W/sync4.pra' ]"
  check "  the data flush fails: rc 1, nothing left, not even a temporary" bash -c "
    rm -rf '$W/sync5'; mkdir '$W/sync5'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=1 '$PRA' a -q '$W/in/gray8.pgm' -o '$W/sync5/g.pra' 2> '$W/sync5.txt' &&
    grep -q 'could not write it' '$W/sync5.txt' && [ -z \"\$(ls -A '$W/sync5')\" ]"
  check "--no-sync: no fsync at all, and the file comes back" bash -c "
    strace -f -qq -o '$W/sync3.txt' -e trace=fsync,fdatasync '$PRA' a -q -f --no-sync '$W/in/gray8.pgm' -o '$W/sync3.pra' &&
    ! grep -qE 'fsync|fdatasync' '$W/sync3.txt' && '$PRA' x -q -f '$W/sync3.pra' -o '$W/sync3.pgm' && cmp -s '$W/sync3.pgm' '$W/in/gray8.pgm'"
else
  check "--no-sync: the file comes back" bash -c "
    '$PRA' a -q -f --no-sync '$W/in/gray8.pgm' -o '$W/sync3.pra' && '$PRA' x -q -f --no-sync '$W/sync3.pra' -o '$W/sync3.pgm' &&
    cmp -s '$W/sync3.pgm' '$W/in/gray8.pgm'"
  check "the data reaches the disk before the name (no strace: the round trip)" bash -c "
    '$PRA' a -q -f '$W/in/gray8.pgm' -o '$W/sync.pra' && '$PRA' x -q -f '$W/sync.pra' -o '$W/sync.pgm' &&
    cmp -s '$W/sync.pgm' '$W/in/gray8.pgm'"
fi

# what a SIGKILL leaves: noticed by the next run there, deleted only when asked
L="$W/left"; rm -rf "$L"; mkdir -p "$L"; cp "$W/in/gray8.pgm" "$L/g.pgm"
sh -c 'exit 0' & wait $!; DEAD=$!                     # a pid that is gone
while kill -0 "$DEAD" 2> /dev/null; do DEAD=$((DEAD + 1)); done
mk() { echo left > "$L/$1"; touch -d "${2:-2 hours ago}" "$L/$1"; }
mk ".pra-tmp-$DEAD-0"                                 # old, of a dead run
mk ".pra-tmp-$DEAD-1" now                             # fresh: maybe still being written
mk ".pra-tmp-$$-0"                                    # old, but its process (this shell) lives
mk ".pra-tmp-$DEAD-x"                                 # not PRA's pattern
echo victim > "$W/left_victim"; ln -s "$W/left_victim" "$L/.pra-tmp-$DEAD-2"; touch -h -d '2 hours ago' "$L/.pra-tmp-$DEAD-2"
check "a run that writes there names the leftovers, rc 0, deletes nothing" bash -c "
  '$PRA' a -q '$L/g.pgm' 2> '$W/left.txt' && grep -q 'found 1 leftover temporary of an interrupted run' '$W/left.txt' &&
  grep -q -- '--clean-temps' '$W/left.txt' && [ -e '$L/.pra-tmp-$DEAD-0' ]"
check "--clean-temps deletes the old one of a dead pid" bash -c "
  '$PRA' a -q -f --clean-temps '$L/g.pgm' 2> '$W/left2.txt' && grep -q 'deleted 1 leftover temporary' '$W/left2.txt' &&
  [ ! -e '$L/.pra-tmp-$DEAD-0' ]"
check "  not a fresh one, not a live process's, not another name" bash -c "
  [ -e '$L/.pra-tmp-$DEAD-1' ] && [ -e '$L/.pra-tmp-$$-0' ] && [ -e '$L/.pra-tmp-$DEAD-x' ]"
check "  not a symbolic link with the name, nor its target" bash -c "
  [ -L '$L/.pra-tmp-$DEAD-2' ] && [ \"\$(cat '$W/left_victim')\" = victim ]"
check "a run with nothing left there says nothing" bash -c "
  '$PRA' a -q -f --clean-temps '$L/g.pgm' 2> '$W/left3.txt' && [ ! -s '$W/left3.txt' ]"
check "--clean-temps with list: rc 2" test "$(rc "$PRA" list --clean-temps "$W/g.pra")" -eq 2
check "--no-sync with list: rc 2" test "$(rc "$PRA" list --no-sync "$W/g.pra")" -eq 2


echo "--- version, selftest, --cpu"
check "--version: rc 0, the version and the SIMD path" bash -c "'$PRA' --version | grep -q '^pra ' && '$PRA' --version | grep -q '^cpu_path: '"
check "selftest: rc 0, every check passed" bash -c "'$PRA' selftest | grep -q 'checks passed'"
check "selftest --cpu=plain: that path alone" bash -c "'$PRA' selftest --cpu=plain | grep -q 'on 1 path(s) (plain)'"
check "--cpu=plain and the default path make the same .pra" bash -c "
  '$PRA' a -q -f --cpu=plain '$W/in/color.ppm' -o '$W/cpu1.pra' && '$PRA' a -q -f '$W/in/color.ppm' -o '$W/cpu2.pra' &&
  cmp -s '$W/cpu1.pra' '$W/cpu2.pra'"
check "--cpu with a space: rc 2, naming --cpu=" bash -c "'$PRA' a --cpu plain x.pgm 2>&1 | grep -q 'write --cpu=plain'"
check "--cpu=avx512: rc 2" test "$(rc "$PRA" a --cpu=avx512 "$W/in/gray8.pgm")" -eq 2
check "selftest with a file: rc 2" test "$(rc "$PRA" selftest "$W/in/gray8.pgm")" -eq 2

echo "--- t"
check "t: OK for each .pra, rc 0" bash -c "'$PRA' t '$W/pra/color.pra' '$W/pra/gray8.pra' | grep -c ': OK' | grep -qx 2"
cp "$W/pra/color.pra" "$W/bad.pra"; printf '\x55' | dd of="$W/bad.pra" bs=1 seek=60 conv=notrunc 2> /dev/null
check "t on a damaged .pra: FAILED, rc 1" bash -c "'$PRA' t '$W/bad.pra' 2>&1 | grep -q FAILED; [ \$('$PRA' t '$W/bad.pra' > /dev/null 2>&1; echo \$?) -eq 1 ]"
check "t on an image: not a .pra, rc 1" test "$(rc "$PRA" t "$W/in/gray8.pgm")" -eq 1
check "t -o: rc 2" test "$(rc "$PRA" t "$W/pra/color.pra" -o "$W/x/")" -eq 2
check "t writes nothing" bash -c "rm -rf '$W/tdir' && mkdir '$W/tdir' && cp '$W/pra/color.pra' '$W/tdir/' && '$PRA' t -q '$W/tdir/color.pra' && [ \$(ls '$W/tdir' | wc -l) -eq 1 ]"

echo "--- info"
check "info of an image: its layout and what a does" bash -c "
  '$PRA' info '$W/in/color.ppm' > '$W/info.txt' && grep -q 'width: 64' '$W/info.txt' && grep -q 'pra: takes it' '$W/info.txt'"
check "info of a .pra: the container, the stream, extracts it" bash -c "
  '$PRA' info '$W/pra/color.pra' > '$W/info2.txt' && grep -q 'container:' '$W/info2.txt' && grep -q 'stream:' '$W/info2.txt' &&
  grep -q 'extracts it' '$W/info2.txt'"
check "info of a file of several images: its parts" bash -c "'$PRA' info '$W/in/ico_three.ico' | grep -q 'images: '"
check "info of what PRA does not take: rc 0, refuses it" bash -c "
  head -c 300 /dev/urandom > '$W/junk.bin' && '$PRA' info '$W/junk.bin' | grep -q 'refuses it'"
check "info --json: one object a line, then the summary" bash -c "
  '$PRA' info --json '$W/in/color.ppm' '$W/pra/color.pra' | python3 -c 'import json,sys; l=[json.loads(x) for x in sys.stdin]; assert len(l)==3 and \"summary\" in l[2] and l[0][\"pra\"][\"takes\"]'"
check "info of a missing file: rc 1" test "$(rc "$PRA" info "$W/nowhere.pgm")" -eq 1

echo "--- report"
check "report FILE: the system, the command, the file, a link" bash -c "
  '$PRA' report '$W/in/color.ppm' > '$W/rep.txt' && grep -q '== PRA and the system' '$W/rep.txt' &&
  grep -q 'pra report color.ppm' '$W/rep.txt' && grep -q 'https://github.com/YadeWira/PRA/issues/new' '$W/rep.txt'"
check "  no folder names in it" bash -c "! grep -qF '$W' '$W/rep.txt'"
check "  no header text in it (a PGM comment)" bash -c "
  printf 'P5\n# secret-comment-xyz\n4 4\n255\n0123456789abcdef' > '$W/sec.pgm' && '$PRA' report '$W/sec.pgm' > '$W/rep2.txt' &&
  ! grep -q 'secret-comment-xyz' '$W/rep2.txt'"
check "report -o: written there, never over an existing file" bash -c "
  rm -f '$W/rep3.txt' && '$PRA' report '$W/in/color.ppm' -o '$W/rep3.txt' > /dev/null && [ -s '$W/rep3.txt' ] &&
  [ \$('$PRA' report '$W/in/color.ppm' -o '$W/rep3.txt' > /dev/null 2>&1; echo \$?) -eq 1 ]"
check "report --with-file: a copy beside the report" bash -c "
  rm -rf '$W/rw' && mkdir '$W/rw' && '$PRA' report '$W/in/color.ppm' -o '$W/rw/r.txt' --with-file > /dev/null &&
  cmp -s '$W/rw/pra-report-color.ppm' '$W/in/color.ppm'"
check "report --with-file without a file: rc 2" test "$(rc "$PRA" report --with-file)" -eq 2
check "report without a file: rc 0, the system alone" bash -c "'$PRA' report | grep -q '== No file'"

echo "--- --stats and --json"
check "a --stats: the stages and the run's line" bash -c "
  '$PRA' a -f --stats '$W/in/color.ppm' -o '$W/st1.pra' > '$W/st.txt' && grep -q 'stats: read' '$W/st.txt' &&
  grep -q 'band(s)' '$W/st.txt' && grep -q 'MB/s' '$W/st.txt'"
check "x --json: each file, then the summary, valid JSON" bash -c "
  '$PRA' x -f --json '$W/st1.pra' -o '$W/st1.ppm' | python3 -c 'import json,sys; l=[json.loads(x) for x in sys.stdin]; assert l[0][\"ok\"] and l[1][\"summary\"][\"command\"]==\"x\"'"
check "a --json on a file it refuses: ok false, error, rc 1" bash -c "
  ! '$PRA' a -f --json '$W/junk.bin' -o '$W/junk.pra' 2> /dev/null > '$W/js.txt'; python3 -c 'import json; l=[json.loads(x) for x in open(\"$W/js.txt\")]; assert not l[0][\"ok\"] and l[0][\"error\"]'"
check "--stats with list: rc 2" test "$(rc "$PRA" list --stats "$W/pra/color.pra")" -eq 2
check "--json with bench: rc 2" test "$(rc "$PRA" bench --json "$W/in/color.ppm")" -eq 2

echo "--- --no-verify"
check "a --no-verify: the same .pra" bash -c "
  '$PRA' a -q -f --no-verify '$W/in/ico_three.ico' -o '$W/nv.pra' && cmp -s '$W/nv.pra' '$W/pra/ico_three.pra'"
check "--no-verify with x: rc 2" test "$(rc "$PRA" x --no-verify "$W/pra/color.pra")" -eq 2

echo "--- bench"
check "bench: a, a --no-verify and x, rc 0, nothing beside the input" bash -c "
  rm -rf '$W/bn' && mkdir '$W/bn' && cp '$W/in/color.ppm' '$W/bn/' && '$PRA' bench -r 1 '$W/bn/color.ppm' > '$W/bn.txt' &&
  grep -q 'a --no-verify' '$W/bn.txt' && grep -qE '^  x ' '$W/bn.txt' && [ \$(ls '$W/bn' | wc -l) -eq 1 ]"
check "bench -r 0: rc 2" test "$(rc "$PRA" bench -r 0 "$W/in/color.ppm")" -eq 2

echo "--- a bug in PRA"
check "a range error: rc 3, and what to do" bash -c "
  PRA_TEST_CRASH=range '$PRA' a -q -f '$W/in/gray8.pgm' -o '$W/bug.pra' 2> '$W/bug.txt'; [ \$? -eq 3 ] &&
  grep -q 'This is a bug in PRA. Please run: pra report' '$W/bug.txt'"
check "an access violation: rc 3" bash -c "PRA_TEST_CRASH=access '$PRA' a -q -f '$W/in/gray8.pgm' -o '$W/bug.pra' 2> /dev/null; [ \$? -eq 3 ]"

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 100 ]
