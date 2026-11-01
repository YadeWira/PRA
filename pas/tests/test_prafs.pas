{ Writing the output without following links, without half-done writes and
  without leaving a file whose hash does not match under its name
  (doc/FORMAT.md 4.5).

    test_prafs <temp_dir>   (prafs_* is created and deleted inside) }
program test_prafs;
{$I ../pra.inc}
{$ifopt R-}{$fatal test_prafs: range checks ($R+) are mandatory}{$endif}
uses SysUtils, Classes, {$ifndef MSWINDOWS} BaseUnix, {$endif} prablake3, prafs;

var cells, failures: Integer;
procedure Check(ok: Boolean; const what: string);
begin Inc(cells); if ok then Writeln('  ', what:64, '  ok') else begin Inc(failures); Writeln('  ', what:64, '  FAIL'); end; end;

function B(const s: RawByteString): TBytes;
begin Result := nil; SetLength(Result, Length(s)); if s <> '' then Move(s[1], Result[0], Length(s)); end;
function H16(const s: RawByteString): THash16; begin Result := Blake3_128(B(s)); end;
function ReadText(const f: string): RawByteString; var st: TFileStream;
begin
  st := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
  try Result := ''; SetLength(Result, st.Size); if st.Size > 0 then st.ReadBuffer(Result[1], st.Size);
  finally st.Free; end;
end;
procedure PutText(const f: string; const s: RawByteString); var st: TFileStream;
begin
  st := TFileStream.Create(f, fmCreate);
  try if s <> '' then st.WriteBuffer(s[1], Length(s)); finally st.Free; end;
end;
function Exists(const p: string): Boolean;
{$ifndef MSWINDOWS} var st: Stat; {$endif}
begin {$ifdef MSWINDOWS} Result := FileExists(p) or DirectoryExists(p); {$else} Result := fpLstat(PChar(p), st) = 0; {$endif} end;
function IsLink(const p: string): Boolean;
{$ifndef MSWINDOWS} var st: Stat; {$endif}
begin {$ifdef MSWINDOWS} Result := False; {$else} Result := (fpLstat(PChar(p), st) = 0) and fpS_ISLNK(st.st_mode); {$endif} end;
procedure MakeLink(const target, p: string);
begin {$ifndef MSWINDOWS} if fpSymlink(PChar(target), PChar(p)) <> 0 then raise Exception.Create('symlink ' + p); {$endif} end;

procedure DeleteTree(const d: string);
var sr: TSearchRec;
begin
  if IsLink(d) then begin DeleteFile(d); Exit; end;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile or faSymLink, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if IsLink(IncludeTrailingPathDelimiter(d) + sr.Name) then DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name)
      else if (sr.Attr and faDirectory) <> 0 then DeleteTree(IncludeTrailingPathDelimiter(d) + sr.Name)
      else DeleteFile(IncludeTrailingPathDelimiter(d) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(d);
end;

var TMP: string;
function TempDir(const name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(TMP) + 'prafs_' + name;
  DeleteTree(Result);
  if not ForceDirectories(Result) then raise Exception.Create('could not create ' + Result);
end;
var d, outside: string; q: RawByteString; f: TFsResult;
    oc: TOutcome; i: Integer; foreign, hGood: THash16;
const TEMP_DIRS: array[0..10] of string = ('verify', 'keep', 'final_outside', 'final_outside_x', 'dangling',
        'dangling_x', 'hard', 'hard_x', 'foreign', 'corrupt_link', 'dirs');
begin
  cells := 0; failures := 0;
  if ParamCount < 1 then begin Writeln('usage: test_prafs <temp_dir>'); Halt(2); end;
  TMP := ParamStr(1);

  Writeln('--- Parent: Path::parent');
  { Parent returned garbage on the normal path (Result := True was missing):
    in this binary it gave false 1000 out of 1000 times when called directly. }
  Check(Parent('x', q) and (q = ''), 'x -> empty, like Path::parent');
  Check(not Parent('', q), 'empty has no parent');
  Check(Parent('a/b', q) and (q = 'a'), 'relative: a/b -> a');
  {$ifndef MSWINDOWS}
  Check(Parent('/a/b/c', q) and (q = '/a/b'), '/a/b/c -> /a/b');
  Check(Parent('/a', q) and (q = '/'), '/a -> /');
  Check(not Parent('/', q), '/ has no parent');
  Check(Parent('a\b', q) and (q = ''), 'on Unix the backslash is part of the name');
  {$else}
  Check(Parent('C:\a\b', q) and (q = 'C:\a'), 'C:\a\b -> C:\a');
  Check(Parent('C:\a', q) and (q = 'C:\'), 'C:\a -> C:\');
  Check(not Parent('C:\', q), 'C:\ has no parent');
  { the path is typed by the user: on Windows '/' separates too }
  Check(Parent('C:/a/b', q) and (q = 'C:/a'), 'C:/a/b -> C:/a');
  Check(Parent('C:/a', q) and (q = 'C:/'), 'C:/a -> C:/');
  Check(not Parent('C:/', q), 'C:/ has no parent');
  Check(Parent('dir\sub/x.ppm', q) and (q = 'dir\sub'), 'mixed separators');
  Check(Parent('\\?\C:\a', q) and (q = '\\?\C:\'), '\\?\C:\a -> the root');
  Check(Parent('\\?\UNC\srv\share\a', q) and (q = '\\?\UNC\srv\share\'), 'UNC: \\srv\share\a -> \\srv\share\');
  Check(not Parent('\\srv\share\', q), 'UNC without prefix: the share is the root');
  {$endif}

  Writeln('--- a_hash_that_does_not_match_leaves_no_file_under_its_name');
  d := TempDir('verify');
  f := WriteVerified(d + '/ok.ppm', B('correct contents'), H16('correct contents'), omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocVerified) and (oc.path = d + '/ok.ppm'), 'positive control: Verified');
  Check(ReadText(d + '/ok.ppm') = 'correct contents', 'the good case stays on disk');
  foreign := H16('something else');
  f := WriteVerified(d + '/bad.ppm', B('correct contents'), foreign, omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocDeleted), 'foreign hash: Deleted');
  hGood := H16('correct contents');
  Check(CompareMem(@oc.expected, @foreign, 16) and CompareMem(@oc.actual, @hGood, 16),
     'expected and actual are right');
  Check(not Exists(d + '/bad.ppm'), 'the file with a bad hash was not left under its name');
  f := WriteVerified(d + '/empty.ppm', nil, H16(''), omDelete, False, oc);
  Check(f.Ok and (oc.kind = ocVerified) and Exists(d + '/empty.ppm'), 'zero bytes: created and verified');

  Writeln('--- keep_renames_and_never_leaves_the_good_name');
  d := TempDir('keep');
  f := WriteVerified(d + '/photo.ppm', B('salvageable bytes'), foreign, omKeep, False, oc);
  Check(f.Ok and (oc.kind = ocKept) and (ExtractFileName(oc.path) = 'photo.ppm.corrupt'), 'Kept as photo.ppm.corrupt');
  Check(ReadText(d + '/photo.ppm.corrupt') = 'salvageable bytes', 'the bytes survive');
  Check(not Exists(d + '/photo.ppm'), 'the good name stays free');
  f := WriteVerified(d + '/photo.ppm', B('another try'), foreign, omKeep, False, oc);
  Check(f.Ok and (ExtractFileName(oc.path) = 'photo.ppm.corrupt.1'), 'the second one goes to .corrupt.1');
  Check(not Exists(d + '/photo.ppm'), 'and the good name is still free');
  Check(ReadText(d + '/photo.ppm.corrupt') = 'salvageable bytes', 'the first .corrupt is not overwritten');

  Writeln('--- without_overwrite_a_foreign_file_stays_intact');
  d := TempDir('foreign');
  PutText(d + '/f.ppm', 'the user''s');
  f := WriteVerified(d + '/f.ppm', B('x'), H16('x'), omDelete, False, oc);
  Check(not f.Ok, 'does not write: ' + f.Text);
  Check(ReadText(d + '/f.ppm') = 'the user''s', 'the user''s file stays intact');
  f := WriteVerified(d + '/f.ppm', B('bad'), H16('other'), omDelete, True, oc);
  Check(f.Ok and (oc.kind = ocDeleted) and (ReadText(d + '/f.ppm') = 'the user''s'),
     'with overwrite and a foreign hash: the user''s stays intact');
  f := WriteVerified(d + '/f.ppm', B('bad'), H16('other'), omKeep, True, oc);
  Check(f.Ok and (oc.kind = ocKept) and (ReadText(d + '/f.ppm') = 'the user''s')
     and (ReadText(d + '/f.ppm.corrupt') = 'bad'), '  and with keep, too: it goes to .corrupt');
  f := WriteVerified(d + '/f.ppm', B('x'), H16('x'), omDelete, True, oc);
  Check(f.Ok and (ReadText(d + '/f.ppm') = 'x'), 'with overwrite: replaces it');
  Check(not Exists(d + '/f.ppm.pra-tmp0'), '  without leaving the temporary');
  PutText(d + '/g.ppm.pra-tmp0', 'taken');
  f := WriteVerified(d + '/g.ppm', B('y'), H16('y'), omDelete, True, oc);
  Check(f.Ok and (ReadText(d + '/g.ppm') = 'y') and (ReadText(d + '/g.ppm.pra-tmp0') = 'taken'),
     '  with temporary 0 taken, it uses another and does not touch it');
  ForceDirectories(d + '/folder.ppm');
  f := WriteVerified(d + '/folder.ppm', B('x'), H16('x'), omDelete, True, oc);
  Check((not f.Ok) and DirectoryExists(d + '/folder.ppm'), 'over a directory, not even with overwrite: ' + f.Text);

  Writeln('--- intermediate directories');
  d := TempDir('dirs');
  f := WriteVerified(d + '/a/b/c/x.ppm', B('x'), H16('x'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/a/b/c/x.ppm') = 'x'), 'creates the missing ones');
  PutText(d + '/file', 'x');
  f := WriteVerified(d + '/file/x.ppm', B('x'), H16('x'), omDelete, False, oc);
  Check(not f.Ok, 'a file in place of a directory: ' + f.Text);
  if not SetCurrentDir(d) then raise Exception.Create('chdir');
  f := WriteVerified('rel.ppm', B('r'), H16('r'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/rel.ppm') = 'r'), 'relative path, no directory');
  f := WriteVerified('sub/rel.ppm', B('r'), H16('r'), omDelete, False, oc);
  Check(f.Ok and (ReadText(d + '/sub/rel.ppm') = 'r'), 'relative path with a directory');
  SetCurrentDir(TMP);

  { --- Defects measured on 2026-10-09 in the previous Rust version. }
  {$ifndef MSWINDOWS}
  Writeln('--- final_link_pointing_outside_is_not_followed_when_overwriting');
  d := TempDir('final_outside'); outside := TempDir('final_outside_x');
  PutText(outside + '/victim.txt', 'original');
  MakeLink(outside + '/victim.txt', d + '/a.ppm');
  f := WriteVerified(d + '/a.ppm', B('new'), H16('new'), omDelete, False, oc);
  Check(not f.Ok, 'without overwrite: the link takes the name, ' + f.Text);
  Check(ReadText(outside + '/victim.txt') = 'original', '  outside intact');
  f := WriteVerified(d + '/a.ppm', B('new'), H16('new'), omDelete, True, oc);
  Check(f.Ok and (oc.kind = ocVerified), 'with overwrite: Verified');
  Check(ReadText(outside + '/victim.txt') = 'original', '  outside intact');
  Check(not IsLink(d + '/a.ppm'), '  the link was replaced');
  Check(ReadText(d + '/a.ppm') = 'new', '  with the new contents');

  Writeln('--- a_dangling_link_takes_the_name');
  d := TempDir('dangling'); outside := TempDir('dangling_x');
  MakeLink(outside + '/new.txt', d + '/b.ppm');
  f := WriteVerified(d + '/b.ppm', B('x'), H16('x'), omDelete, False, oc);
  Check((not f.Ok) and (f.code = ESysEEXIST), 'Io(EEXIST), ' + f.Text);
  Check(not Exists(outside + '/new.txt'), 'nothing was created outside');

  Writeln('--- a_hard_link_is_not_written_through');
  d := TempDir('hard'); outside := TempDir('hard_x');
  PutText(outside + '/victim.txt', 'original');
  if fpLink(PChar(outside + '/victim.txt'), PChar(d + '/c.ppm')) <> 0 then raise Exception.Create('link');
  f := WriteVerified(d + '/c.ppm', B('new'), H16('new'), omDelete, True, oc);
  Check(f.Ok, 'writes');
  Check(ReadText(outside + '/victim.txt') = 'original', 'outside intact');

  Writeln('--- corrupt_name_taken_by_a_dangling_link');
  d := TempDir('corrupt_link');
  MakeLink(d + '/does_not_exist', d + '/g.ppm.corrupt');
  f := WriteVerified(d + '/g.ppm', B('x'), H16('other'), omKeep, False, oc);
  Check(f.Ok and (ExtractFileName(oc.path) = 'g.ppm.corrupt.1'), 'goes to .corrupt.1');
  Check(IsLink(d + '/g.ppm.corrupt'), 'the link is still there');
  {$endif}

  { a declared array and not `for n in [...]`: with literals, FPC trims them to the length of the first }
  for i := 0 to High(TEMP_DIRS) do DeleteTree(IncludeTrailingPathDelimiter(TMP) + 'prafs_' + TEMP_DIRS[i]);

  Writeln;
  Writeln(cells, ' cells, ', failures, ' failures');
  {$ifdef MSWINDOWS} if (failures > 0) or (cells < 30) then Halt(1);
  {$else} if (failures > 0) or (cells < 39) then Halt(1); {$endif}
end.
