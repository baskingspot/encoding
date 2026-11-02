# Changelog

All notable changes to encoding are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Encoding`: every encoding in the Encoding Standard, plus `ibm437` and `ibm850`, with `forLabel` (the standard's label table), `name`, `outputEncoding`, `forBom`, and `isImplemented`.
- `Decoder`: streaming `decodeToUtf8` and `decodeToUtf16` into caller buffers, `.replacement` or `.fatal` errors, byte order mark handling (`.sniff`, `.remove`, `.keep`), and `maxUtf8Len` and `maxUtf16Len`.
- `Encoder`: streaming `encodeFromUtf8` and `encodeFromUtf16` into caller buffers, `.html` (numeric character references) or `.fatal` errors, and `maxLenFromUtf8` and `maxLenFromUtf16`.
- Decoders and encoders for UTF-8, UTF-16LE, UTF-16BE, replacement, x-user-defined, and the 28 single-byte encodings (IBM866, ISO-8859-2 to -16, KOI8-R, KOI8-U, macintosh, windows-874, windows-1250 to -1258, x-mac-cyrillic). EUC-KR, IBM437, and IBM850 are not implemented yet: `isImplemented` is false for them, and `Decoder.init` and `Encoder.init` panic.
- Shift_JIS, EUC-JP, and ISO-2022-JP decoders and encoders.
- GBK, gb18030, and Big5 decoders and encoders: `isImplemented` is true for `gbk`, `gb18030`, and `big5`.
