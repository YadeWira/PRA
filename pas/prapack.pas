{ A whole file to a .pra and back: the codec (pracodec) inside the format
  (praformat), in the order doc/FORMAT.md gives.

  Pack: compress (which verifies its own stream), hash the original, write;
  a stream no smaller than the original is not worth it, and the original
  is stored instead (praformat.FLAG_STORED). A file no parser takes is
  refused, with the parser's reason: PRA is not a general compressor.
  Unpack: open the format, refuse a declared size above the caller's cap,
  decode with that size as the decoder's cap, check the length and the hash.
  What comes out of Unpack with ukOk is the original, byte for byte. }
unit prapack;

{$I pra.inc}
{$ifopt R-}{$fatal prapack: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal prapack: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, prablake3, praformat, pracodec;

type
  TPackError = (
    ukOk,
    { the .pra is malformed (detail in fmt) }
    ukFormat,
    { no parser takes the input, or it did not come back (detail in why) }
    ukNotRaster,
    { the codec stream inside is damaged (detail in dec) }
    ukCodec,
    { the declared size is above the caller's cap }
    ukTooLarge,
    { decoded, but not to the declared length or hash: damaged }
    ukSizeMismatch, ukHashMismatch);

  TPackResult = record
    err: TPackError;
    fmt: TPraResult;
    dec: TDecodeStatus;
    why: string;
    { Pack: the original went in as it is (the codec would not have made it smaller) }
    stored: Boolean;
    { Unpack: the original's extension the .pra keeps, without the dot }
    ext: string;
    function Ok: Boolean;
    { "Format(RatioExceeded)", "NotRaster(unsupported variant)", "HashMismatch" }
    function Text: string;
  end;

{ The original file -> .pra. ext: the original's extension without the dot,
  kept for the extracted name when the format allows it. }
function Pack(const original: TBytes; out pra: TBytes; const ext: string = ''; threads: Integer = 1): TPackResult;

{ .pra -> the original. maxOutput: the largest original accepted. With
  ukHashMismatch, `original` holds what was decoded and `expected` the hash
  it should have had; with any other error it is empty. }
function Unpack(const pra: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16; threads: Integer = 1): TPackResult;

implementation

const
  ERROR_NAMES: array[TPackError] of string = ('Ok', 'Format', 'NotRaster', 'Codec', 'TooLarge',
    'SizeMismatch', 'HashMismatch');

function TPackResult.Ok: Boolean;
begin Result := err = ukOk; end;

function TPackResult.Text: string;
begin
  Result := ERROR_NAMES[err];
  case err of
    ukFormat: Result := Result + '(' + fmt.Text + ')';
    ukNotRaster: Result := Result + '(' + why + ')';
    ukCodec: Result := Result + '(' + DecodeStatusName(dec) + ')';
  end;
end;

function PackFail(e: TPackError): TPackResult;
begin
  Result := Default(TPackResult);
  Result.err := e;
end;

function Pack(const original: TBytes; out pra: TBytes; const ext: string; threads: Integer): TPackResult;
var stream: TBytes; e, why: string;
begin
  e := ext;
  if not ValidExtension(e) then e := '';
  pra := nil;
  Result := PackFail(ukOk);
  if not EncodeFile(original, stream, why, threads) then begin
    Result.err := ukNotRaster; Result.why := why; Exit;
  end;
  Result.stored := Length(stream) >= Length(original);
  if Result.stored then
    Result.fmt := WritePra(original, Blake3_128(original), Length(original), pra, True, e)
  else
    Result.fmt := WritePra(stream, Blake3_128(original), Length(original), pra, False, e);
  if not Result.fmt.Ok then begin pra := nil; Result.err := ukFormat; end;
end;

function Unpack(const pra: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16; threads: Integer = 1): TPackResult;
var p: TPra; actual: THash16;
begin
  original := nil;
  FillChar(expected, SizeOf(expected), 0);
  Result := PackFail(ukOk);
  Result.fmt := Open(pra, p);
  if not Result.fmt.Ok then begin Result.err := ukFormat; Exit; end;
  expected := p.hash;
  Result.ext := p.ext;
  if p.orig_size > maxOutput then Exit(PackFail(ukTooLarge));
  if p.stored then original := p.payload
  else begin
    Result.dec := DecodeFile(p.payload, Int64(p.orig_size), original, threads);
    if Result.dec <> dsOk then begin original := nil; Result.err := ukCodec; Exit; end;
  end;
  if QWord(Length(original)) <> p.orig_size then begin original := nil; Exit(PackFail(ukSizeMismatch)); end;
  actual := Blake3_128(original);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then Result.err := ukHashMismatch;
end;

end.
