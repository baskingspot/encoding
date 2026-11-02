# Plan

encoding is the WHATWG Encoding Standard as a Zig package: decode legacy
text to UTF-8 or UTF-16 and encode it back, with no C, no allocation,
streaming, and encoding_rs's speed and table size or better. Plus the IBM
code pages ZIP filenames need, and charset detection for text with no label.
This file is the scope, the API, the order of work, the decisions to
measure, and who owns what. Update it when a decision lands.

## Scope: phase 1

- **Every encoding in the standard**, both directions where the standard
  defines an encoder:
  - Multi-byte: Shift_JIS, EUC-JP, ISO-2022-JP, GBK, gb18030 (with its
    four-byte ranges), Big5 (HKSCS as the standard defines it), EUC-KR.
  - Single-byte: IBM866, ISO-8859-2 through -16 as listed (including
    ISO-8859-8-I), KOI8-R, KOI8-U, macintosh, x-mac-cyrillic, windows-874,
    windows-1250 through -1258.
  - UTF-8, UTF-16LE, UTF-16BE, replacement, x-user-defined.
- **Labels**: the standard's label table (`"sjis"`, `"latin1"`,
  `"cp1252"`, ...) to an encoding, case- and whitespace-insensitive, and
  each encoding's canonical name.
- **BOM sniffing** and the standard's decode, UTF-8 decode, and "decode
  without BOM" entry points.
- **Error modes**: replacement (U+FFFD on decode, numeric character
  references on encode, as the standard's HTML mode does) and fatal (stop and
  report the position).
- **Outside the standard**, because real data needs them:
  - IBM code page 437, for ZIP filenames without the UTF-8 flag, and 850.
  - **Detection**: guess the encoding of unlabeled bytes, as Firefox's
    chardetng does: a confidence-ranked guess with an optional top-level
    domain and declared-language hint. It comes last in phase 1.

## Not in phase 1

- EBCDIC and the rest of Go's IBM and Mac code pages: add one when a user
  asks, from its published table.
- UTF-7, ISO-2022-KR and -CN, HZ, and other encodings the standard maps to
  replacement or omits: they are attack surface the web removed.
- Unicode normalization, case mapping, and collation: separate libraries.

## API

Modeled on encoding_rs's, in Zig's terms. Nothing allocates: callers own
every buffer.

- `Encoding`: one value per encoding, with `forLabel(label) ?Encoding`,
  `name()`, and `forBom(bytes)`.
- `Decoder` and `Encoder`: small structs holding the streaming state (a
  pending lead byte, ISO-2022-JP's mode). `decodeToUtf8(src, dst, last)` and
  `decodeToUtf16(src, dst, last)` return how much they read and wrote and
  whether they stopped for output space, input, or (in fatal mode) an error
  and its position. Encoders mirror them from UTF-8 and UTF-16.
- `maxUtf8Len(n)`, `maxUtf16Len(n)`, and the encoders' `maxLen(n)` say how
  big an output buffer a call needs, so a caller can size it once.
- One-call conveniences over a whole buffer into a caller's buffer, and a
  `std.Io.Reader`/`std.Io.Writer` adapter that transcodes a stream.
- `detect`: a `Detector` fed chunks, then asked for its guess.

## Dependencies

- `baskingspot/utf`: UTF-8 and UTF-16 validation and the ASCII and UTF-8
  paths should be utf's, not a second copy. Whether to depend on utf's
  module or share its `simd.zig` is decision 3.
- `testingx` for tests.

## Testing

- **The standard's indexes** (index-jis0208, index-jis0212, index-gb18030,
  index-gb18030-ranges, index-big5, index-euc-kr, index-iso-2022-jp-katakana,
  and the single-byte indexes), vendored from encoding.spec.whatwg.org with
  checksums. Generated tables are checked against them in full, both
  directions.
- **web-platform-tests**' encoding tests, vendored and run through a small
  harness, with a list of any that cannot pass and why.
- **encoding_rs** as a differential oracle, built in the dev shell, on
  random and adversarial bytes and on every chunk split of them, plus ICU
  and iconv as secondary oracles where they follow the standard.
- **Fuzzing** from each codec's first commit: decoders on arbitrary bytes
  (no crash, valid output, round-trip where the standard guarantees it),
  encoders on arbitrary Unicode, and streaming splits. Lua's `test/fuzz`
  harness is a model.
- **Detection** is scored against chardetng and uchardet on a labeled corpus
  of real pages and documents per encoding, by accuracy and by bytes needed.

## Benchmarks

Throughput in GB/s and per-call nanoseconds, decode and encode, per
encoding, on ASCII-heavy and script-heavy text at sizes from 16 bytes to
megabytes, against encoding_rs, ICU, glibc iconv, GNU libiconv, and Go's
x/text. Table size in `.rodata` and peak RSS are reported beside them. Use
utf's harness design: each arm a pinned server, rows timed back to back in
rotating order, paired ratios with 95% intervals, and identical buffer
placement for every arm.

## Order of work

Each wave fans out to orbs with disjoint file ownership; this file records
the owner of each file while a wave runs.

0. **Foundations.** `Encoding` and labels, the `Decoder`/`Encoder` interface
   and streaming contract, the index vendoring and table generator, the
   differential, fuzz, and benchmark harnesses, the corpus script. UTF-8 and
   UTF-16 through utf, and the single-byte encodings, which exercise the
   whole interface cheaply. One orb, before the rest.
1. **Japanese** (Shift_JIS, EUC-JP, ISO-2022-JP) and **Chinese** (GBK,
   gb18030, Big5) in parallel, then **Korean** (EUC-KR) and the IBM code
   pages.
2. **SIMD.** ASCII runs in every codec, then the per-encoding fast paths the
   benchmarks call for.
3. **Detection.**
4. **Stream adapters** and the conveniences, and a README with numbers.

Merge rule: every file has one owner while a wave runs. An orb that needs a
change in a file it does not own asks for it in its report; a private helper
in its own files is fine until the merge. Orbs push signed branches rebased on
`origin/main` and report to the orchestrating thread, which reruns the gates,
brings the branch onto main without merge commits, pushes, and deletes the
branch.

### Owners

Wave 0, running as one orb (branch `wave0-foundations`): every file in the
repository except this Owners section, which the orchestrating thread keeps.
Wave 0 also proposes the wave 1 split, so that adding an encoding touches its
own files plus at most one line in each shared registry.

## Decisions to measure

1. **Table layout.** encoding_rs compresses its CJK tables (ranges and
   deltas instead of flat arrays) and pays a little lookup speed for it.
   Measure flat, ranged, and two-level layouts on decode and encode speed and
   on `.rodata` size before settling.
2. **Encoder lookups.** Encoding to a CJK encoding needs a reverse map from
   code point to bytes: a search over the decode table, a generated
   perfect hash, or a ranged reverse table. Same two-sided measurement.
3. **Sharing with utf.** Depend on utf's module for UTF-8/UTF-16 work and
   its SIMD helpers, or vendor `simd.zig`. Depending is the default, if utf's
   API and release cadence allow it.
4. **UTF-16 output.** Whether `decodeToUtf16` gets SIMD paths of its own or
   goes through UTF-8, judged by how often callers on Windows and JavaScript
   hosts would use it.
5. **Detection's model.** chardetng's approach (byte-pair scores per
   encoding and language, from a training corpus) against simpler
   frequency models, on accuracy, bytes needed, and table size.
