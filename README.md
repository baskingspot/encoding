# encoding

Legacy text encodings in Zig with no C: the WHATWG Encoding Standard's Shift_JIS, GBK, Big5, EUC-KR, windows-125x, and the rest.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

encoding decodes legacy text to UTF-8 or UTF-16 and encodes it back, for every encoding in the [Encoding Standard](https://encoding.spec.whatwg.org/), the one browsers implement. It does the job Rust's [encoding_rs](https://github.com/hsivonen/encoding_rs) and Go's [golang.org/x/text/encoding](https://pkg.go.dev/golang.org/x/text/encoding) do, as a Zig package:

- Decoders and encoders that stream: they take input in as many pieces as it comes, write into buffers you own, and never allocate.
- `DecoderFor` and `EncoderFor`, specialized at compile time to the encodings you name, so a program links only their code and tables.
- `Detector`, a charset detector for bytes with no label, in the manner of Firefox's chardetng.
- The standard's label table (`"sjis"`, `"latin1"`, `"cp1252"`, ...), byte order mark sniffing, and its two error modes: replace (U+FFFD when decoding, `&#NNNN;` when encoding) or stop and report.

## Encodings

| Family               | Encodings                                                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Unicode              | UTF-8, UTF-16LE, UTF-16BE                                                                                                                              |
| Japanese             | Shift_JIS, EUC-JP, ISO-2022-JP                                                                                                                         |
| Chinese              | GBK, gb18030 (with its four-byte ranges), Big5 (with the HKSCS extensions the standard includes)                                                       |
| Korean               | EUC-KR                                                                                                                                                 |
| Single-byte          | IBM866, ISO-8859-2 to -8, ISO-8859-8-I, ISO-8859-10, -13, -14, -15, -16, KOI8-R, KOI8-U, macintosh, windows-874, windows-1250 to -1258, x-mac-cyrillic |
| Special              | replacement, x-user-defined                                                                                                                            |
| Outside the standard | IBM437 and IBM850, from Unicode's mappings of the IBM code pages, for ZIP file names and DOS text                                                      |

Every one decodes. The standard defines no encoder for UTF-16LE, UTF-16BE, or replacement: an `Encoder` for them writes UTF-8, as the standard says. IBM437 and IBM850 have no labels; name them as `.ibm437` and `.ibm850`.

Not here: UTF-7, ISO-2022-KR, ISO-2022-CN, HZ, and the other encodings the standard maps to replacement or leaves out; EBCDIC and the rest of the IBM and Mac code pages; normalization, case mapping, and collation.

## Install

There are no releases yet. Fetch the main branch:

```sh
zig fetch --save git+https://github.com/baskingspot/encoding
```

Add the module in `build.zig`:

```zig
const encoding = b.dependency("encoding", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("encoding", encoding.module("encoding"));
```

It builds with Zig 0.16 and depends on [baskingspot/utf](https://github.com/baskingspot/utf) for UTF-8 and UTF-16.

## Use

### Decode

```zig
const encoding = @import("encoding");

const enc = encoding.Encoding.forLabel("shift_jis") orelse return error.UnknownLabel;
var decoder: encoding.Decoder = .init(enc, .{});
var out: [4096]u8 = undefined;
var rest: []const u8 = input;
while (true) {
    const r = decoder.decodeToUtf8(rest, &out, true);
    try writer.writeAll(out[0..r.written]);
    rest = rest[r.read..];
    if (r.status == .input_empty) break; // else .output_full: go round again
}
```

Each call reads what it can of the input, writes what fits, and says why it stopped. For input that arrives in pieces, pass each piece with `last` false and the final one with `last` true; a character cut between two pieces comes out whole, and any split gives the same output as one call. `decodeToUtf16` writes UTF-16 instead. `decoder.maxUtf8Len(n)` and `maxUtf16Len(n)` give a buffer size that always takes `n` bytes in one call.

`Decoder.Options` picks the error mode, `.replacement` (U+FFFD for each malformed sequence) or `.fatal` (stop with `.malformed` and its position), and what to do with a byte order mark: `.sniff`, the default, is the standard's "decode", where a UTF-8 or UTF-16 mark overrides the label; `.remove` strips only the encoding's own mark, as `TextDecoder` does; `.keep` decodes it like any other bytes.

### Decode one encoding

`Decoder` can decode any encoding, chosen at run time, so it links every encoding's tables. When the encodings are known at compile time, `DecoderFor` links only theirs:

```zig
const Windows1252 = encoding.DecoderFor(&.{.windows_1252});
var decoder: Windows1252 = .init(.windows_1252, .{ .bom = .remove });
```

It has the same calls and results as `Decoder`, which is `DecoderFor(&encoding.implemented)`. A set without UTF-8, UTF-16BE, and UTF-16LE (`encoding.bom_encodings`) cannot sniff, so its options name `.remove` or `.keep`. `EncoderFor` does the same for encoders.

### Encode

```zig
var encoder: encoding.Encoder = .init(.shift_jis, .{});
const buf = try gpa.alloc(u8, encoder.maxLenFromUtf8(text.len).?);
defer gpa.free(buf);
const r = encoder.encodeFromUtf8(text, buf, true);
// buf[0..r.written] is Shift_JIS, with &#NNNN; for each character it lacks.
```

`encodeFromUtf16` reads UTF-16. Ill-formed input reads as U+FFFD, as the standard's decoders do. With `.mode = .fatal` the encoder stops at a character the encoding lacks, with status `.unmappable` and the character in `r.unmappable`, and can go on from there.

### Detect

```zig
var detector: encoding.Detector = .init();
detector.feed(bytes); // as many times as the input takes
const guess = detector.guess(.{ .tld = "jp" });
var decoder: encoding.Decoder = .init(guess.encoding, .{});
```

The guess is one of the encodings unlabeled web content used: UTF-8, Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, Big5, GBK, windows-874, windows-1250 to -1258, ISO-8859-2, -4, -5, -6, -7, -8, and -13, KOI8-U, and IBM866, with a confidence from 0 to 1; `guesses` ranks them all. The hints, a top-level domain or a declared language (`.language = "ru"`), settle short or ambiguous input, and `.allow_utf8 = false` keeps UTF-8 out. UTF-16 is found by its byte order mark, with `Encoding.forBom`, before detection. The detector keeps 864 bytes of state and none of the input.

### Convert a whole buffer, or a stream

```zig
// A whole buffer in one call. The first argument is the decoder type:
// `Decoder` takes any encoding, `DecoderFor(&.{.shift_jis})` links only Shift_JIS.
const r = try encoding.decodeToUtf8(encoding.Decoder, enc, bytes, &out, .{});
// r.text is the UTF-8; r.encoding the encoding decoded, which a byte order mark can change.

// Streams: decode what a reader reads...
var dr: encoding.DecodingReader(encoding.Decoder) = .init(in, .init(enc, .{}), &.{});
_ = try dr.interface.streamRemaining(out_writer);

// ...or encode what you write.
var ew: encoding.EncodingWriter(encoding.Encoder) = .init(out_writer, .init(.shift_jis, .{}), &buf);
try ew.interface.print("{s}\n", .{text});
try ew.end();
try out_writer.flush();
```

`decodeToUtf8`, `decodeToUtf16`, `encodeFromUtf8`, and `encodeFromUtf16` convert all of their input or fail with `error.NoSpaceLeft`; a buffer of the type's `maxUtf8Len` (or `maxUtf16Len`, `maxLenFromUtf8`, `maxLenFromUtf16`) always fits. In fatal mode the result also carries the first error and where it is in the input, in `malformed` or `unmappable`. They cost the same as calling a decoder or encoder yourself.

`DecodingReader` is a `std.Io.Reader` of UTF-8 over another reader's bytes, and `EncodingWriter` a `std.Io.Writer` that encodes the UTF-8 written to it onto another writer. Both work over buffers you give them, of any size. A fatal error ends a read or write with `ReadFailed` or `WriteFailed`, and its position from the start of the stream is in `malformed` or `unmappable`. `end` finishes an `EncodingWriter`'s stream (a cut-off character, ISO-2022-JP's return to ASCII) but does not flush the writer under it.

## Correctness

The Encoding Standard is the specification, word for word: its decoder and encoder algorithms, its error handling, its label table, and its byte order mark rules. The tables are generated from the standard's own index files, vendored unmodified, and the tests check every entry of every index in both directions.

- **web-platform-tests.** The browsers' encoding tests run against the package built as WebAssembly, behind a small `TextDecoder` and `TextEncoder` shim. 1,139,861 subtests pass. One fails, where the test expects a fatal streaming error to drop the unread input and the standard keeps it. Twelve files are skipped: five need a browser or a server, and seven are reftests or manual pages.
- **encoding_rs, differentially.** Every decoder and encoder is compared with encoding_rs on random input and on exhaustive sets: every byte on both sides of the 16- and 64-byte SIMD blocks, every two-byte sequence, and every three- and four-byte sequence of the bytes that start, continue, and end multi-byte characters, in one call and a byte at a time, both error modes and every byte order mark option. They agree on all of it, fatal errors' positions included, and on every label.
- **Fuzzing.** Every codec and the detector are fuzzed for crashes, safety checks, hangs, ill-formed output, and any split of the input or size of buffer that changes the output. Decoders read untrusted bytes, so they keep Zig's safety checks on in safe builds.
- **Big-endian and aarch64.** The tests run on s390x and aarch64 under qemu, so the byte-order paths and the NEON code are tested; their speed is not measured.

## Performance

Measured on one machine: an Intel Xeon (Ice Lake server) at 2.60 GHz, a 4-vCPU cloud VM with AVX-512, Linux 6.1, Zig 0.16. The host is shared, so read the ratios rather than the absolute speeds. Each arm runs as a server pinned to one core, every arm times a row back to back in an order that rotates, and a row's ratio is the median of ten paired rounds; `bench/README.md` has the method. Above 1x, this package is faster.

### Against encoding_rs

encoding_rs 0.8.44, built for Rust's default x86-64 target with its own SSE2 code; this package built for the host CPU. Inputs of 4 KiB to 1 MiB: the geometric mean of each family's encodings and inputs, in GB/s of input and as a multiple of encoding_rs's speed. Single-byte is the standard's 28 single-byte encodings.

Realistic text, web pages, mail, subtitles, and CSV, written from Wikipedia articles in each encoding's language:

| Family                | Decode to UTF-8 | Decode to UTF-16 | Encode from UTF-8 | Encode from UTF-16 |
| --------------------- | --------------: | ---------------: | ----------------: | -----------------: |
| UTF-8                 |    13.74, 1.36x |      4.51, 4.57x |      14.12, 0.23x |        9.91, 9.72x |
| UTF-16LE and UTF-16BE |     6.80, 6.01x |    37.54, 14.42x |                   |                    |
| Single-byte (the 28)  |     3.51, 3.64x |      7.66, 5.19x |       1.89, 3.67x |        7.20, 5.84x |
| Japanese              |     0.65, 1.72x |      1.09, 2.24x |      0.54, 13.69x |       0.63, 18.20x |
| Chinese               |     0.69, 1.84x |      0.97, 1.84x |      0.57, 38.97x |       0.72, 54.44x |
| Korean                |     0.71, 1.14x |      0.83, 1.36x |       0.51, 5.00x |        0.90, 8.05x |

Synthetic text: English ASCII only, the language's non-ASCII characters only, the two alternating, and random bytes:

| Family                | Decode to UTF-8 | Decode to UTF-16 | Encode from UTF-8 | Encode from UTF-16 |
| --------------------- | --------------: | ---------------: | ----------------: | -----------------: |
| UTF-8                 |     6.30, 1.26x |      3.46, 3.17x |      15.83, 0.32x |       14.21, 9.65x |
| UTF-16LE and UTF-16BE |     7.35, 4.93x |     18.45, 7.61x |                   |                    |
| Single-byte (the 28)  |     5.51, 6.97x |      8.08, 6.56x |       2.02, 4.84x |        4.65, 6.54x |
| Japanese              |     1.27, 2.41x |      1.54, 2.66x |       0.99, 7.08x |        1.21, 8.51x |
| Chinese               |     1.28, 1.99x |      1.34, 1.90x |      1.14, 15.74x |       1.25, 16.58x |
| Korean                |     1.34, 1.46x |      1.41, 1.64x |       1.05, 3.54x |        1.48, 4.79x |

UTF-16 has no encoder in the standard. Encoding UTF-8 to UTF-8 is a copy for encoding_rs, whose input is a Rust `&str` and already valid; this package validates it.

Calls on 16 bytes, which measure the cost of starting a call, median nanoseconds over the family's encodings and shapes, this package / encoding_rs:

| Family                | Decode to UTF-8 | Decode to UTF-16 | Encode from UTF-8 | Encode from UTF-16 |
| --------------------- | --------------: | ---------------: | ----------------: | -----------------: |
| UTF-8                 |     19.0 / 15.6 |      20.5 / 18.1 |        11.9 / 9.2 |        12.8 / 15.3 |
| UTF-16LE and UTF-16BE |     14.9 / 16.8 |      13.1 / 19.3 |                   |                    |
| Single-byte (the 28)  |      9.9 / 13.8 |      10.2 / 13.7 |        9.0 / 14.9 |        10.2 / 15.8 |
| Japanese              |     29.3 / 34.0 |      27.5 / 30.2 |       22.1 / 28.2 |        22.3 / 29.5 |
| Chinese               |      9.6 / 14.5 |      10.8 / 14.6 |        8.5 / 12.7 |         9.1 / 13.8 |
| Korean                |      9.2 / 14.1 |      10.2 / 14.5 |        8.6 / 13.2 |         9.5 / 14.1 |

Over every row encoding_rs has, 6,688 of them (each encoding, operation, shape, and size from 16 bytes to 1 MiB), this package is 3.55x encoding_rs's speed, geometric mean: 3.03x decoding and 4.19x encoding. 123 rows are slower beyond their 95% interval, 44 of them UTF-8 to UTF-8.

Where encoding_rs is faster:

- Encoding UTF-8 as UTF-8, 0.11 to 0.79x, for the reason above.
- UTF-8 decode on 16 bytes (0.67 to 0.93x; 19 ns against 16 to UTF-8), on a few ASCII rows up to 4 KiB (0.85 to 0.97x), and of random bytes to UTF-16 (0.78 to 0.95x).
- Shift_JIS and Big5 decode of Japanese and Chinese text up to 4 KiB: 0.75 to 0.96x on 27 rows, though mostly 1.1 to 2.5x from 64 KiB up.
- Single-byte decode to UTF-8 of Latin text with few accented letters at 64 to 256 bytes, and of macintosh at 4 to 64 KiB: 0.79 to 0.97x on 16 rows.
- UTF-16 decode of random bytes (0.58 to 0.98x) and of some 16-byte inputs (0.87 to 0.94x), and x-user-defined encode at 16 bytes (0.67 to 0.85x).
- Size: see below.

### Against ICU, iconv, and Go

ICU 78, glibc's iconv, GNU libiconv, and Go's golang.org/x/text, each on the rows where its output matches the standard's (their tables and error handling differ in places, so 3 to 8% of each one's rows are left out):

| Direction |                        ICU |               glibc iconv |              GNU libiconv |                 Go x/text |
| --------- | -------------------------: | ------------------------: | ------------------------: | ------------------------: |
| Decode    |  5.38x (20 of 3,302 below) | 11.89x (6 of 3,214 below) | 17.36x (1 of 3,124 below) |  6.62x (5 of 1,680 below) |
| Encode    | 5.01x (272 of 3,160 below) | 8.89x (14 of 3,186 below) |  9.46x (7 of 3,092 below) | 6.47x (12 of 1,576 below) |

Each cell is the geometric mean of this package's speed over the other's across every row both have, with the rows where the other is faster beyond the interval. ICU is the one that wins rows: it encodes non-ASCII-heavy text into the single-byte encodings whose letters lie scattered through the table (ISO-8859-2, windows-1250, KOI8-R, and the like) up to 1.7 times as fast, with a reverse table this package does without, and it is up to 1.6 times as fast on some GBK, Shift_JIS, and EUC-KR rows of non-ASCII-heavy text. Go's x/text has no UTF-16 operations. A call on 16 bytes costs about 10 ns here, median over every row, against 36 to 97 ns in ICU, 85 to 122 ns in either iconv, and 36 ns in x/text.

### Other CPUs

Everything above is this package built for the host CPU, which has AVX-512, against encoding_rs built for SSE2. Built for x86-64-v3 (AVX2) or baseline x86-64 (SSE2) and run on the same machine, on every row of 64 KiB and of 16 bytes, the geometric mean of the ratio to encoding_rs:

| Family and direction | Host, 64 KiB | x86-64-v3 | Baseline | Host, 16 bytes | x86-64-v3 | Baseline |
| -------------------- | -----------: | --------: | -------: | -------------: | --------: | -------: |
| UTF-8 decode         |        2.33x |     2.38x |    2.35x |          1.35x |     1.28x |    1.19x |
| UTF-16 decode        |        6.82x |     7.14x |    5.76x |          1.45x |     1.48x |    1.41x |
| Single-byte decode   |        7.60x |     5.51x |    3.24x |          1.90x |     1.55x |    1.40x |
| Single-byte encode   |        7.11x |     5.49x |    3.99x |          2.27x |     1.98x |    1.80x |
| Japanese decode      |        2.71x |     2.86x |    2.85x |          1.31x |     1.32x |    1.34x |
| Japanese encode      |       10.03x |     9.87x |    7.87x |          2.86x |     2.82x |    2.63x |
| Chinese decode       |        2.20x |     2.21x |    2.08x |          1.41x |     1.39x |    1.26x |
| Chinese encode       |       24.25x |    23.54x |   19.25x |          4.55x |     4.50x |    4.12x |
| Korean decode        |        1.52x |     1.49x |    1.52x |          1.45x |     1.40x |    1.31x |
| Korean encode        |        4.87x |     4.69x |    3.98x |          2.56x |     2.48x |    2.34x |
| Every row            |        6.69x |     5.39x |    3.81x |          2.05x |     1.80x |    1.65x |

(UTF-8 to UTF-8 is left out. The three builds were timed in one run of their own, so the host columns differ a little from the tables above.) Every conversion between UTF-8 and UTF-16, the single-byte encodings' included, goes through baskingspot/utf, which on a generic build picks its AVX-512 kernels at run time, so those keep their speed. The single-byte loops lose the most, in their own table lookups: at baseline, without SSSE3's byte shuffle, Latin text with the odd accented letter decodes to UTF-8 at 0.72 to 1.00x encoding_rs's speed at 64 KiB in macintosh, windows-1252, and ISO-8859-3, -14, and -15. Built for x86-64-v3, no single-byte decode row of 64 KiB is below encoding_rs.

### Size

Every encoding's tables take 307,099 bytes in a program that links them all, against encoding_rs's 124,497: 2.5 times as much. Nearly all of it is the Chinese, Japanese, and Korean indexes. Their decode tables are flat or paged arrays, faster to read than encoding_rs's compressed ranges, and their encode tables are a ranked bitmap per block of code points, where encoding_rs searches its decode tables; that is where encoding 3.5 to 54 times as fast comes from. A program that never encodes links no encode table.

What a small program that converts stdin links, in ReleaseSmall, net of one that only copies stdin to stdout, in bytes of `.rodata` + `.text`:

| Program                          | x86-64 with AVX-512 |        x86-64-v3 | x86-64-v3, no dispatch |  x86-64 baseline | baseline, no dispatch |          aarch64 |
| -------------------------------- | ------------------: | ---------------: | ---------------------: | ---------------: | --------------------: | ---------------: |
| `Decoder`, any encoding by label |    185,626 + 35,525 | 251,749 + 50,408 |       221,334 + 35,906 | 274,703 + 74,623 |      184,384 + 32,917 | 220,688 + 34,404 |
| `Encoder`, any encoding by label |    167,160 + 18,744 | 200,344 + 27,558 |       170,028 + 20,494 | 205,804 + 43,223 |      166,016 + 22,050 | 169,760 + 21,528 |
| `DecoderFor(&.{.windows_1252})`  |         369 + 2,688 |   39,738 + 7,439 |          9,448 + 3,717 |  49,446 + 12,918 |           544 + 5,974 |    9,280 + 3,508 |
| `EncoderFor(&.{.windows_1252})`  |         999 + 5,307 |  34,800 + 10,746 |          4,488 + 5,817 |  40,132 + 18,211 |           528 + 8,475 |    4,432 + 6,720 |
| `DecoderFor(&.{.shift_jis})`     |      16,530 + 3,298 |   16,552 + 3,304 |         16,552 + 3,304 |   16,528 + 3,255 |        16,528 + 3,255 |   16,528 + 3,308 |
| `DecoderFor(&.{.gb18030})`       |      48,762 + 4,892 |   48,784 + 4,900 |         48,784 + 4,900 |   48,752 + 4,823 |        48,752 + 4,823 |   48,768 + 4,832 |
| `DecoderFor(&.{.euc_kr})`        |      47,562 + 2,659 |   47,560 + 2,666 |         47,560 + 2,666 |   47,552 + 2,645 |        47,552 + 2,645 |   47,552 + 2,920 |

Every conversion between UTF-8 and UTF-16, the single-byte encodings' included, is baskingspot/utf's. Built for a generic x86-64 CPU, an x86-64 level or the baseline, utf picks its SIMD kernels at run time and links them for every level above the target's: that is most of what the x86-64-v3 and baseline columns add over the native one, much of it constant tables the linker keeps whole. Build with `.dispatch = false` (`b.dependency("encoding", .{ .dispatch = false })`, or `-Ddispatch=false`) to link only the target's own kernels: a one-encoding windows-1252 decoder is then 6 to 13 KB, but a baseline binary runs SSE2 code on every CPU. A native or named CPU never dispatches. encoding_rs has no build for fewer encodings: a program that uses it links all of its tables.

### Detection

Against chardetng 0.1.17, Firefox's detector, and uchardet 0.0.8, on 60,810 windows of 16 to 4096 bytes and 1,870 whole articles in 25 encodings and 56 languages, from Wikipedia articles held out from training. Every arm guesses each sample with a fresh detector and no hints. Accuracy is the share of samples whose guess decodes them to the right text, averaged over the encodings; speed is pinned to one core, the median of five runs.

| Detector     | 16 bytes | 32 bytes | 64 bytes | 128 bytes | whole articles |  Tables | Speed, whole articles | A 32-byte call |
| ------------ | -------: | -------: | -------: | --------: | -------------: | ------: | --------------------: | -------------: |
| this package |    92.0% |    95.3% |    97.4% |     98.7% |          99.7% | 32.3 KB |             61.5 MB/s |         5.6 µs |
| chardetng    |    88.9% |    93.0% |    94.2% |     95.9% |          98.6% | 29.3 KB |              9.9 MB/s |         6.6 µs |
| uchardet     |    81.1% |    91.4% |    93.6% |     94.2% |          92.5% |  136 KB |              5.1 MB/s |        11.1 µs |

Half of each encoding's articles are guessed right, and stay right, from the first 16 bytes. chardetng is still ahead on short windows-1252 (96% to 91% at 16 bytes), on short Central European text (windows-1250 and ISO-8859-2: about 89% to 75% at 16 bytes, level from 256), on ISO-8859-4 at 16 bytes (67% to 59%), and on long Greek in ISO-8859-7, which this package reads as windows-1253 (100% to 95% on whole articles; the two differ in a few letters such as Ά). Elsewhere it is ahead or level, but for a point in a few cells, and furthest ahead on the Baltic encodings, Turkish, Hebrew, and Arabic. The test text is encyclopedic prose; real pages add markup, which reads as ASCII to every candidate alike.

### Not measured

- Speed on aarch64. The NEON paths are tested under qemu, not timed; on aarch64 only the sizes above are measured.
- Other x86-64 machines, AMD's included, other operating systems, and dedicated hardware: every number here is from one shared VM.
- Big-endian speed (s390x is tested under qemu only).
- Peak memory: a program converting the benchmark corpus peaks at 32 MiB with this package and 29 to 38 MiB with the others, nearly all of it the inputs, so it tells little apart.

## Work on it

`nix develop` provides the toolchain, and `just` lists the recipes. `just ci` runs what CI runs: the tests in Debug and ReleaseSafe and on big-endian s390x and aarch64 under qemu, the table checks against the standard's indexes, lint, a differential against encoding_rs, the web-platform-tests encoding tests, and a bounded fuzz run. `just fuzz` fuzzes longer.

`just bench-compare` benchmarks against encoding_rs, ICU, glibc iconv, GNU libiconv, and Go's x/text; [`bench/README.md`](bench/README.md) describes the arms, the corpus, and the method. `just detect-score` scores the detector against chardetng and uchardet; [`test/detect/README.md`](test/detect/README.md) describes its corpus and trainer. Third-party material and its licenses are in [`THIRD_PARTY.md`](THIRD_PARTY.md), and changes in [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT. See [`LICENSE`](LICENSE).
