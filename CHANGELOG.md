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
- `DecoderFor(encodings)` and `EncoderFor(encodings)`: a decoder or encoder for a set of encodings fixed at compile time, which links only those encodings' code and tables (a windows-1252 decoder adds about 3 KB of code and tables for a native AVX-512 build, 6 to 14 KB for aarch64 or an x86-64 build with `.dispatch = false`, and 21 to 26 KB for a generic x86-64 build that picks its SIMD kernels at run time, instead of about 220 KB). `Decoder` is now `DecoderFor(&implemented)` and `Encoder` `EncoderFor(&implemented)`, with the same calls. A set without `bom_encodings` takes `OptionsWithoutSniff`, which has no `.sniff`.

- `Detector` (`encoding.detect`): charset detection for unlabeled bytes, as Firefox's chardetng does. Feed it chunks, then call `guess` or `guesses` for a confidence-ranked answer among UTF-8, the CJK encodings, and the single-byte encodings legacy web pages used. It takes optional `Hints`: `tld`, `language`, and `allow_utf8`. It allocates nothing and keeps 864 bytes of state.
- `decodeToUtf8`, `decodeToUtf16`, `encodeFromUtf8`, and `encodeFromUtf16`: convert a whole buffer into one you own in a single call. Pass the decoder or encoder type first (`Decoder`, or a `DecoderFor` to link only its encodings). You get back `Decoded` or `Encoded`, which in fatal mode also carry the first error and its position, or `error.NoSpaceLeft`. A buffer of the type's `maxUtf8Len` (or `maxUtf16Len`, `maxLenFromUtf8`, `maxLenFromUtf16`) always fits.
- `DecodingReader(D)` and `EncodingWriter(E)`: a `std.Io.Reader` that decodes another reader's bytes to UTF-8, and a `std.Io.Writer` that encodes the UTF-8 written to it onto another writer, over buffers you give them. Call `end` to finish an `EncodingWriter`'s stream; it does not flush the underlying writer.
- The `dispatch` build option (`-Ddispatch`, or `.dispatch` in `b.dependency("encoding", ...)`), passed to baskingspot/utf: whether a build for a generic x86-64 CPU picks its SIMD kernels at run time. Unset, utf decides: on for an x86-64 level or the baseline, off for a native or named CPU. `false` makes such a build smaller (a windows-1252 decoder for x86-64-v3 14 KB instead of 21 KB) but runs only that level's kernels on every CPU.

### Changed

- Big5 decodes about 10% faster.
- GBK and gb18030 decode to UTF-8 about 15% faster.
- Shift_JIS and EUC-JP decode about 7% faster.
- ISO-2022-JP decodes invalid input 3 to 4 times faster.
- The gb18030 and EUC-KR encode tables are 20.7 KB and 5.2 KB smaller in a program that encodes. GBK and gb18030 encode about 11% slower on traditional Chinese text; EUC-KR encodes as fast as before.
- The single-byte encodings, x-user-defined, UTF-16LE, and UTF-16BE decode and encode 16 bytes at a time: 1.4 to 14 times faster depending on direction, and no longer faster or slower with where the linker places them.

- Single-byte decoding (windows-125x, ISO-8859, KOI8, IBM866, macintosh, ...) is faster on x86-64 without AVX-512 and on aarch64: blocks of 16 bytes are looked up with `pshufb` (SSSE3, AVX2) or NEON `tbl`, chosen at compile time from the target CPU. Single-byte encoding is faster on every target.
- Requires baskingspot/utf v0.2.1. The single-byte encodings and x-user-defined convert to and from UTF-8 with utf's converters, so a generic x86-64 build runs them with the CPU's best kernels too: on an AVX-512 CPU, a baseline build decodes single-byte text to UTF-8 about 1.5 times as fast as with the converters it had.

### Fixed

- Decoding UTF-16LE or UTF-16BE with many unpaired surrogates is linear in the input: it was quadratic.
