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

- `Detector` (`encoding.detect`): charset detection for unlabeled bytes, as Firefox's chardetng does. Feed it chunks, then call `guess` or `guesses` for a confidence-ranked answer among UTF-8, the CJK encodings, and the single-byte encodings legacy web pages used. It takes optional `Hints`: `tld`, `language`, and `allow_utf8`. It allocates nothing and keeps 864 bytes of state.

### Changed

- Big5 decodes about 10% faster.
- GBK and gb18030 decode to UTF-8 about 15% faster.
- Shift_JIS and EUC-JP decode about 7% faster.
- ISO-2022-JP decodes invalid input 3 to 4 times faster.
- The gb18030 and EUC-KR encode tables are 20.7 KB and 5.2 KB smaller in a program that encodes. GBK and gb18030 encode about 11% slower on traditional Chinese text; EUC-KR encodes as fast as before.
- The single-byte encodings, x-user-defined, UTF-16LE, and UTF-16BE decode and encode 16 bytes at a time: 1.4 to 14 times faster depending on direction, and no longer faster or slower with where the linker places them.

- Single-byte decoding (windows-125x, ISO-8859, KOI8, IBM866, macintosh, ...) is faster on x86-64 without AVX-512 and on aarch64: blocks of 16 bytes are looked up with `pshufb` (SSSE3, AVX2) or NEON `tbl`, chosen at compile time from the target CPU. Single-byte encoding is faster on every target.

### Fixed

- Decoding UTF-16LE or UTF-16BE with many unpaired surrogates is linear in the input: it was quadratic.
