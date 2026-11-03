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
  `name()`, `outputEncoding()`, and `forBom(bytes)`. Every phase-1
  encoding is a tag from wave 0 on, IBM437 and IBM850 without labels;
  `isImplemented()` says whether this version has its codec, and
  `Decoder.init` and `Encoder.init` panic on one it lacks. `isImplemented`
  goes away when phase 1 is complete.
- `Decoder` and `Encoder`: small structs holding the streaming state (a
  pending lead byte, ISO-2022-JP's mode). `decodeToUtf8(src, dst, last)` and
  `decodeToUtf16(src, dst, last)` return how much they read and wrote and
  whether they stopped for output space, input, or (in fatal mode) an error
  and its position. Encoders mirror them from UTF-8 and UTF-16.
- `DecoderFor(encodings)` and `EncoderFor(encodings)`: `Decoder` and
  `Encoder` specialized at compile time to a set of encodings, so a program
  links only those families' code and tables (docs/slop/comptime.md).
  `Decoder` is `DecoderFor(&implemented)` and `Encoder` is
  `EncoderFor(&implemented)`, with the same calls, results, and streaming
  contract. Any order and repeats give the same type. An empty or
  unimplemented set is a compile error, and an encoding outside the set
  panics in `init`. A set that holds `bom_encodings` takes
  `Decoder.Options`; any other takes `OptionsWithoutSniff`, whose `bom` is
  `.remove` or `.keep` with no default. A family that tells its encodings
  apart at run time may declare `decodeAs` and `encodeAs`, with the encoding
  a compile-time parameter.
- `maxUtf8Len(n)`, `maxUtf16Len(n)`, and the encoders' `maxLenFromUtf8(n)`
  and `maxLenFromUtf16(n)` say how big an output buffer a call needs, so a
  caller can size it once.
- As built in wave 0: `Decoder.Options` has `mode` (`.replacement` or
  `.fatal`) and `bom`: `.sniff` is the standard's decode (a byte order mark
  picks UTF-8 or UTF-16 and is removed), `.remove` its "UTF-8 decode" and
  TextDecoder's default (only the encoding's own mark is removed), `.keep`
  "decode without BOM handling". A fatal error's `read` ends just past the
  malformed sequence. `Encoder.Options` has `mode` (`.html`, numeric
  character references, or `.fatal`); encoders read ill-formed UTF-8 or
  UTF-16 as U+FFFD, as the standard's UTF-8 decoder and its "convert to a
  scalar value" do. `docs/slop/adding-an-encoding.md` is the family
  contract behind both.
- One-call conveniences over a whole buffer into a caller's buffer, and a
  `std.Io.Reader`/`std.Io.Writer` adapter that transcodes a stream.
- `detect`: a `Detector` fed chunks with `feed`, then asked for `guess` or
  a ranked `guesses`, with `Hints` (top-level domain, declared language,
  whether UTF-8 may be guessed). Candidates are chardetng's set; UTF-16 is
  left to `Encoding.forBom`. `DetectorWith(tables)` is public for the
  scoring harness while the API incubates.

## Dependencies

- `baskingspot/utf`: UTF-8 and UTF-16 validation, conversion, and length
  are utf's, through its module, pinned to its v0.1.0 release in
  `build.zig.zon` (decision 3).
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

### Wave 1 split (proposed by wave 0)

Two orbs in parallel, each owning its family files and tables and adding
one line per registry (`docs/slop/adding-an-encoding.md`):

- **Japanese**: `src/japanese.zig` (or one file per encoding),
  `src/tables/jis0208.zig`, `jis0212.zig`, `iso_2022_jp_katakana.zig`, its
  layouts under `gen/layouts/`, and its results files. Registry lines in
  the Japanese slots of `src/codecs.zig`, `gen/sources.zig`, and
  `gen/layouts.zig`; its line in `test/wpt/expectations.txt`; a
  `CHANGELOG.md` bullet.
- **Chinese**: `src/gb18030.zig` (GBK and gb18030) and `src/big5.zig`,
  `src/tables/gb18030.zig`, its four-byte ranges, and `big5.zig`, its
  layouts, and its results files, with the same registry lines in the
  Chinese slots.

Both measure decisions 1 and 2 on their own indexes and write them up; the
orchestrating thread records the verdict here once both report, so neither
edits this file. Then **Korean** (`src/euc_kr.zig`, `src/tables/euc_kr.zig`,
on the layout the first two settle) and **IBM 437/850** (two lines in
`gen/sources.zig`, two tags in `single_byte.zig`'s `encodings`, and a check
against `vendor/unicode/` in `test/tables.zig`) can run in parallel too.

### Owners

Wave 0 (landed at `66f644c`): `Encoding` and labels, the `Decoder` and
`Encoder` interface, UTF-8, UTF-16, replacement, x-user-defined and the 28
single-byte encodings, the vendored indexes and WPT tests, the table
generator, and the fuzz, oracle, WPT, and benchmark harnesses.

Wave 1, Japanese and Chinese (both landed). Each orb owned its family's
files, added one line per registry, and measured decisions 1 and 2.

- **Japanese** (landed at `96e0808`; japanese-20261102.md,
  japanese-tables-20261102.md): Shift_JIS, EUC-JP, and ISO-2022-JP, on the
  `japanese_paged` layout. 2.98x encoding_rs geomean over its rows; decode
  0.93x at 16 bytes and 2.3x at 1 MiB; encode 5-7x, because encoding_rs's
  default build encodes kanji by linear scan. Tables 50,005 bytes against
  encoding_rs's 26,262 (68,056 with its fast kanji encode).
- **Chinese** (landed at `21277d8`; chinese-codecs-20261102.md,
  chinese-layouts-20261102.md): GBK, gb18030, and Big5, on the
  `chinese_rank` layout. Decode 1.02-1.38x encoding_rs geomean, encode
  12-19x, because encoding_rs encodes by searching its decode tables.
  Tables 186,552 bytes against encoding_rs's 69,526.

Wave 1b, two orbs in parallel. The orchestrating thread owns everything
not listed, including `src/utf8.zig`, `src/utf16.zig`, and
`build.zig.zon` (the utf repin), the harness cores, the flake, CI, and this
file.

- **Korean** (landed at `e4bbf6e`; korean-20261102.md): EUC-KR on the
  `chinese_rank` layout. Decode 1.23x and 1.28x encoding_rs geomean (to
  UTF-8 and UTF-16), encode 3.5x and 4.7x; 16-byte decode 0.72x, in the
  shared decoder path. Table 89,094 bytes against encoding_rs's 21,770.
- **Core and IBM** (landed at `d72503e`; core-20261102.md):
  `Decoder.init` and `Encoder.init` copy a fresh state from a compile-time
  table, so a family adds an entry rather than a branch; 16-byte calls 22.8
  to 16.7 ns geomean. Encoders read with `codec.read(Unit, src, i, first)`,
  a u32 code point with 2- and 3-byte UTF-8 inline; single-byte encode from
  UTF-8 is 2.6-3.2x faster. The tables' `decode` returns a u32, 0 for none:
  +10.9% CJK decode. The ASCII runs and the reader are shared in
  `codec.zig`. IBM437 and IBM850 are single-byte tables. test-layouts keeps
  flat, japanese_paged, and chinese_rank. Tables are 333,075 bytes against
  encoding_rs's 124,497.
- **Compile-time decoders** (landed; comptime-20261102.md, comptime.md):
  `DecoderFor`/`EncoderFor`, now the base of `Decoder` and `Encoder`. A
  windows-1252 decoder links 320 bytes of .rodata and 812 of .text in
  ReleaseSmall, against 178,212 and 34,047 for `Decoder`. One encoding is
  0.876x `Decoder`'s time per call at 16 bytes and the same at 64 KiB;
  `DecoderFor(&implemented)` is 1.004x and links what `Decoder` links.

Wave 2, SIMD, two orbs in parallel beside the compile-time decoder orb.
Neither edits `coder.zig` or `codecs.zig`. The orchestrating thread owns
everything not listed.

- **Single-byte and UTF-16** (landed at `2a7108f`;
  single-byte-20261102.md): every loop goes a 16-byte block at a time;
  across four code placements the median row varies 4.0% (14.5% before,
  0.9% noise). Single-byte decode to UTF-16 looks a block up with
  AVX-512BW `vpermi2w`, patching lanes elsewhere; the encoder maps ASCII
  and the table's two longest runs (less the C1 controls) by arithmetic and
  searches the rest. x-user-defined UTF-8 encode at 16 bytes 125.6 to 7.3
  ns; UTF-16 decode at 16 bytes 19.5 to 9.4 ns, and linear on unpaired
  surrogates. `codec.putBmp` writes a BMP code point with no optional, for
  the CJK families. 3.49x encoding_rs over its 5,632 rows; 33 below. The
  owner decided: add the block lookup for AVX2 (`pshufb`) and NEON (`tbl`),
  where single-byte decode is 59-74% of the AVX-512 build (wave 2b);
  accept the NCR-heavy encode slowdowns (worst 0.52x of before, still above
  encoding_rs) and the 16 sparse-Latin decode rows to UTF-8 at 64-256
  bytes (0.78-1.00x encoding_rs), since a scalar path would bring back the
  placement-sensitive loop; no reverse table for the Latin-2-type encoders,
  which would cost up to 64 KiB each.
- **CJK** (landed at `d361067`; cjk-fast-paths-20261102.md,
  cjk-tables-20261102.md): Big5, GBK, and gb18030 decode write without
  `tryPut`'s optional; Shift_JIS and EUC-JP copy ASCII a block at a time;
  ISO-2022-JP replaces errors in its ASCII loop; `japanese.zig` has
  `decodeAs` and `encodeAs`. gb18030 and euc_kr generate in `flat_runs`:
  tables 333,073 to 307,099 bytes (2.47x encoding_rs). CJK rows below
  encoding_rs fell from 50 to 18. The owner kept `flat_runs` for gb18030:
  20.7 KB smaller for GBK and gb18030 encode at 0.87-0.90x, still
  13-15.7x encoding_rs.

Wave 2b and wave 3, two orbs in parallel. The orchestrating thread owns
everything not listed, including `coder.zig`, `codecs.zig`, `encoding.zig`,
`CHANGELOG.md`, `THIRD_PARTY.md`, and this file. Each orb may append the
lines it needs to `root.zig`, `build.zig`, `justfile`, `flake.nix`,
`test/fuzz/main.zig`, and `.github/workflows/ci.yml`, and proposes everything else in its report.

- **Portable SIMD** (running, branch `wave2b-simd-portable`):
  `src/single_byte.zig` and `src/codec.zig`. The single-byte block lookup
  for x86-64 without AVX-512 (SSSE3 `pshufb`, AVX2) and for aarch64 (NEON
  `tbl`), and an aarch64 test job under qemu.
- **Detection** (landed at `15ecb3b`; detect-20261103.md): `Detector` in
  `src/detect.zig`, its trainer `gen/detect/train.zig`, and the scoring
  harness `test/detect/`. Mean accuracy over 25 encodings at 16 bytes,
  32 bytes, and on whole articles is 92.0, 95.3, and 99.7%, against
  chardetng's 88.9, 93.0, and 98.6% and uchardet's 81.1, 91.4, and 92.5%.
  Tables are 32.3 KB (chardetng 29.3 KB); whole articles run at 61.2 MB/s
  (chardetng 9.8 MB/s); 864 bytes of state. Behind chardetng on short
  windows-1252, short central European, ISO-8859-4 at 16 bytes, and
  ISO-8859-7 against windows-1253. `just detect-check` needs the network,
  so it is not in `just ci`.

## Decisions to measure

1. **Table layout.** encoding_rs compresses its CJK tables (ranges and
   deltas instead of flat arrays) and pays a little lookup speed for it.
   Measure flat, ranged, and two-level layouts on decode and encode speed and
   on `.rodata` size before settling.
   Japanese measured (japanese-tables-20261102.md): `japanese_paged`, pages
   of 32 to 128 entries behind a page index with empty pages shared,
   decodes at 0.95 ns a lookup against 0.80 for flat, and jis0208 is 29%
   smaller; ranged is 2x slower to decode for little saving. Chinese
   measured (chinese-layouts-20261102.md): gb18030 and Big5 are dense, so
   pages share nothing; a flat u16 decode array with a bit per pointer for
   plane-2 code points is both smallest and fastest there (47,880 and
   42,040 bytes), and `japanese_paged` is 692 and 34,403 bytes larger and
   2-7% slower to decode. **Verdict** (owner agreed on paged for Japanese):
   paged decode where pages save bytes (jis0208, jis0212, euc_kr), flat with
   the plane-2 bit where they do not (gb18030, Big5). Korean measured
   (korean-20261102.md): on euc_kr pages save 6,334 bytes (41,166 against
   47,500) but decode 5% slower geomean and 7-11% slower on Korean text, so
   euc_kr takes flat decode. **Verdict amended:** paged for jis0208 and
   jis0212; flat for gb18030, Big5, and euc_kr. Wave 2 measured rows (each row cut
   to the columns that hold code points): 11,016 bytes off euc_kr, but
   decode 4-9% slower; not taken. Narrow u8 pages are counted (-10.7 KB
   gb18030, -17.3 KB euc_kr) but not built. Whatever the layout, never merge
   two branches into an optional or a struct holding a `u21`: LLVM routes
   it through memory, a store-forwarding stall per character. Return early,
   or use `u32`. The same holds for any optional in a hot loop:
   `codec.tryPut`'s `?usize` and a captured `?u21` from a table's `decode`
   both go through the stack every character. Unwrap at once (`orelse 0`),
   or return an integer with a sentinel. Never build a tagged union one branch
   per variant and then copy it (a store-forwarding stall); copy a value
   built at compile time.
2. **Encoder lookups.** Encoding to a CJK encoding needs a reverse map from
   code point to bytes: a search over the decode table, a generated
   perfect hash, or a ranged reverse table. Same two-sided measurement.
   Japanese measured: a 64-code-point bitmap per block with a popcount
   rank into packed pointers, 1.38 ns a lookup against 41 for bisection
   and 6 for a perfect hash, and 31% smaller than the flat encode table.
   Chinese measured the same table, byte for byte: 12-19x encoding_rs,
   against 7-9x for a perfect hash, 4-5x for bisection, and 1-2x for a
   vector scan of the decode table, which would save 95,808 bytes.
   **Verdict:** rank, everywhere. Amended in wave 2: rank with runs where
   they pay. `flat_runs` keeps the first pointer of a block's run of
   consecutive pointers and ranks the rest, reading the run word only for
   code points outside it, where the run is at least half its block but not
   all of it: gb18030 encode 54,316 to 33,590 bytes at 0.87-0.90x, euc_kr
   41,594 to 36,346 at 0.99x. A run word read on every lookup cost 12-15%;
   a u8 per 64 code points under a u16 per 4096 saved 5.9 KB for 5%.
   Neither is in. CJK loops are bound by instructions (about six cycles a
   character), so a layout that adds two instructions to every lookup
   costs 5-10% whatever it saves in loads: put a layout's extra work on the
   path of the characters that need it. Integer types bite in hot code:
   `@min(x, N)` with a comptime N has the smallest type that holds N
   (`@min(len, 256)` is a u9), and `@popCount` of a u16 is a u5, so give
   the result a type; `a = .{ x, a[0] }` writes `a[0]` before reading it,
   so go through a temporary.
3. **Sharing with utf.** Settled in wave 0: depend on utf's module, now
   pinned to its v0.1.0 release. Its public `validate`, `convert`, and
   `length` cover the UTF-8 and UTF-16 codecs, and its runtime x86-64
   dispatch comes with them; `simd.zig` is not exported and is utf's
   internals, so vendoring it would fork the dispatch and the kernels for
   no gain, and the ASCII runs a legacy codec needs are a few lines of
   `@Vector` code in `src/codec.zig`. utf v0.1.0 builds for 32-bit targets
   and its checked conversions return a `ConvertResult` whose `written` is
   the output before an error, so the UTF-8 and UTF-16 codecs no longer
   recount with `utf.length`. The WPT harness stays on wasm64 because
   testingx v0.4.0's runner does not build for WASI; utf itself would.
4. **UTF-16 output.** Whether `decodeToUtf16` gets SIMD paths of its own or
   goes through UTF-8, judged by how often callers on Windows and JavaScript
   hosts would use it.
5. **Detection's model.** chardetng's approach (byte-pair scores per
   encoding and language, from a training corpus) against simpler
   frequency models, on accuracy, bytes needed, and table size.
   **Decided** (detect-20261103.md): byte-pair scores. A Markov chain over
   character classes per language group, plus each language's class
   frequencies, with the languages mixed as probabilities. It beats a
   frequency-only model by 9 points at 16 bytes and chardetng's
   most-favorable-language merge by 2.4. With 512 listed CJK characters and
   48 classes per group, the tables are 32.3 KB. windows-1252 keeps the
   lowest prior, since it is the commonest unlabeled encoding.
