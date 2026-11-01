{ A tool, not a test: compresses each file given with the codec (which
  verifies itself) and prints sizes and times; the totals count a file the
  codec does not take at its own size. }
program bench_codec;
{$I ../pra.inc}
uses {$ifdef UNIX} cthreads, {$endif} SysUtils, Classes, DateUtils, pracodec;

function ReadFile(const name: string): TBytes;
var fs: TFileStream;
begin
  Result := nil;
  fs := TFileStream.Create(name, fmOpenRead or fmShareDenyNone);
  try SetLength(Result, fs.Size); if Length(Result) > 0 then fs.ReadBuffer(Result[0], Length(Result)); finally fs.Free; end;
end;

var i: Integer; d, s: TBytes; why: string; t0: TDateTime; ms: Int64; tin, tout: Int64; ok: Boolean;
begin
  tin := 0; tout := 0;
  for i := 1 to ParamCount do begin
    d := ReadFile(ParamStr(i));
    t0 := Now;
    ok := EncodeFile(d, s, why, StrToIntDef(GetEnvironmentVariable('PRA_TH'), 1));
    ms := MilliSecondsBetween(Now, t0);
    Inc(tin, Length(d));
    if ok then begin
      Inc(tout, Length(s));
      Writeln(Format('%10d -> %10d  %6.2f%%  %6d ms  %s', [Length(d), Length(s), 100.0 * Length(s) / Length(d), ms, ExtractFileName(ParamStr(i))]));
    end else begin
      Inc(tout, Length(d));
      Writeln(Format('%10d    (%s)  %s', [Length(d), why, ExtractFileName(ParamStr(i))]));
    end;
  end;
  if tin > 0 then Writeln(Format('total %d -> %d  %.2f%%', [tin, tout, 100.0 * tout / tin]));
end.
