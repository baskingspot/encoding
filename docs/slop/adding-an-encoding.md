# Adding an encoding

How a codec joins the package: the files it owns, the one line it adds to
each shared registry, and what checks it before it lands. Wave 0 built the
registries so that a wave 1 orb (Japanese, Chinese, Korean, IBM) touches its
own files plus at most one line per registry. If a change needs more than
that, the registry is wrong: say so in the report rather than working
around it.

## What already exists

Every encoding in phase 1 is already a tag of `Encoding`
(`src/encoding.zig`): the standard's, from
`vendor/whatwg-encoding/encodings.json`, plus `ibm437` and `ibm850`, which
have no labels. The label table (`src/tables/labels.zig`, generated) maps
every label in the standard. `Encoding.isImplemented()` is false for an
encoding no family decodes yet, and `Decoder.init` and `Encoder.init` panic
on one. Nothing about an encoding's identity, labels, or name changes when
its codec lands.

The corpus (`bench/encodings.tsv`, `bench/corpus/`), the benchmark arms, and
the encoding_rs oracle already cover every phase-1 encoding: they skip the
ones the package does not implement and start timing or comparing them the
moment it does.

## The files a family owns

- `src/<family>.zig`: the codec. A family implements one or more encodings
  with shared code, as `single_byte.zig` does for 28. GBK and gb18030 are
  one family; Shift_JIS, EUC-JP, and ISO-2022-JP may be one or three. The
  interface, from the comment at the top of `src/codecs.zig`:

  ```zig
  pub const encodings = [_]Encoding{ ... };   // the ones it decodes
  pub const Decoder = struct {
      pub fn init(e: Encoding) Decoder;
      pub fn decode(d: *Decoder, comptime Unit: type, src: []const u8,
          dst: []Unit, last: bool, mode: DecoderMode) DecodeResult;
      pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize;
  };
  pub const Encoder = struct {                // unless it has none
      pub fn init(e: Encoding) Encoder;
      pub fn encode(e: *Encoder, comptime Unit: type, src: []const Unit,
          dst: []u8, last: bool, mode: EncoderMode) EncodeResult;
      pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize,
          mode: EncoderMode) ?usize;
  };
  ```

  A family that implements several encodings and tells them apart at run
  time may also declare `decodeAs` and `encodeAs`: `decode` and `encode`
  with the encoding a `comptime` parameter, so that a `DecoderFor` or
  `EncoderFor` over one of its encodings links only that encoding's code
  and tables (`src/coder.zig`, docs/slop/comptime.md). Its `decode` then
  switches on its state with `inline else` into `decodeAs`.

  `Unit` is `u8` (UTF-8) or `u16` (UTF-16 in the machine's byte order).
  `src/codec.zig` has the shared pieces: the result types; `tryPut` and
  `putNcr` for output; `read` for encoder input, a plain `u32` code point
  and length (ill-formed input reads as U+FFFD; `first` is 2 or 3, the
  UTF-8 length tested first), and `readScalar`, its `Scalar` form for
  cold paths; and `asciiRun`, `asciiRunOut`, `asciiPrefixBlocks`,
  `copyAscii`, `narrowAscii`, and `highBits` (big-endian safe) for ASCII
  runs. In a hot loop, never merge two paths into an optional or a struct
  holding a `u21`: LLVM passes it through memory on every character.
  Return early, or use a `u32` with 0 for none.

- `src/tables/<index>.zig`: generated from `vendor/whatwg-encoding/` by
  `just gen`, never edited. Committed, so a consumer's build runs no
  generator; `just check` fails when a table differs from what the
  generator writes.
- `gen/layouts/<layout>.zig`: a table layout, if the family adds one for
  plan decisions 1 and 2. Every layout emits the same interface
  (`decode(pointer) u32`, 0 for none, and `encode(cp) ?u16`), so a codec
  never changes when its table's layout does. Callers test `cp != 0`.
- Unit tests inside the family file, for the standard's edge cases the
  shared harnesses cannot name: the decoder's error recovery (which bytes
  are re-read after an error), ISO-2022-JP's states, gb18030's four-byte
  ranges, Big5's two-code-point pointers.
- `docs/slop/results/<topic>-<yyyymmdd>.md` for each measurement.

## The decoder contract

The harnesses check all of this on every implemented encoding, so a family
that breaks it fails `just test`, `just fuzz`, and `just oracle` without a
line of new test code:

- **The standard's algorithm, word for word.** The decoder is the
  standard's decoder; an error in replacement mode writes U+FFFD and goes
  on, and in fatal mode returns `malformed` with `read` just past the
  malformed sequence (bytes the standard prepends back to the stream are
  not read) and `written` the output before it. The oracle compares both
  offsets with encoding_rs.
- **Streaming.** `last = false` means more input may follow: a family keeps
  a partial sequence in its `Decoder` and finishes it on the next call. Any
  split of the input into calls, and any output buffer size from one
  character up, gives the same output as one call (`test/props.zig`).
- **Output space.** A call stops with `output_full` only when the next
  character does not fit, leaving `read` at its first byte; it never writes
  part of a character. `maxLen(n)` bounds the output of `n` more bytes in
  any split, including what the family holds from earlier calls; with that
  much room a call takes all its input.
- **Untrusted input.** Any bytes: no crash, no out-of-bounds access, no
  infinite loop, well-formed UTF-8 or UTF-16 out. No
  `@setRuntimeSafety(false)`. Safety checks stay on in ReleaseSafe and the
  fuzz build.

The encoder contract mirrors it: `unmappable` in fatal mode with
`unmappable` the code point and `read` past it; a numeric character
reference in html mode; ISO-2022-JP's closing escape on the call with
`last`. `Encoder` holds a character split across calls (UTF-8 bytes or a
lead surrogate) before the family sees it, so a family's encoder receives
whole characters only, except at the very end with `last`.

## The registry lines

One line each, in the slots the comments mark for each wave:

| File                        | Line                                                                                   | When                    |
| --------------------------- | -------------------------------------------------------------------------------------- | ----------------------- |
| `src/codecs.zig`            | `.japanese = @import("japanese.zig"), // ziglint-ignore: Z028` in `families`           | every family            |
| `gen/sources.zig`           | `.{ .name = "jis0208", .file = "whatwg-encoding/index-jis0208.txt" },` in `multi_byte` | each committed table    |
| `gen/layouts.zig`           | `.ranged = @import("layouts/ranged.zig"), // ziglint-ignore: Z028` in `impls`          | each new layout         |
| `test/wpt/expectations.txt` | delete the family's `FAIL ... is not implemented yet` line                             | when its encodings land |
| `CHANGELOG.md`              | `- Shift_JIS, EUC-JP, and ISO-2022-JP decoders and encoders.` under Unreleased, Added  | every family            |

Nothing else: `implemented` (the list the fuzzer, oracle, streaming tests,
WPT harness, and benchmark arm iterate) is derived from `families`; the
WPT expectations name failures by encoding, so landing one turns its
expected failures into unexpected passes, which `just wpt --strict` lists;
`bench/encodings.tsv` and the corpus already list every encoding.

The IBM code pages are tables in the single-byte family, not a family:
uncomment their two lines in `gen/sources.zig` (the format is `.unicode`,
from `vendor/unicode/CP437.TXT` and `CP850.TXT`, already vendored), add
`.ibm437, .ibm850` to `single_byte.zig`'s `encodings`, and add a check of
those tables against the vendor files beside the WHATWG ones in
`test/tables.zig`. encoding_rs does not have them, so the oracle skips them
(any encoding without a label is skipped); Go's x/text and the iconv arms
have them in the benchmarks, and their checksums against this package are
the cross-check.

## Before it lands

- `just ci` passes: tests in Debug and ReleaseSafe, the table and vendor
  checksums, every layout on every index, lint, the bounded fuzz run, the
  oracle with no mismatches, the WPT harness, and the big-endian tests.
- `just fuzz 600` (or longer) finds nothing; `just fuzz 600 all <label>`
  aims the whole run at one encoding.
- `just oracle 20000` has no mismatches. Where encoding_rs disagrees with
  the standard, the standard wins: add the case to `known` in
  `test/oracle/compare.zig` with the reason, and write it up.
- `just bench-compare` with a filter for the family's rows, such as
  `just bench-compare 10 'Shift_JIS|EUC-JP|ISO-2022-JP'`, against
  encoding_rs, and `just bench-rodata` for table sizes, written up in
  `docs/slop/results/`.
