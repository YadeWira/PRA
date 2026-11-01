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

  { the smallest codec stream: version, the header's length (and no
    header), the layout, the tail's length and the arithmetic coder's 4
    closing bytes }
  MIN_PAYLOAD = 13;

  { How many times its payload a declared original size may be: so that a
    tiny file cannot declare a huge output before anything is decoded. The
    coder's probabilities stop at 1/4096, so a decision costs at least
    0.00035 bits: a blank 8-bit image compresses about 6,000:1 at most, a
    blank PBM about 23,000:1 (one decision a pixel). 65536 leaves room
    above both, and the user's --max-output still applies. }
  MAX_EXPANSION_RATIO = 65536;

implementation

end.
