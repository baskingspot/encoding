# encoding

Legacy text encodings in Zig with no C: the WHATWG Encoding Standard's Shift_JIS, GBK, Big5, EUC-KR, windows-125x, and the rest.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

## Use

```zig
const encoding = @import("encoding");

const enc = encoding.Encoding.forLabel("latin1") orelse return error.UnknownLabel;
var decoder: encoding.Decoder = .init(enc, .{});
var out: [4096]u8 = undefined;
const r = decoder.decodeToUtf8(bytes, &out, true);
// r.read bytes of input became out[0..r.written]; r.status says why it stopped.
```

Nothing allocates: decoders and encoders write into buffers you own, in as many calls as the input takes, and `maxUtf8Len`, `maxUtf16Len`, `maxLenFromUtf8`, and `maxLenFromUtf16` say how big a buffer a call needs. Errors are replaced (U+FFFD when decoding, numeric character references when encoding) or, in fatal mode, reported with their position.

This version implements UTF-8, UTF-16LE and BE, replacement, x-user-defined, and every single-byte encoding in the standard; the CJK encodings, IBM437, and IBM850 come next. `Encoding.isImplemented` tells which.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs: the tests in Debug and ReleaseSafe and on big-endian s390x, the table checks against the standard's indexes, a differential against encoding_rs, the web-platform-tests encoding tests, and a bounded fuzz run. `just fuzz` fuzzes longer, and `just bench-compare` benchmarks against encoding_rs, ICU, iconv, and Go (`bench/README.md`).

## License

MIT. See `LICENSE`.
