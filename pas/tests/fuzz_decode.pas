{ A tool, not a test: the decoder against damaged streams. Each file given
  is coded, then its stream damaged (bytes changed, cut, a byte put in or
  taken out) and decoded, with 1 to 3 threads: never an exception, never
  more than the cap. Built without PRA_FAST, the range and overflow checks
  are on. The container's hash is what catches a damaged stream that still
  decodes.

    fuzz_decode <count> FILE... }
program fuzz_decode;
{$I ../pra.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, Math, pracodec;
var seed: Cardinal = 99991;
function Rand: Cardinal;
begin seed := seed xor (seed shl 13); seed := seed xor (seed shr 17); seed := seed xor (seed shl 5); Result := seed; end;
function ReadAll(const f: string): TBytes; var s: TFileStream;
begin s := TFileStream.Create(f, fmOpenRead); SetLength(Result, s.Size); if s.Size > 0 then s.ReadBuffer(Result[0], s.Size); s.Free; end;
var streams: array of TBytes; sizes: array of Int64; names: array of string; d, s, dm, back: TBytes; why: string;
  i, j, k, n, kind, bad, raised, oks, total: Integer; cap, p: Int64; st: TDecodeStatus; fs: TFileStream;
begin
  n := 0;
  for i := 2 to ParamCount do begin
    d := ReadAll(ParamStr(i));
    if not EncodeFile(d, s, why) then Continue;
    SetLength(streams, n + 1); SetLength(sizes, n + 1); SetLength(names, n + 1);
    streams[n] := s; sizes[n] := Length(d); names[n] := ExtractFileName(ParamStr(i)); Inc(n);
  end;
  Writeln(n, ' streams');
  total := StrToIntDef(ParamStr(1), 10000); bad := 0; raised := 0; oks := 0;
  for i := 1 to total do begin
    k := Integer(Rand mod Cardinal(n));
    dm := Copy(streams[k], 0, Length(streams[k]));
    kind := Integer(Rand mod 5);
    case kind of
      0, 1: for j := 1 to 1 + Integer(Rand mod 4) do dm[Integer(Rand mod Cardinal(Length(dm)))] := Byte(Rand);
      2: SetLength(dm, Integer(Rand mod Cardinal(Length(dm))));
      3: begin p := Rand mod Cardinal(Length(dm)); Insert([Byte(Rand)], dm, p); end;
      4: begin p := Rand mod Cardinal(Length(dm)); Delete(dm, p, 1 + Integer(Rand mod 8)); end;
    end;
    { mostly in the stream's head, where the structure is }
    if (kind = 1) and (Length(dm) > 0) then dm[Integer(Rand mod Cardinal(Min(Length(dm), 64)))] := Byte(Rand);
    cap := sizes[k] * 2;
    try
      st := DecodeFile(dm, cap, back, 1 + Integer(Rand mod 3));
      if st = dsOk then begin Inc(oks); if Length(back) > cap then Inc(bad); end;
    except on E: Exception do begin
      Inc(raised);
      if raised <= 3 then begin
        Writeln('raised on ', names[k], ' (', kind, '): ', E.ClassName, ' ', E.Message);
        fs := TFileStream.Create(ParamStr(0) + '.crash' + IntToStr(raised), fmCreate); fs.WriteBuffer(dm[0], Length(dm)); fs.Free;
      end;
    end; end;
    if i mod 20000 = 0 then begin Writeln(i, ' raised ', raised, ' over the cap ', bad, ' decoded ', oks); Flush(Output); end;
  end;
  Writeln('done: raised ', raised, ', over the cap ', bad, ', decoded anyway ', oks);
  if (raised > 0) or (bad > 0) then Halt(1);
end.
