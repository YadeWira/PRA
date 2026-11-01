{ A tool, not a test: what the parsers say about each file given. }
program scan_raster;
{$I ../pra.inc}
uses SysUtils, Classes, praraster, prapnm;
var i: Integer; d: TBytes; L: TRasterLayout; st: TParseStatus; fs: TFileStream; tail: Int64;
begin
  for i := 1 to ParamCount do begin
    d := nil;
    fs := TFileStream.Create(ParamStr(i), fmOpenRead or fmShareDenyNone);
    try SetLength(d, fs.Size); if Length(d) > 0 then fs.ReadBuffer(d[0], Length(d)); finally fs.Free; end;
    st := ParsePnm(d, L);
    if st = psOk then begin
      tail := Length(d) - L.dataOffset - L.dataLength;
      Writeln(Format('%-5s %dx%dx%d %2d bits  header %d  pixels %d  tail %d  %s',
        [FormatName(L.format), L.width, L.height, L.channels, L.bits, L.dataOffset, L.dataLength, tail, ParamStr(i)]))
    end else
      Writeln(Format('%-22s %s', [StatusName(st), ParamStr(i)]));
  end;
end.
