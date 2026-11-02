# encoding bench

Benchmarks for decoding and encoding every encoding in the WHATWG Encoding
Standard, plus IBM437 and IBM850: this package against encoding_rs, ICU,
glibc's iconv, GNU libiconv, and Go's golang.org/x/text, over one pinned
corpus, with the size of the tables in the binary and each program's peak
RSS beside the timings.

These are local numbers, for iterating. They are not claims: a number that
gets quoted needs a run on dedicated hardware.

## Arms

Each arm is one program with the same contract. Run from the repository
root, `bench-<arm> check [OP...]` converts every input of every encoding in
`bench/encodings.tsv` once and prints one line per row, the output's length
and FNV-1a hash; `bench-<arm> serve` reads one request per line on stdin,
`OP ENCODING INPUT N`, and answers each with that row timed for N iterations
after one untimed call, or for `BENCHTIME_MS` (default 100) when N is 0, in
the Go benchmark format. An arm prints a `# SKIP` line for an encoding or
operation it has no equivalent for.

| Arm        | Program                               | Library                                                                      |
| ---------- | ------------------------------------- | ---------------------------------------------------------------------------- |
| `rust`     | `bench/rust/src/main.rs`              | encoding_rs 0.8.44 (`bench/rust/Cargo.lock`), the bar every arm is held to   |
| `zig`      | `bench/zig/arm.zig`                   | this package, ReleaseFast for the host CPU                                   |
| `icu`      | `bench/c/arm.c` with `-DARM_ICU`      | ICU 78 from the dev shell's nixpkgs                                          |
| `iconv`    | `bench/c/arm.c` with `-DARM_ICONV`    | glibc's iconv                                                                |
| `libiconv` | `bench/c/arm.c` with `-DARM_LIBICONV` | GNU libiconv from the dev shell                                              |
| `go`       | `bench/go/main.go`                    | golang.org/x/text (`bench/go/go.mod`), by the standard's names via htmlindex |

The operations, for each encoding:

| Operation      | Input                      | Output                    | encoding_rs                                          | this package                                         |
| -------------- | -------------------------- | ------------------------- | ---------------------------------------------------- | ---------------------------------------------------- |
| `decode-utf8`  | `<shape>-<size>.bin`       | UTF-8                     | `new_decoder_without_bom_handling`, `decode_to_utf8` | `Decoder.init(e, .{ .bom = .keep })`, `decodeToUtf8` |
| `decode-utf16` | the same                   | UTF-16, native byte order | `decode_to_utf16`                                    | `decodeToUtf16`                                      |
| `encode-utf8`  | `<shape>-<size>.utf8`      | the encoding              | `new_encoder`, `encode_from_utf8`                    | `Encoder.init(e, .{})`, `encodeFromUtf8`             |
| `encode-utf16` | the `.utf8` file in UTF-16 | the encoding              | `encode_from_utf16`                                  | `encodeFromUtf16`                                    |

Every call makes a fresh decoder or encoder and converts the whole input
with `last` set, replacing errors: U+FFFD for bytes that do not decode, and
a numeric character reference for a character the encoding lacks. The
standard has no encoder for UTF-16LE, UTF-16BE, or replacement (they encode
as UTF-8), so no arm times one. Throughput counts input bytes.

The arms do not all do the same work:

- encoding_rs's `encode_from_utf8` takes a `&str`, which Rust has already
  validated, so encoding UTF-8 as UTF-8 is a copy; this package's
  `encodeFromUtf8` takes bytes and validates them as it goes.
- ICU and iconv keep one converter for a row and reset it before each call,
  as a program converting many strings would; their tables are their own,
  not the standard's (Shift_JIS is `windows-31j` or `CP932`, EUC-KR is
  `windows-949` or `CP949`, Big5 is Big5-HKSCS). iconv stops at an error, so
  its arm writes U+FFFD, or `&#N;` when encoding, and goes on.
- x/text converts only to and from UTF-8, so its arm skips the UTF-16
  operations; it keeps one transformer for a row and resets it per call.

## Equivalence

`just bench-compare` runs every arm's `check` first. A row's reference is
encoding_rs's checksum, or this package's where encoding_rs lacks the
encoding (IBM437, IBM850). This package must match every reference, or the
run stops. Any other arm's row that differs is left out of the timing and
counted in `checks.txt`, with the differing rows in `check-diff-<arm>.txt`:
on invalid input most libraries replace errors differently from the
standard, and their tables differ from the standard's in places.

## Corpus

`bench/corpus/sources.tsv` lists one Wikipedia article per language, as
wikitext at a fixed revision; `bench/encodings.tsv` gives each encoding its
language. `just bench-corpus` fetches the articles into the gitignored
`bench/corpus-gen/sources/`, builds `bench-corpus` (in `bench/rust/`), which
writes every encoding's inputs into `bench/corpus-gen/<name>/`, and checks
the sources and every `.bin` file against `bench/corpus/SHA256SUMS`.

Each encoding gets eight shapes, each at 16, 64, 256, 4096, and 65536 bytes,
and the first, fifth, sixth, and seventh also at 1048576:

| Shape       | Content                                                                                                   |
| ----------- | --------------------------------------------------------------------------------------------------------- |
| `web`       | an HTML page with a `<meta charset>`, navigation, headings, links, and the article's paragraphs           |
| `mail`      | an mbox of plain-text messages with headers, wrapped paragraphs, and quoted replies                       |
| `subtitles` | SubRip cues of up to two 42-character lines                                                               |
| `csv`       | rows of ids, dates, names, amounts, and quoted notes                                                      |
| `ascii`     | English text, ASCII only                                                                                  |
| `nonascii`  | the language's non-ASCII characters only, with no spaces or markup: the worst case for an ASCII fast path |
| `mixed`     | ASCII and non-ASCII characters alternating                                                                |
| `invalid`   | random bytes, which most multi-byte decoders mostly reject                                                |

The text is the article's prose with the markup removed. A character the
encoding lacks is decomposed and written with what the encoding has (as
windows-1258 writes Vietnamese letters as a base and a combining mark), or
dropped. encoding_rs encodes every standard encoding; IBM437 and IBM850 use
Unicode's vendor tables in `vendor/unicode/`. Each `.bin` file has a
`.utf8` beside it, the standard's decode of it, which the encode rows read.
`just bench-corpus-sums` rewrites the checksums after a deliberate change.

## Method

`just bench-compare [ROUNDS] [FILTER...]` (default 10 rounds, every row
this package has) fetches and checks the corpus, builds the arms, checks
equivalence, and measures peak RSS: GNU `time` around one `check` pass per
arm and operation, which loads one encoding's inputs at a time. Then it
times the rows. On a shared host every arm's throughput steps by as much as
half for seconds at a time, so the arms run as servers pinned with
`taskset` to the last core, and every arm that has a row times it in turn,
in an order that rotates from row to row and round to round, before the
next row starts. A first round sizes each row's loop to `BENCHTIME_MS`
(default 50 here) and is not counted; each round after it starts the
servers afresh and runs every row that many iterations. Every input and
output buffer is an anonymous mapping of its own, the input at the start of
a page and the output 2048 bytes into one, in every arm alike;
`BENCH_IN_OFFSET` and `BENCH_OUT_OFFSET` move them.

FILTER is one or more extended regular expressions on row names,
`<Op>/<encoding>/<shape>-<size>`, such as
`just bench-compare 10 'windows-125[0-8]/web' 'DecodeUtf8/UTF-8/'`. The
variable `arms` picks the arms, encoding_rs first:
`just arms="rust zig" bench-compare`.

`benchstat` compares the arms' throughput in GB/s into `benchstat.txt`.
The summary has one line per operation and encoding: this package's
geometric-mean GB/s, and its ratio to each arm, the geometric mean of its
rows' ratios, where a row's ratio is the median over the rounds of this
package's GB/s divided by the arm's in the same round, with a 95%
confidence interval from the order statistics (above 1, this package is
faster). Against encoding_rs it also counts the rows slower beyond their
interval (`<1`) and the rows too noisy to call (`~`), and names the slowest
row. Then the per-call cost on short inputs: for each operation and size up
to 256 bytes, every arm's median ns per call, and this package's median
ratio to encoding_rs. `rows.txt` has every row against every arm.
Everything lands in `zig-out/bench-compare/`; `just bench-summary [DIR]`
prints the summary again.

`just bench-rodata` counts the bytes the single-byte tables take in this
package's and encoding_rs's arm binaries, by finding each table's 128 code
points in the binary (both store them the same way), and prints each
binary's `.rodata` and `.text` sizes.
