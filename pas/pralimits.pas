{ The limits, in one place: the parsers apply them when reading a file, and
  the decoder applies the same ones before decoding anything. Why each one
  is what it is: doc/POLICY.md. }
unit pralimits;

{$I pra.inc}

interface

const
  { a side of an image, in pixels: 16,777,216 }
  MAX_DIMENSION = 1 shl 24;
  { samples per pixel (PAM's DEPTH) }
  MAX_CHANNELS = 256;
  { a text header (PNM, PAM, PFM): comments included }
  MAX_TEXT_HEADER = 1 shl 20;

implementation

end.
