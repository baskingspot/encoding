# Changelog

All notable changes to encoding are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Encoding`: every encoding in the Encoding Standard, plus `ibm437` and `ibm850`, with `forLabel` (the standard's label table), `name`, `outputEncoding`, `forBom`, and `isImplemented`.
- `Decoder`: streaming `decodeToUtf8` and `decodeToUtf16` into caller buffers, `.replacement` or `.fatal` errors, byte order mark handling (`.sniff`, `.remove`, `.keep`), and `maxUtf8Len` and `maxUtf16Len`.
- `Encoder`: streaming `encodeFromUtf8` and `encodeFromUtf16` into caller buffers, `.html` (numeric character references) or `.fatal` errors, and `maxLenFromUtf8` and `maxLenFromUtf16`.
- Decoders and encoders for UTF-8, UTF-16LE, UTF-16BE, replacement, x-user-defined, and the 28 single-byte encodings (IBM866, ISO-8859-2 to -16, KOI8-R, KOI8-U, macintosh, windows-874, windows-1250 to -1258, x-mac-cyrillic).
- Shift_JIS, EUC-JP, and ISO-2022-JP decoders and encoders.
- GBK, gb18030, and Big5 decoders and encoders.
- EUC-KR decoder and encoder.
- IBM437 and IBM850 decoders and encoders, from Unicode's mappings of the IBM code pages. They have no labels, so `Encoding.forLabel` never returns them; name them as `.ibm437` and `.ibm850`.
- `DecoderFor(encodings)` and `EncoderFor(encodings)`: a decoder or encoder for a set of encodings fixed at compile time, which links only those encodings' code and tables (a windows-1252 decoder adds about 1 KB instead of about 210 KB). `Decoder` is now `DecoderFor(&implemented)` and `Encoder` `EncoderFor(&implemented)`, with the same calls. A set without `bom_encodings` takes `OptionsWithoutSniff`, which has no `.sniff`.
