# The README's numbers, 2026-11-03

Every number in README.md, measured on main at `a1774d2` (wave 3 landed;
wave 4's conversions and adapters, which add no codec code, came after):
the full benchmark against every arm, the build for three x86-64 CPU
levels against encoding_rs, binary and table sizes, and detection against
chardetng and uchardet.

Headline: **3.55x encoding_rs**, geometric mean over its 6,688 rows (3.03x
decoding, 4.19x encoding), 123 rows slower beyond their 95% interval, 44
of them UTF-8 to UTF-8 encode, which is a copy for encoding_rs. Against
the comparison arms: ICU 5.20x, glibc iconv 10.29x, GNU libiconv 12.83x,
Go x/text 6.55x. Calls on 16 bytes take 10.0 ns median against
encoding_rs's 14.2 (1.39x) to decode to UTF-8. Tables: 307,099 bytes
against encoding_rs's 124,497 (2.47x). Detection: 92.0, 95.3, and 99.7%
mean accuracy at 16 bytes, 32 bytes, and on whole articles, against
chardetng's 88.9, 93.0, and 98.6%, at 61.5 MB/s against 9.9.

## Machine

Intel(R) Xeon(R) Processor @ 2.60GHz (family 6 model 106, Ice Lake
server), 4 vCPUs (2 cores, 2 threads each) in a KVM orb, AVX-512 (f, bw,
cd, dq, vl, vbmi, vbmi2, ifma, vnni, bitalg, vpopcntdq), Linux 6.1. Zig
0.16.0, ReleaseFast for the host CPU unless named; encoding_rs 0.8.44 for
Rust's default x86-64 target (its SSE2 code; `simd-accel` needs nightly),
release with LTO; ICU 78.3, glibc iconv, GNU libiconv, and Go x/text
v0.43.0 (`GOAMD64=v1`) from the dev shell. A shared host: read ratios, not
absolute GB/s.

Not measured: aarch64 speed (NEON is tested under qemu by `just
test-aarch64`; only its sizes are here), big-endian speed, other x86-64
machines, AMD included, other operating systems, dedicated hardware.

## Commands

- `just bench-corpus`, then `BENCHTIME_MS=20 just bench-compare 10`: every
  row this package has (7,040), every arm, ten rounds after a sizing round,
  each arm a server pinned to core 3, rows timed back to back by every arm
  in rotating order. The rounds took 2 h 51 min (10:26 to 13:18 UTC). 20
  ms samples, as every earlier results file used, instead of the recipe's default 50,
  which would have taken about 6 hours.
- The CPU levels:
  `just arms="rust zig zigv3 zigbase" bench-compare 10 '/[a-z]+-(16|65536)$'`,
  where `zigv3` and `zigbase` are `bench-zig` built with `cd bench && zig build -Dcpu=x86_64_v3` and `-Dcpu=baseline`, rows of
  16 and 65,536 bytes only. A filter must not start with `-`: the recipe
  passes it to `grep -E` as a pattern without `-e`, so `'-(16|65536)$'`
  fails with "no rows match".
- The CJK decode A/B:
  `just arms="rust zig cjk sb" bench-compare 10 '^Decode(Utf8|Utf16)/(Shift_JIS|EUC-JP|GBK|Big5|EUC-KR)/'`,
  with `bench-zig` built at `d361067` and `2a7108f` in worktrees.
- The CPU-level run and the A/B ran with this branch's README edits
  uncommitted, hence `a1774d2-dirty` in their configuration; no code
  differed from `a1774d2`.
- `just bench-rodata`; `bench/comptime/sizes.sh`; and in `bench/comptime`,
  `zig build sizes -Doptimize=ReleaseSmall` with `-Dcpu=x86_64_v3`,
  `-Dcpu=baseline`, and `-Dtarget=aarch64-linux-musl`.
- `just detect-corpus`, `just detect-score`, then four more speed rounds of
  each arm with `BENCH_MS=1500`, pinned to core 3.
- The family tables below come from a scratch script over the run's
  `raw-<arm>.txt` files with the same statistics as `bench/summary.awk`:
  a row's ratio is the median over rounds of the paired ratio, a group's the
  geometric mean of its rows', and the interval of a group is that of its
  per-round geomeans.

## Throughput against encoding_rs, by family

Inputs of 4 KiB to 1 MiB; each cell is this package's geomean GB/s and its
geomean ratio to encoding_rs. "Single-byte" is the 28 single-byte
encodings of the standard (x-user-defined, IBM437, and IBM850 are only in
the per-encoding summary below). Realistic is web, mail, subtitles, csv;
synthetic is ascii, nonascii, mixed, invalid.

Realistic:

| Family      |   decode to UTF-8 |   decode to UTF-16 | encode from UTF-8 | encode from UTF-16 |
| ----------- | ----------------: | -----------------: | ----------------: | -----------------: |
| UTF-8       | 13.74 GB/s, 1.36x |   4.51 GB/s, 4.57x | 14.12 GB/s, 0.23x |   9.91 GB/s, 9.72x |
| UTF-16      |  6.80 GB/s, 6.01x | 37.54 GB/s, 14.42x |                   |                    |
| single-byte |  3.51 GB/s, 3.64x |   7.66 GB/s, 5.19x |  1.89 GB/s, 3.67x |   7.20 GB/s, 5.84x |
| Japanese    |  0.65 GB/s, 1.72x |   1.09 GB/s, 2.24x | 0.54 GB/s, 13.69x |  0.63 GB/s, 18.20x |
| Chinese     |  0.69 GB/s, 1.84x |   0.97 GB/s, 1.84x | 0.57 GB/s, 38.97x |  0.72 GB/s, 54.44x |
| Korean      |  0.71 GB/s, 1.14x |   0.83 GB/s, 1.36x |  0.51 GB/s, 5.00x |   0.90 GB/s, 8.05x |

Synthetic:

| Family      |  decode to UTF-8 |  decode to UTF-16 | encode from UTF-8 | encode from UTF-16 |
| ----------- | ---------------: | ----------------: | ----------------: | -----------------: |
| UTF-8       | 6.30 GB/s, 1.26x |  3.46 GB/s, 3.17x | 15.83 GB/s, 0.32x |  14.21 GB/s, 9.65x |
| UTF-16      | 7.35 GB/s, 4.93x | 18.45 GB/s, 7.61x |                   |                    |
| single-byte | 5.51 GB/s, 6.97x |  8.08 GB/s, 6.56x |  2.02 GB/s, 4.84x |   4.65 GB/s, 6.54x |
| Japanese    | 1.27 GB/s, 2.41x |  1.54 GB/s, 2.66x |  0.99 GB/s, 7.08x |   1.21 GB/s, 8.51x |
| Chinese     | 1.28 GB/s, 1.99x |  1.34 GB/s, 1.90x | 1.14 GB/s, 15.74x |  1.25 GB/s, 16.58x |
| Korean      | 1.34 GB/s, 1.46x |  1.41 GB/s, 1.64x |  1.05 GB/s, 3.54x |   1.48 GB/s, 4.79x |

Calls on 16 bytes, median ns over the family's rows (all eight shapes),
this package / encoding_rs:

| Family      | decode to UTF-8 | decode to UTF-16 | encode from UTF-8 | encode from UTF-16 |
| ----------- | --------------: | ---------------: | ----------------: | -----------------: |
| UTF-8       |     19.0 / 15.6 |      20.5 / 18.1 |        11.9 / 9.2 |        12.8 / 15.3 |
| UTF-16      |     14.9 / 16.8 |      13.1 / 19.3 |                   |                    |
| single-byte |      9.9 / 13.8 |      10.2 / 13.7 |        9.0 / 14.9 |        10.2 / 15.8 |
| Japanese    |     29.3 / 34.0 |      27.5 / 30.2 |       22.1 / 28.2 |        22.3 / 29.5 |
| Chinese     |      9.6 / 14.5 |      10.8 / 14.6 |        8.5 / 12.7 |         9.1 / 13.8 |
| Korean      |      9.2 / 14.1 |      10.2 / 14.5 |        8.6 / 13.2 |         9.5 / 14.1 |

Over all 6,688 rows encoding_rs has: 3.55x (3.03x decode, 4.19x encode),
123 rows below beyond their interval and 48 too noisy to call. By
encoding and operation, `bench/summary.awk`'s table is under Raw output.

## Rows below encoding_rs

The 123, grouped:

- 44: UTF-8 to UTF-8 encode (0.11 to 0.79x), a copy for encoding_rs.
- 19: UTF-8 decode at 16 bytes (to UTF-8 0.82 to 0.93x, to UTF-16 0.67 to
  0.89x), plus ASCII at 256 and 4096 bytes (0.85, 0.97x), mixed-64 (0.95x),
  and random bytes to UTF-16 at 64, 256, and 65,536 bytes (0.78 to 0.95x).
- 27: Shift_JIS and Big5 decode of 16 bytes to 4 KiB (0.75 to 0.96x):
  Shift_JIS to UTF-8 11 rows, Big5 to UTF-8 8 and to UTF-16 8. The same
  encodings are 1.1 to 2.5x at 64 KiB and 1 MiB. See the A/B below.
- 3: EUC-KR decode of mail and web at 256 bytes and mail at 4 KiB (0.96 to
  0.99x).
- 17: single-byte decode to UTF-8: macintosh at 4 and 64 KiB (0.82 to
  0.95x, 6 rows), sparse-Latin text at 64 and 256 bytes in ISO-8859-2, -3,
  -13, -16, windows-1252 and -1257 (0.79 to 0.97x, 10 rows; the owner
  accepted these in wave 2), and windows-1251 random bytes at 16 (0.89x).
- 10: UTF-16LE and BE decode of random bytes at 16 to 65,536 bytes (0.58 to
  0.98x) and of nonascii and mixed at 16 bytes (0.87 to 0.94x).
- 3: x-user-defined encode from UTF-8 at 16 bytes (0.67 to 0.85x).

The full list with intervals is under Raw output.

## Shift_JIS and Big5 decode against the CJK landing

The CJK fast-path results (cjk-fast-paths-20261102.md, at `d361067`) had
Shift_JIS decode to UTF-8 at 1.46x encoding_rs with 4 rows below and Big5
at 1.43x with 1 below; this run has 1.31x with 11 below and 1.26x with 8
(to UTF-16, Big5 1.27x then and 1.23x now, 8 below each time). The other
CJK decoders kept or improved their ratios (GBK 1.80 to 1.99x, EUC-JP 1.80
to 1.87x). A/B to tell a change from a different run:
`just arms="rust zig cjk sb" bench-compare 10
'^Decode(Utf8|Utf16)/(Shift_JIS|EUC-JP|GBK|Big5|EUC-KR)/'`, where `cjk` is
`bench-zig` built at `d361067` and `sb` at `2a7108f` (wave 2 single-byte,
the commit that last touched the CJK decoders, through `codec.putBmp`).

Ratios are geomeans of per-row median paired ratios over all 44 rows of
each; `zig<cjk` and `zig>cjk` count rows where main is slower or faster than
`d361067` beyond the interval:

```text
encoding   op           rows zig/rust cjk/rust  sb/rust  zig/cjk   zig/sb  zig<cjk zig>cjk
Shift_JIS  DecodeUtf8     44     1.31     1.31     1.31     1.00     1.00        5       5
Shift_JIS  DecodeUtf16    44     1.60     1.59     1.61     1.01     0.99        2      11
EUC-JP     DecodeUtf8     44     1.86     1.83     1.86     1.02     1.00        5      11
EUC-JP     DecodeUtf16    44     1.66     1.66     1.66     1.00     1.00        6       5
GBK        DecodeUtf8     44     1.98     1.99     1.95     0.99     1.02        5       1
GBK        DecodeUtf16    44     1.81     1.82     1.78     1.00     1.02       12       7
Big5       DecodeUtf8     44     1.26     1.25     1.27     1.01     0.99       15       8
Big5       DecodeUtf16    44     1.23     1.23     1.23     1.01     1.01        7      17
EUC-KR     DecodeUtf8     44     1.33     1.31     1.33     1.02     1.00        7       8
EUC-KR     DecodeUtf16    44     1.48     1.44     1.44     1.03     1.03        4      15
Shift_JIS and Big5, realistic and nonascii, 64 B to 4 KiB: 60 rows zig/rust 1.01 cjk/rust 1.01 sb/rust 1.01 below rust: zig 29 cjk 29 sb 27
```

**Not a regression.** Main, `d361067`, and `2a7108f` are within 3% of each
other on every encoding and direction, and all three have 27 to 29 of the
60 Shift_JIS and Big5 rows of 64 bytes to 4 KiB below encoding_rs in this
run. The higher ratios in cjk-fast-paths-20261102.md are that run's, with
the same encoding_rs version and build. So the plan's "CJK rows below
encoding_rs fell from 50 to 18" was true of that run, and this run, on the
same code, has 30 (Shift_JIS 11, Big5 16, EUC-KR 3).

## Against ICU, iconv, and Go

| arm          | decode                   | encode                    | all rows                  |
| ------------ | ------------------------ | ------------------------- | ------------------------- |
| ICU 78.3     | 5.38x, 20 of 3,302 below | 5.01x, 272 of 3,160 below | 5.20x, 292 of 6,462 below |
| glibc iconv  | 11.89x, 6 of 3,214 below | 8.89x, 14 of 3,186 below  | 10.29x, 20 of 6,400 below |
| GNU libiconv | 17.36x, 1 of 3,124 below | 9.46x, 7 of 3,092 below   | 12.83x, 8 of 6,216 below  |
| Go x/text    | 6.62x, 5 of 1,680 below  | 6.47x, 12 of 1,576 below  | 6.55x, 17 of 3,256 below  |

ICU's 272 encode rows: single-byte encode of nonascii, mixed, and some
invalid text into the encodings whose letters are scattered through the
table and which this package encodes by search (wave 2 decided against a
reverse table): ISO-8859-2, windows-1250, KOI8-R, ISO-8859-13, -10, -3,
-4, windows-1257, -1258, -1254, IBM437, IBM850, macintosh, ... at 0.58 to
0.98x (nonascii-65536: ISO-8859-2 0.59x, windows-1250 0.59x, KOI8-R
0.58x); and CJK encode of nonascii and mixed text (GBK mixed 0.61 to
0.69x, Shift_JIS nonascii 0.67 to 0.88x, EUC-KR mixed and nonascii 0.57 to
0.87x). ICU's 20 decode rows: GBK, gb18030, EUC-KR, and Big5 mixed text to UTF-16
(16 rows, down to 0.62x), and random bytes to UTF-16 from UTF-8 (3) and
UTF-16LE (1).

Rows left out because the arm's output differs from the standard's: ICU
226 of 6,688 (3.4%), glibc iconv 464 of 6,864 (6.8%), GNU libiconv 472 of
6,688 (7.1%), x/text 264 of 3,520 (7.5%).

## Other CPU levels

`zigv3` and `zigbase` against encoding_rs on the 16- and 65,536-byte rows
(UTF-8 to UTF-8 left out), the geomean of per-row median ratios, then
each level's ratio to the host build:

```text
size 65536: geomean ratio to encoding_rs (rows), and each CPU level's ratio to the host build
family       dir     rows   host     v3   base   v3/host base/host
UTF-8        decode    16   2.25   2.25   2.22      1.00      0.99
UTF-8        encode     8  12.36  12.27  12.19      0.99      0.99
UTF-16       decode    32   7.84   7.56   5.72      0.97      0.73
single-byte  decode   448   6.76   4.71   2.83      0.70      0.42
single-byte  encode   448   5.90   4.55   3.38      0.77      0.57
Japanese     decode    48   2.50   2.45   2.40      0.98      0.96
Japanese     encode    48  10.37  10.10   8.04      0.97      0.78
Chinese      decode    48   2.13   2.11   2.09      0.99      0.98
Chinese      encode    48  26.36  25.68  20.59      0.97      0.78
Korean       decode    16   1.49   1.43   1.44      0.96      0.96
Korean       encode    16   4.61   4.50   3.69      0.98      0.80
all zig: 6.00x over 1208 rows, 6 below
all zigv3: 4.73x over 1208 rows, 4 below
all zigbase: 3.38x over 1208 rows, 47 below

size 16: geomean ratio to encoding_rs (rows), and each CPU level's ratio to the host build
family       dir     rows   host     v3   base   v3/host base/host
UTF-8        decode    16   0.89   0.94   1.11      1.06      1.25
UTF-8        encode     8   1.28   1.33   1.31      1.04      1.03
UTF-16       decode    32   1.24   1.31   1.43      1.05      1.15
single-byte  decode   448   1.57   1.41   1.51      0.90      0.96
single-byte  encode   448   2.05   1.91   1.77      0.93      0.86
Japanese     decode    48   1.26   1.25   1.29      0.99      1.02
Japanese     encode    48   2.84   2.78   2.63      0.98      0.93
Chinese      decode    48   1.48   1.46   1.50      0.99      1.02
Chinese      encode    48   4.66   4.59   4.20      0.98      0.90
Korean       decode    16   1.50   1.45   1.49      0.97      0.99
Korean       encode    16   2.59   2.52   2.35      0.98      0.90
all zig: 1.83x over 1208 rows, 23 below
all zigv3: 1.71x over 1208 rows, 14 below
all zigbase: 1.70x over 1208 rows, 16 below
```

Rows below encoding_rs at 65,536 bytes: host 6, v3 4, baseline 47. At
baseline, 28 are every single-byte encoding's nonascii decode to UTF-16
(0.61 to 0.63x) and 4 are windows-874's realistic rows (0.78 to 0.89x):
with no SSSE3 the block lookup patches lane by lane. utf's run-time
dispatch keeps UTF-8 and UTF-16 at the host's speed in every build. At 16
bytes the baseline build decodes UTF-8 faster than the host build: median
13.6 ns against 20.6 to UTF-16 and 17.5 against 18.7 to UTF-8 (v3: 14.6
and 21.1; encoding_rs 17.8 and 15.5). So the 16-byte UTF-8 rows below
encoding_rs are the AVX-512 build's: the baseline build is 1.11x
encoding_rs there. That path is utf's conversion; not investigated.

## Size

### Tables

`just bench-rodata` on the two arm binaries: this package's generated
tables take 307,099 bytes, encoding_rs's `encoding_rs::data` 124,497
(2.47x), the same as wave 2's CJK results recorded. 512 of the 307,099 are
IBM437's and IBM850's tables, which encoding_rs lacks. On this AVX-512
host the single-byte split tables for `pshufb` and `tbl` are not built.

### What a program links

`bench/comptime/sizes.sh` (ReleaseSmall and ReleaseFast for the host), then
ReleaseSmall for x86-64-v3, baseline x86-64, and aarch64. Net of `none`,
ReleaseSmall, bytes of `.rodata` + `.text`:

| program        | host (AVX-512)   | x86-64-v3        | baseline         | aarch64          |
| -------------- | ---------------- | ---------------- | ---------------- | ---------------- |
| `rt_label`     | 186,250 + 35,245 | 242,477 + 48,376 | 256,735 + 66,706 | 212,224 + 33,364 |
| `rt_enc_label` | 167,960 + 19,618 | 219,823 + 30,580 | 245,413 + 46,680 | 189,888 + 23,288 |
| `ct_1252`      | 1,049 + 5,781    | 51,012 + 12,250  | 72,550 + 17,350  | 21,168 + 4,800   |
| `ct_enc_1252`  | 1,775 + 5,711    | 54,338 + 13,565  | 79,804 + 21,503  | 24,608 + 8,384   |
| `ct_sjis`      | 16,530 + 3,298   | 16,552 + 3,304   | 16,528 + 3,255   | 16,528 + 3,308   |
| `ct_gb18030`   | 48,762 + 4,892   | 48,784 + 4,900   | 48,752 + 4,823   | 48,768 + 4,832   |
| `ct_euc_kr`    | 47,562 + 2,659   | 47,560 + 2,666   | 47,552 + 2,645   | 47,552 + 2,920   |

Against comptime-20261102.md (ReleaseSmall, host), three changes since the
compile-time decoders landed:

- `ct_1252` went from 320 + 812 to 1,049 + 5,781 on the host. Wave 2's
  single-byte decoder goes a 16-byte block at a time and transcodes a
  staged block of UTF-16 to UTF-8 with utf (`codec.bmpToUtf8`, which calls
  `utf.convert.utf16leToUtf8`); `encodeStaged` does the reverse with
  `utf8ToUtf16le`.
- **Off the host CPU the single-byte types cost 21 to 80 KB more.** On
  x86-64-v3 and baseline, utf's x86-64 dispatch links its kernels for the
  levels above the target and picks one at run time; an unstripped v3
  `size-ct_1252` holds `utf_..._avx512_convert_utf16leToUtf8` and its
  dispatch slot, and the `convert.utf8_pack2`, `utf8_pack3`, and
  `utf8_pack4` tables (4,352 + 4,352 + 10,625 bytes). aarch64 has no
  dispatch but its NEON kernel's tables come to about 20 KB. The CJK
  decoders do not call utf, so their sizes do not move with the target.
  CHANGELOG.md's "a windows-1252 decoder adds about 1 KB instead of about
  210 KB" holds only for an AVX-512 build.
- `ct_sjis` went from 29,650 to 16,530 bytes of `.rodata`: Shift_JIS no
  longer links index jis0212, which only EUC-JP decodes, since wave 2's
  `japanese.zig` `decodeAs`. `rt_enc_label` went from 192,608 to 167,960
  with wave 2's `flat_runs` encode tables for gb18030 and EUC-KR.

## Detection

`just detect-score` on main gives accuracy identical, cell for cell, to
detect-20261103.md's (the corpus, tables, and detector are unchanged), and
the same speed within noise. Speed, five runs of each arm pinned to core
3 (one from `just detect-score`, four with `BENCH_MS=1500`), medians:

| arm              | whole articles | a 32-byte window |
| ---------------- | -------------- | ---------------- |
| this package     | 61.5 MB/s      | 5,564 ns         |
| chardetng 0.1.17 | 9.9 MB/s       | 6,598 ns         |
| uchardet 0.0.8   | 5.1 MB/s       | 11,051 ns        |

Tables: this package 32,256 bytes (`detect-score tables`), chardetng
29,344 (`chardetng::data::DETECTOR_DATA` 28,224 and `SINGLE_BYTE_DATA`
1,120, by `nm -S`), uchardet's library 136,122 bytes of `.rodata` and 9,624
of `.data.rel.ro`. A `Detector` is 864 bytes.

## Raw output

### `BENCHTIME_MS=20 just bench-compare 10`: configuration, equivalence, peak RSS

```text
zig: ReleaseFast, native, a1774d2
rust: encoding_rs 0.8.44; icu 78.3; go: x/text v0.43.0
buffers: input 0 bytes past a page, output 2048; 20 ms a sample, 10 rounds
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor @ 2.60GHz

rust       6688 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-rust.txt), 12 skipped
zig        7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-zig.txt), 4 skipped
icu        6462 rows match the reference,  226 differ (zig-out/bench-compare/check-diff-icu.txt), 12 skipped
iconv      6400 rows match the reference,  464 differ (zig-out/bench-compare/check-diff-iconv.txt), 8 skipped
libiconv   6216 rows match the reference,  472 differ (zig-out/bench-compare/check-diff-libiconv.txt), 12 skipped
go         3256 rows match the reference,  264 differ (zig-out/bench-compare/check-diff-go.txt), 84 skipped

peak RSS (MiB)     rust      zig      icu    iconv libiconv       go
decode-utf8        35.4     32.5     37.8     34.0     33.9     30.0
decode-utf16       34.4     32.5     36.9     33.2     33.0        -
encode-utf8        33.3     32.3     36.9     33.2     33.0     29.3
encode-utf16       33.3     32.3     36.9     33.1     33.0        -
```

### Its summary (`just bench-summary`)

Per operation and encoding: this package's geomean GB/s and its ratio to each arm; against encoding_rs the spread over rounds, the rows below, the rows too noisy to call, and the slowest row. Then the per-call cost on inputs up to 256 bytes.

```text
zig/arm, geomean              rows  zig GB/s     rust      icu    iconv libiconv       go     ±   <1    ~   slowest vs rust
DecodeUtf8/UTF-8                44      3.77     1.15     6.58    19.38    20.53     8.86    2%    9    9   0.82 [0.81, 0.85] mail-16
DecodeUtf16/UTF-8               44      2.11     2.13     3.98     7.94    10.06        -    2%   10    2   0.67 [0.66, 0.69] invalid-16
EncodeUtf8/UTF-8                44      7.33     0.41    10.21    25.98    28.00    18.44    1%   44    0   0.11 [0.11, 0.11] invalid-4096
EncodeUtf16/UTF-8               44      6.53     4.42     6.46    17.16    20.17        -    1%    0    0   1.15 [1.07, 1.16] nonascii-16
DecodeUtf8/IBM866               44      3.10     3.98     7.51    12.35    17.39     7.24    2%    0    0   1.38 [1.32, 1.39] subtitles-16
DecodeUtf16/IBM866              44      4.93     4.04     3.79    12.98    27.49        -    2%    0    0   1.21 [1.14, 1.24] ascii-1048576
EncodeUtf8/IBM866               44      2.01     6.93     4.63     7.86     8.14    10.22    1%    0    0   1.64 [1.62, 1.66] mail-16
EncodeUtf16/IBM866              44      6.57    17.36     9.93    16.38    18.35        -    1%    0    0   1.41 [1.35, 1.45] ascii-1048576
DecodeUtf8/ISO-8859-2           44      3.35     2.69     6.97    12.30    16.20     6.49    2%    1    1   0.89 [0.85, 1.04] web-256
DecodeUtf16/ISO-8859-2          44      5.31     3.28     4.01    13.85    26.01        -    2%    0    0   1.20 [1.16, 1.39] ascii-1048576
EncodeUtf8/ISO-8859-2           44      1.77     3.22     4.09     5.59     7.23     5.58    2%    0    0   1.30 [1.29, 1.33] web-256
EncodeUtf16/ISO-8859-2          44      3.58     4.41     4.72     6.99     8.60        -    1%    0    0   1.42 [1.38, 1.62] ascii-1048576
DecodeUtf8/ISO-8859-3           44      3.15     2.35     6.80    12.75    15.22     6.07    1%    4    0   0.79 [0.78, 0.84] csv-64
DecodeUtf16/ISO-8859-3          44      5.25     3.14     4.40    16.19    25.86        -    1%    0    0   1.18 [1.13, 1.21] ascii-1048576
EncodeUtf8/ISO-8859-3           44      1.79     3.12     4.45     7.99     8.02     5.36    1%    0    0   1.64 [1.58, 1.65] mail-16
EncodeUtf16/ISO-8859-3          44      3.54     4.23     4.99     9.58     9.29        -    2%    0    0   1.37 [1.32, 1.50] ascii-1048576
DecodeUtf8/ISO-8859-4           44      3.55     2.93     7.47    13.13    17.01     6.87    1%    0    1   1.11 [0.93, 1.13] mail-256
DecodeUtf16/ISO-8859-4          44      5.54     3.49     4.19    14.55    26.39        -    2%    0    0   1.24 [1.18, 1.27] ascii-1048576
EncodeUtf8/ISO-8859-4           44      1.79     2.97     4.15     5.68     7.35     6.12    2%    0    0   1.34 [1.33, 1.45] mail-256
EncodeUtf16/ISO-8859-4          44      3.56     3.94     4.71     6.97     8.91        -    1%    0    0   1.40 [1.36, 1.48] ascii-1048576
DecodeUtf8/ISO-8859-5           44      3.20     4.04     7.50    12.55    16.61     7.17    1%    0    0   1.39 [1.36, 1.39] subtitles-16
DecodeUtf16/ISO-8859-5          44      4.93     4.03     3.72    12.90    24.96        -    2%    0    0   1.22 [1.18, 1.45] ascii-1048576
EncodeUtf8/ISO-8859-5           44      2.12     3.62     4.55     7.75     8.21    11.72    1%    0    1   1.28 [0.84, 1.30] invalid-16
EncodeUtf16/ISO-8859-5          44      8.31     4.48    11.69    18.78    21.15        -    1%    0    0   1.42 [1.36, 1.52] ascii-1048576
DecodeUtf8/ISO-8859-6           44      3.13     4.18     8.47    14.46    16.18     7.55    1%    0    0   1.39 [1.37, 1.41] ascii-16
DecodeUtf16/ISO-8859-6          44      4.95     4.33     4.77    16.55    25.47        -    1%    0    0   1.21 [1.18, 1.34] ascii-1048576
EncodeUtf8/ISO-8859-6           44      1.75     4.30     4.56     9.22     7.70    10.98    2%    0    0   1.65 [1.63, 1.66] mail-16
EncodeUtf16/ISO-8859-6          44      5.30     7.06     8.99    16.99    15.58        -    2%    0    0   1.41 [1.35, 1.54] ascii-1048576
DecodeUtf8/ISO-8859-7           44      3.11     4.04     7.69    13.66    16.28     7.25    1%    0    0   1.38 [1.36, 1.41] web-16
DecodeUtf16/ISO-8859-7          44      4.90     4.07     4.03    15.06    25.27        -    1%    0    0   1.19 [1.16, 1.23] ascii-1048576
EncodeUtf8/ISO-8859-7           44      2.00     3.64     4.54     8.98     8.44    11.02    1%    0    0   1.42 [1.38, 1.44] mixed-16
EncodeUtf16/ISO-8859-7          44      7.20     4.66    10.69    19.80    20.94        -    2%    0    0   1.45 [1.36, 2.25] ascii-1048576
DecodeUtf8/ISO-8859-8           44      3.12     4.12     8.36    14.23    16.65     7.48    2%    0    0   1.38 [1.30, 1.47] ascii-16
DecodeUtf16/ISO-8859-8          44      4.92     4.33     4.68    16.35    26.24        -    1%    0    0   1.20 [1.17, 2.00] ascii-1048576
EncodeUtf8/ISO-8859-8           44      1.93     3.60     4.99    10.70     8.84    12.00    2%    0    0   1.44 [1.38, 1.48] mixed-16
EncodeUtf16/ISO-8859-8          44      7.10     4.47    11.96    24.28    21.96        -    2%    0    0   1.44 [1.38, 1.75] ascii-1048576
DecodeUtf8/ISO-8859-8-I         44      3.10     4.06     8.19    13.92    16.43     7.16    3%    0    0   1.38 [1.28, 1.41] mail-16
DecodeUtf16/ISO-8859-8-I        44      4.85     4.25     4.55    16.04    25.88        -    2%    0    0   1.20 [1.16, 1.31] ascii-1048576
EncodeUtf8/ISO-8859-8-I         44      1.94     3.58     4.92    10.52     8.77    11.58    2%    0    0   1.44 [1.38, 1.47] mixed-16
EncodeUtf16/ISO-8859-8-I        44      7.37     4.50    11.92    24.20    22.00        -    1%    0    0   1.42 [1.34, 1.50] ascii-1048576
DecodeUtf8/ISO-8859-10          44      3.17     3.08     6.87    11.76    15.69     6.19    2%    0    1   1.08 [1.07, 1.14] csv-64
DecodeUtf16/ISO-8859-10         44      5.15     3.80     3.86    13.38    25.75        -    3%    0    0   1.20 [1.14, 1.25] ascii-1048576
EncodeUtf8/ISO-8859-10          44      1.38     2.44     3.20     5.14     5.72     4.96    2%    0    0   1.10 [1.08, 1.28] subtitles-256
EncodeUtf16/ISO-8859-10         44      2.89     3.12     3.94     6.49     7.16        -    1%    0    0   1.44 [1.36, 1.52] ascii-1048576
DecodeUtf8/ISO-8859-13          44      3.30     2.76     6.92    12.18    16.17     6.36    1%    2    1   0.80 [0.78, 0.85] web-256
DecodeUtf16/ISO-8859-13         44      5.43     3.52     4.10    14.21    26.87        -    1%    0    0   1.18 [1.14, 1.69] ascii-1048576
EncodeUtf8/ISO-8859-13          44      1.63     2.22     3.80     6.15     6.67     5.65    1%    0    1   1.00 [0.97, 1.02] subtitles-64
EncodeUtf16/ISO-8859-13         44      3.34     2.73     4.47     7.64     8.31        -    2%    0    0   1.43 [1.26, 1.47] ascii-1048576
DecodeUtf8/ISO-8859-14          44      4.46     2.64     9.27    16.25    21.91     8.83    3%    0    1   0.98 [0.97, 1.02] csv-65536
DecodeUtf16/ISO-8859-14         44      6.69     3.28     5.04    17.49    32.82        -    3%    0    0   1.24 [1.14, 1.29] ascii-1048576
EncodeUtf8/ISO-8859-14          44      2.88     2.27     6.73    10.14    12.09     8.62    1%    0    0   1.23 [1.19, 1.26] csv-256
EncodeUtf16/ISO-8859-14         44      5.70     2.62     7.26    12.21    14.27        -    1%    0    0   1.33 [1.28, 1.46] nonascii-16
DecodeUtf8/ISO-8859-15          44      3.92     2.67     8.07    14.18    18.59     7.49    2%    0    1   1.10 [1.08, 1.11] csv-65536
DecodeUtf16/ISO-8859-15         44      6.01     3.32     4.52    15.68    28.76        -    2%    0    0   1.19 [1.16, 1.23] ascii-1048576
EncodeUtf8/ISO-8859-15          44      3.04     2.39     7.06     9.91    12.51     8.93    1%    0    1   0.96 [0.94, 1.09] csv-256
EncodeUtf16/ISO-8859-15         44      9.87     3.74    12.88    19.56    24.21        -    2%    0    0   1.39 [1.33, 1.51] ascii-1048576
DecodeUtf8/ISO-8859-16          44      3.11     2.61        -    11.52    14.95     6.01    2%    1    2   0.87 [0.84, 0.89] web-256
DecodeUtf16/ISO-8859-16         44      5.47     3.49        -    14.25    26.46        -    2%    0    0   1.20 [1.16, 1.25] ascii-1048576
EncodeUtf8/ISO-8859-16          44      1.74     2.54        -     6.76     7.66     6.11    2%    0    0   1.16 [1.07, 1.17] subtitles-64
EncodeUtf16/ISO-8859-16         44      3.67     3.41        -     8.72     9.77        -    1%    0    0   1.42 [1.39, 1.47] ascii-1048576
DecodeUtf8/KOI8-R               44      3.14     3.99     7.49    12.40    16.17     7.32    2%    0    0   1.38 [1.27, 1.40] subtitles-16
DecodeUtf16/KOI8-R              44      5.00     4.06     3.75    12.97    25.42        -    1%    0    0   1.19 [1.14, 1.20] ascii-1048576
EncodeUtf8/KOI8-R               44      1.05     2.92     2.29     4.38     4.40     5.52    1%    0    0   1.46 [1.40, 1.51] subtitles-64
EncodeUtf16/KOI8-R              44      1.91     3.30     2.68     5.13     5.43        -    1%    0    0   1.39 [1.32, 1.42] ascii-1048576
DecodeUtf8/KOI8-U               44      3.13     4.02     7.51    12.51    16.63     7.25    2%    0    0   1.37 [1.29, 1.38] ascii-16
DecodeUtf16/KOI8-U              44      4.96     4.07     4.04    13.12    25.23        -    1%    0    0   1.22 [1.16, 1.46] ascii-1048576
EncodeUtf8/KOI8-U               44      1.21     3.51     2.73     5.14     5.03     6.31    1%    0    0   1.63 [1.61, 1.70] csv-16
EncodeUtf16/KOI8-U              44      2.24     4.10     3.20     6.17     6.27        -    1%    0    0   1.40 [1.36, 1.49] ascii-1048576
DecodeUtf8/macintosh            44      3.65     2.43     7.82    15.15    18.26     7.01    1%    6    2   0.82 [0.77, 0.83] subtitles-4096
DecodeUtf16/macintosh           44      6.18     3.22     4.64    18.90    29.78        -    1%    0    0   1.23 [1.12, 1.28] ascii-1048576
EncodeUtf8/macintosh            44      2.28     3.59     5.51     9.09    11.26     6.74    1%    0    0   1.65 [1.63, 1.73] csv-16
EncodeUtf16/macintosh           44      4.38     4.95     5.66    10.83    12.79        -    1%    0    0   1.41 [1.23, 1.52] ascii-1048576
DecodeUtf8/windows-874          44      2.70     3.62     8.15    13.50    16.20     7.54    2%    0    0   1.32 [1.28, 1.45] invalid-16
DecodeUtf16/windows-874         44      4.99     3.72     3.83    15.11    24.43        -    1%    0    0   1.21 [1.16, 1.27] ascii-1048576
EncodeUtf8/windows-874          44      2.21     3.58     3.76     7.78     7.76    10.60    1%    0    0   1.16 [1.11, 1.18] mixed-16
EncodeUtf16/windows-874         44      6.73     5.08     9.16    18.19    20.13        -    1%    0    0   1.41 [1.34, 1.45] ascii-1048576
DecodeUtf8/windows-1250         44      2.97     3.08     6.45    12.43    15.30     5.81    2%    0    0   1.11 [1.05, 1.12] invalid-16
DecodeUtf16/windows-1250        44      4.84     3.81     3.67    14.65    24.50        -    1%    0    0   1.18 [1.12, 1.24] ascii-1048576
EncodeUtf8/windows-1250         44      1.36     2.65     3.15     5.78     5.96     4.59    1%    0    0   1.33 [1.29, 1.35] web-256
EncodeUtf16/windows-1250        44      2.88     3.53     3.95     7.73     7.83        -    1%    0    0   1.46 [1.37, 1.56] ascii-1048576
DecodeUtf8/windows-1251         44      2.96     3.82     7.04    12.75    14.96     6.67    2%    1    0   0.89 [0.88, 0.91] invalid-16
DecodeUtf16/windows-1251        44      4.62     3.77     3.49    13.85    22.75        -    1%    0    0   1.21 [1.09, 1.40] ascii-1048576
EncodeUtf8/windows-1251         44      2.06     3.56     4.47     8.13     8.92    11.09    1%    0    0   1.44 [1.42, 1.47] mixed-16
EncodeUtf16/windows-1251        44      7.72     4.14    10.87    20.11    23.02        -    1%    0    0   1.42 [1.34, 1.48] ascii-1048576
DecodeUtf8/windows-1252         44      3.42     2.43     7.21    13.95    16.32     6.31    2%    1    1   0.85 [0.84, 0.94] web-256
DecodeUtf16/windows-1252        44      5.76     3.25     4.34    17.44    27.18        -    2%    0    0   1.20 [1.13, 1.25] ascii-1048576
EncodeUtf8/windows-1252         44      3.02     2.35     7.12    11.70    13.19     9.00    2%    0    2   1.22 [0.93, 1.38] invalid-16
EncodeUtf16/windows-1252        44      9.85     3.39    12.98    23.76    25.62        -    2%    0    0   1.38 [1.34, 1.46] ascii-1048576
DecodeUtf8/windows-1253         44      3.11     4.03     7.56    13.72    16.48     7.18    2%    0    0   1.38 [1.35, 1.39] ascii-16
DecodeUtf16/windows-1253        44      4.96     4.04     3.84    14.87    25.18        -    2%    0    1   1.21 [1.17, 1.26] ascii-1048576
EncodeUtf8/windows-1253         44      2.01     3.61     4.46     8.42     9.10    11.27    1%    0    0   1.41 [1.08, 1.42] mixed-16
EncodeUtf16/windows-1253        44      7.25     4.61    10.37    20.28    23.20        -    1%    0    0   1.44 [1.40, 1.47] ascii-1048576
DecodeUtf8/windows-1254         44      3.14     3.07     6.74    13.55    17.66     6.29    2%    0    0   1.12 [1.10, 1.13] web-256
DecodeUtf16/windows-1254        44      5.16     3.83     3.90    15.84    28.28        -    1%    0    0   1.20 [1.17, 1.38] ascii-1048576
EncodeUtf8/windows-1254         44      1.46     2.29     3.38     6.16     7.65     4.98    2%    0    1   1.12 [0.95, 1.13] web-256
EncodeUtf16/windows-1254        44      3.13     3.00     4.31     8.39     9.78        -    2%    0    0   1.38 [1.34, 1.46] ascii-1048576
DecodeUtf8/windows-1255         44      3.07     4.09     7.54    19.27    22.02     7.17    1%    0    0   1.37 [1.21, 1.40] subtitles-16
DecodeUtf16/windows-1255        44      4.85     4.16     3.93    18.22    27.46        -    2%    0    0   1.21 [1.18, 1.27] ascii-1048576
EncodeUtf8/windows-1255         44      1.98     3.70     4.71     7.77     9.55    11.32    1%    0    0   1.64 [1.61, 1.69] subtitles-16
EncodeUtf16/windows-1255        44      7.55     5.25    11.90    19.57    26.21        -    1%    0    0   1.35 [1.32, 1.44] ascii-1048576
DecodeUtf8/windows-1256         44      3.09     4.02     7.39    13.31    15.93     7.18    2%    0    0   1.39 [1.37, 1.41] mail-16
DecodeUtf16/windows-1256        44      4.91     4.03     3.71    14.62    25.13        -    2%    0    0   1.18 [1.13, 1.24] ascii-1048576
EncodeUtf8/windows-1256         44      1.26     3.16     2.72     6.06     5.12     6.57    1%    0    0   1.64 [1.64, 1.67] mail-16
EncodeUtf16/windows-1256        44      2.42     3.36     3.44     7.60     6.66        -    2%    0    0   1.46 [1.41, 1.51] ascii-1048576
DecodeUtf8/windows-1257         44      3.28     2.84     7.48    13.59    16.08     6.30    1%    1    0   0.90 [0.86, 0.93] mail-256
DecodeUtf16/windows-1257        44      5.53     3.54     4.23    16.65    25.97        -    1%    0    0   1.21 [1.19, 1.22] ascii-1048576
EncodeUtf8/windows-1257         44      1.76     2.71     4.26     7.83     7.72     5.84    2%    0    0   1.47 [1.42, 1.50] mail-4096
EncodeUtf16/windows-1257        44      3.47     3.47     4.58     9.88     9.19        -    2%    0    0   1.40 [1.34, 1.43] ascii-1048576
DecodeUtf8/windows-1258         44      3.13     3.75     7.13    30.69    46.23     6.73    2%    0    0   1.30 [1.27, 1.34] csv-64
DecodeUtf16/windows-1258        44      4.96     4.39     3.74    23.44    41.25        -    1%    0    1   1.22 [1.17, 1.44] ascii-1048576
EncodeUtf8/windows-1258         44      1.24     2.79     2.84     5.12     6.35     5.18    1%    0    0   1.50 [1.48, 1.63] csv-64
EncodeUtf16/windows-1258        44      2.42     3.47     3.51     6.14     7.83        -    2%    0    0   1.42 [1.33, 1.47] ascii-1048576
DecodeUtf8/x-mac-cyrillic       44      3.07     3.99     7.30    12.12    15.53     7.03    2%    0    0   1.37 [1.34, 1.39] web-16
DecodeUtf16/x-mac-cyrillic      44      4.95     4.05     3.91    12.99    24.12        -    1%    0    0   1.20 [1.12, 1.30] ascii-1048576
EncodeUtf8/x-mac-cyrillic       44      1.81     3.68     3.90     6.93     7.95     9.36    1%    0    0   1.64 [1.53, 1.65] subtitles-16
EncodeUtf16/x-mac-cyrillic      44      5.43     5.34     7.67    13.37    16.46        -    1%    0    0   1.43 [1.38, 1.44] ascii-1048576
DecodeUtf8/GBK                  44      1.12     1.99     4.98     4.38     6.57     4.58    1%    0    0   1.51 [1.34, 1.54] web-16
DecodeUtf16/GBK                 44      1.29     1.81     3.32     3.49     7.18        -    2%    0    0   1.15 [1.10, 1.16] subtitles-64
EncodeUtf8/GBK                  44      0.99    15.72     2.62     4.03     6.65     2.39    2%    0    0   1.54 [1.51, 1.55] csv-16
EncodeUtf16/GBK                 44      1.27    18.15     2.53     4.02     6.69        -    1%    0    0   1.55 [1.44, 1.57] ascii-16
DecodeUtf8/gb18030              44      1.13     2.00     4.74     4.81     7.06     4.76    1%    0    0   1.52 [1.48, 1.54] subtitles-16
DecodeUtf16/gb18030             44      1.31     1.83     3.19     4.01     7.77        -    1%    0    0   1.16 [1.15, 1.25] subtitles-64
EncodeUtf8/gb18030              44      0.98    15.58     4.22     3.50     5.79     2.38    1%    0    0   1.54 [1.39, 1.57] mail-16
EncodeUtf16/gb18030             44      1.27    18.08     2.57     3.44     5.95        -    1%    0    0   1.53 [1.44, 1.54] mail-16
DecodeUtf8/Big5                 44      1.00     1.26    11.12    12.13    13.60     5.18    2%    8    4   0.81 [0.79, 0.83] subtitles-4096
DecodeUtf16/Big5                44      1.11     1.23     5.57     9.71    12.25        -    1%    8    5   0.78 [0.77, 0.94] nonascii-4096
EncodeUtf8/Big5                 44      1.05    13.91     8.36    12.17    14.44     6.17    1%    0    0   1.48 [1.46, 1.58] subtitles-16
EncodeUtf16/Big5                44      1.51    17.37     6.81    13.66    15.13        -    1%    0    0   1.49 [1.41, 1.64] ascii-1048576
DecodeUtf8/EUC-JP               44      1.18     1.87     5.50     5.45     7.92     5.09    1%    0    0   1.22 [1.20, 1.24] subtitles-16
DecodeUtf16/EUC-JP              44      1.45     1.66     3.90     4.88     9.15        -    3%    0    1   1.14 [1.13, 1.17] subtitles-64
EncodeUtf8/EUC-JP               44      0.99     6.39     4.93    13.87     5.90     2.66    1%    0    0   1.25 [1.23, 1.26] subtitles-16
EncodeUtf16/EUC-JP              44      1.36     8.12     3.43    16.99     6.80        -    2%    0    0   1.34 [1.31, 1.35] ascii-16
DecodeUtf8/ISO-2022-JP          44      0.75     2.16     5.95     3.39     4.33     3.16    1%    0    1   1.06 [1.03, 1.07] mixed-16
DecodeUtf16/ISO-2022-JP         44      1.11     2.80     6.65     3.97     6.03        -    2%    0    1   1.05 [1.04, 1.26] subtitles-16
EncodeUtf8/ISO-2022-JP          44      0.62     6.78     7.65    11.10     4.15     1.87    1%    0    0   1.27 [1.23, 1.29] ascii-16
EncodeUtf16/ISO-2022-JP         44      0.87     8.29     7.35    13.09     4.80        -    2%    0    0   1.29 [1.16, 1.33] subtitles-16
DecodeUtf8/Shift_JIS            44      0.95     1.31     4.34     4.83     6.54     4.88    1%   11    1   0.75 [0.75, 0.77] nonascii-4096
DecodeUtf16/Shift_JIS           44      1.14     1.60     3.01     4.53     7.49        -    1%    0    0   1.08 [1.07, 1.11] subtitles-64
EncodeUtf8/Shift_JIS            44      0.88     5.89     2.23     3.52     5.66     2.71    1%    0    0   1.24 [1.13, 1.26] subtitles-16
EncodeUtf16/Shift_JIS           44      1.15     6.96     2.20     3.51     6.14        -    1%    0    0   1.33 [1.00, 1.44] mail-16
DecodeUtf8/EUC-KR               44      1.16     1.34     5.05     5.24     7.31     4.15    1%    3    2   0.96 [0.95, 1.00] mail-4096
DecodeUtf16/EUC-KR              44      1.25     1.48     3.04     4.22     7.55        -    2%    0    0   1.14 [1.14, 1.16] mixed-256
EncodeUtf8/EUC-KR               44      0.92     3.58     2.58     4.87     5.64     2.30    1%    0    0   1.52 [1.45, 1.53] web-16
EncodeUtf16/EUC-KR              44      1.56     5.03     3.12     5.73     7.17        -    2%    0    0   1.46 [1.34, 1.53] ascii-16
DecodeUtf8/UTF-16BE             44      3.93     3.18     6.56    11.46    13.40    11.06    2%    5    0   0.76 [0.72, 0.78] invalid-64
DecodeUtf16/UTF-16BE            44      8.94     5.28     5.43    18.85    28.87        -    2%    0    1   0.88 [0.86, 1.07] invalid-64
DecodeUtf8/UTF-16LE             44      3.53     2.68     6.92    11.36    12.32     9.93    1%    3    1   0.77 [0.77, 0.78] invalid-64
DecodeUtf16/UTF-16LE            44      9.24     4.63     5.29    21.71    28.98        -    1%    2    1   0.58 [0.49, 0.59] invalid-64
DecodeUtf8/x-user-defined       44      3.26     3.39        -        -        -     8.77    1%    0    0   1.43 [1.32, 1.50] mixed-16
DecodeUtf16/x-user-defined      44      9.63     1.75        -        -        -        -    1%    0    0   1.08 [1.05, 1.12] web-1048576
EncodeUtf8/x-user-defined       44      2.37     1.90        -        -        -     9.05    1%    3    0   0.66 [0.65, 0.70] mixed-16
EncodeUtf16/x-user-defined      44      4.86     3.02        -        -        -        -    3%    0    0   2.15 [2.12, 2.22] ascii-65536
DecodeUtf8/IBM437               44      3.82        -     8.17    14.02        -     7.26     -    0    0   -
DecodeUtf16/IBM437              44      6.24        -     4.89    16.35        -        -     -    0    0   -
EncodeUtf8/IBM437               44      2.21        -     5.70     7.94        -     6.65     -    0    0   -
EncodeUtf16/IBM437              44      4.40        -     6.09     9.75        -        -     -    0    0   -
DecodeUtf8/IBM850               44      3.22        -     6.79    12.95    15.99     6.08     -    0    0   -
DecodeUtf16/IBM850              44      5.63        -     4.36    16.73    27.14        -     -    0    0   -
EncodeUtf8/IBM850               44      1.78        -     4.51     6.49     7.19     5.79     -    0    0   -
EncodeUtf16/IBM850              44      3.77        -     5.27     8.41     9.28        -     -    0    0   -
all                           7040      2.90     3.55     5.20    10.29    12.83     6.55        123   48

ns/call, median      bytes       zig      rust       icu     iconv  libiconv        go  zig/rust
DecodeUtf8              16      10.0      14.2      97.1     106.0      84.8      36.6      1.39
DecodeUtf8              64      29.5      55.1     167.5     251.5     307.7     124.8      1.64
DecodeUtf8             256      77.9     325.0     432.6     869.0    1207.8     537.3      2.37
DecodeUtf16             16      10.6      14.4      36.1     104.7      86.3         -      1.36
DecodeUtf16             64      16.1      35.3      56.2     200.6     309.6         -      1.77
DecodeUtf16            256      43.1     169.0     134.0     580.8    1177.4         -      3.12
EncodeUtf8              16       9.0      14.9      88.0     112.3      90.7      35.9      1.65
EncodeUtf8              64      57.4     116.5     188.1     263.5     333.1     129.4      1.88
EncodeUtf8             256     219.3    1108.9     627.7    1009.5    1288.9     798.5      3.44
EncodeUtf16             16      10.2      15.8      58.4     122.0      89.0         -      1.55
EncodeUtf16             64      18.0      70.2     165.8     293.8     321.5         -      2.53
EncodeUtf16            256      72.4     344.4     608.0    1006.6    1243.0         -      4.19
```

### Every row below encoding_rs beyond its interval

From `rows.txt`: row, this package's and encoding_rs's median GB/s, the median ratio and its 95% interval.

```text
EncodeUtf8/UTF-8/invalid-4096                  16.135  145.192  0.111 [0.109, 0.112]
EncodeUtf8/UTF-8/mixed-4096                    16.077  112.588  0.143 [0.142, 0.152]
EncodeUtf8/UTF-8/web-4096                      16.357  113.169  0.144 [0.144, 0.145]
EncodeUtf8/UTF-8/subtitles-4096                16.189  111.109  0.146 [0.142, 0.147]
EncodeUtf8/UTF-8/csv-4096                      16.263  111.320  0.147 [0.141, 0.149]
EncodeUtf8/UTF-8/nonascii-4096                 16.324  111.266  0.147 [0.143, 0.147]
EncodeUtf8/UTF-8/mail-4096                     16.755  111.051  0.151 [0.150, 0.154]
EncodeUtf8/UTF-8/invalid-65536                 13.345   47.047  0.284 [0.283, 0.291]
EncodeUtf8/UTF-8/subtitles-65536               13.416   46.402  0.289 [0.286, 0.299]
EncodeUtf8/UTF-8/csv-65536                     13.449   46.476  0.290 [0.282, 0.304]
EncodeUtf8/UTF-8/nonascii-65536                13.478   46.269  0.290 [0.287, 0.293]
EncodeUtf8/UTF-8/mixed-65536                   13.419   46.303  0.291 [0.286, 0.291]
EncodeUtf8/UTF-8/web-65536                     13.507   46.403  0.291 [0.290, 0.292]
EncodeUtf8/UTF-8/mail-65536                    13.834   46.302  0.299 [0.296, 0.300]
EncodeUtf8/UTF-8/invalid-256                   11.506   31.907  0.361 [0.342, 0.366]
EncodeUtf8/UTF-8/mixed-256                      9.922   25.196  0.394 [0.388, 0.414]
EncodeUtf8/UTF-8/subtitles-256                  9.903   24.949  0.399 [0.394, 0.428]
EncodeUtf8/UTF-8/mail-256                      10.411   25.143  0.415 [0.402, 0.453]
EncodeUtf8/UTF-8/nonascii-256                  10.036   23.757  0.416 [0.402, 0.515]
EncodeUtf8/UTF-8/csv-256                        9.669   22.375  0.425 [0.372, 0.451]
EncodeUtf8/UTF-8/web-256                       10.727   25.178  0.428 [0.417, 0.437]
EncodeUtf8/UTF-8/ascii-4096                    49.288  112.628  0.438 [0.435, 0.452]
EncodeUtf8/UTF-8/invalid-64                     6.290   11.752  0.533 [0.513, 0.609]
EncodeUtf8/UTF-8/ascii-256                     13.274   25.161  0.540 [0.506, 0.552]
EncodeUtf8/UTF-8/mixed-1048576                  9.065   16.645  0.554 [0.487, 0.573]
EncodeUtf8/UTF-8/nonascii-1048576               9.125   16.325  0.556 [0.520, 0.583]
EncodeUtf8/UTF-8/web-1048576                    9.151   16.377  0.558 [0.541, 0.583]
EncodeUtf8/UTF-8/csv-64                         3.987    7.101  0.559 [0.556, 0.625]
EncodeUtf8/UTF-8/mixed-64                       3.959    7.103  0.560 [0.536, 0.566]
DecodeUtf16/UTF-16LE/invalid-64                 0.681    1.179  0.580 [0.491, 0.592]
EncodeUtf8/UTF-8/nonascii-64                    4.321    7.015  0.615 [0.592, 0.620]
EncodeUtf8/UTF-8/subtitles-64                   4.318    7.010  0.618 [0.608, 0.669]
EncodeUtf8/UTF-8/mixed-16                       1.100    1.732  0.633 [0.623, 0.655]
EncodeUtf8/UTF-8/invalid-16                     2.065    3.266  0.635 [0.630, 0.644]
EncodeUtf8/UTF-8/nonascii-16                    1.013    1.548  0.635 [0.629, 0.645]
EncodeUtf8/UTF-8/ascii-65536                   29.698   46.422  0.639 [0.637, 0.641]
EncodeUtf8/x-user-defined/mixed-16              0.692    1.046  0.665 [0.652, 0.697]
EncodeUtf8/UTF-8/ascii-64                       4.779    7.117  0.669 [0.663, 0.681]
DecodeUtf16/UTF-8/invalid-16                    0.088    0.131  0.670 [0.664, 0.689]
EncodeUtf8/UTF-8/web-64                         4.749    7.046  0.671 [0.610, 0.701]
EncodeUtf8/UTF-8/mail-64                        4.645    7.048  0.677 [0.602, 0.906]
DecodeUtf16/UTF-8/nonascii-16                   0.409    0.567  0.726 [0.716, 0.778]
DecodeUtf8/Shift_JIS/nonascii-4096              0.470    0.624  0.751 [0.749, 0.771]
DecodeUtf8/UTF-16BE/invalid-64                  0.485    0.640  0.756 [0.724, 0.778]
EncodeUtf8/x-user-defined/invalid-16            0.792    1.045  0.761 [0.730, 0.915]
EncodeUtf8/UTF-8/ascii-1048576                 12.674   16.499  0.763 [0.730, 0.809]
DecodeUtf8/UTF-16LE/invalid-64                  0.505    0.649  0.774 [0.769, 0.784]
DecodeUtf16/Big5/nonascii-4096                  0.655    0.839  0.781 [0.766, 0.939]
DecodeUtf16/UTF-8/invalid-64                    0.106    0.135  0.783 [0.776, 0.794]
EncodeUtf8/UTF-8/csv-16                         1.362    1.738  0.784 [0.701, 0.793]
EncodeUtf8/UTF-8/subtitles-16                   1.367    1.727  0.784 [0.762, 0.818]
EncodeUtf8/UTF-8/web-16                         1.342    1.702  0.785 [0.700, 0.982]
DecodeUtf8/ISO-8859-3/csv-64                    1.848    2.355  0.786 [0.779, 0.836]
EncodeUtf8/UTF-8/ascii-16                       1.368    1.738  0.786 [0.778, 0.808]
EncodeUtf8/UTF-8/mail-16                        1.355    1.733  0.786 [0.756, 0.791]
DecodeUtf8/Shift_JIS/web-4096                   0.515    0.674  0.788 [0.781, 0.846]
DecodeUtf16/Big5/nonascii-256                   0.630    0.777  0.796 [0.774, 0.938]
DecodeUtf8/ISO-8859-13/web-256                  4.304    5.475  0.800 [0.777, 0.848]
DecodeUtf8/Big5/subtitles-4096                  0.617    0.754  0.805 [0.788, 0.826]
DecodeUtf8/Shift_JIS/nonascii-64                0.449    0.553  0.814 [0.811, 0.870]
DecodeUtf8/Big5/mail-4096                       0.751    0.911  0.820 [0.813, 0.836]
DecodeUtf8/Shift_JIS/subtitles-4096             0.599    0.731  0.820 [0.793, 0.860]
DecodeUtf8/macintosh/subtitles-4096             4.730    5.791  0.820 [0.774, 0.834]
DecodeUtf8/Big5/web-4096                        0.573    0.703  0.821 [0.808, 0.869]
DecodeUtf8/UTF-8/mail-16                        0.856    1.040  0.823 [0.810, 0.852]
DecodeUtf8/UTF-8/web-16                         0.833    1.025  0.825 [0.753, 0.835]
DecodeUtf16/Big5/web-4096                       0.776    0.948  0.826 [0.805, 0.885]
DecodeUtf8/UTF-8/csv-16                         0.857    1.043  0.826 [0.807, 0.831]
DecodeUtf8/Shift_JIS/csv-4096                   0.544    0.655  0.830 [0.764, 0.842]
DecodeUtf16/Big5/nonascii-64                    0.613    0.736  0.831 [0.819, 0.856]
DecodeUtf8/UTF-8/ascii-16                       0.870    1.037  0.831 [0.812, 0.984]
DecodeUtf8/Shift_JIS/subtitles-64               0.827    0.986  0.832 [0.823, 0.892]
DecodeUtf8/Big5/nonascii-256                    0.508    0.568  0.844 [0.709, 0.980]
DecodeUtf8/Big5/csv-4096                        0.575    0.686  0.845 [0.815, 0.891]
DecodeUtf8/UTF-8/subtitles-16                   0.861    1.024  0.845 [0.829, 0.915]
DecodeUtf16/Big5/subtitles-4096                 0.862    1.019  0.847 [0.838, 0.854]
DecodeUtf8/Shift_JIS/nonascii-256               0.462    0.546  0.847 [0.840, 0.850]
DecodeUtf8/UTF-8/ascii-256                     10.130   11.803  0.852 [0.843, 0.891]
DecodeUtf8/windows-1252/web-256                 4.942    5.798  0.853 [0.836, 0.941]
DecodeUtf8/Big5/web-256                         1.344    1.552  0.854 [0.844, 0.862]
EncodeUtf8/x-user-defined/nonascii-16           0.952    1.115  0.854 [0.798, 0.863]
DecodeUtf8/Big5/subtitles-256                   0.681    0.819  0.857 [0.713, 0.898]
DecodeUtf16/Big5/csv-4096                       0.776    0.898  0.863 [0.853, 0.923]
DecodeUtf8/Shift_JIS/mail-256                   1.071    1.232  0.869 [0.865, 0.932]
DecodeUtf8/ISO-8859-16/web-256                  4.224    4.837  0.870 [0.843, 0.892]
DecodeUtf8/UTF-16BE/nonascii-16                 0.457    0.534  0.873 [0.751, 0.885]
DecodeUtf16/UTF-8/csv-16                        0.792    0.899  0.881 [0.838, 0.889]
DecodeUtf16/UTF-8/mail-16                       0.772    0.881  0.881 [0.848, 0.900]
DecodeUtf16/UTF-8/web-16                        0.789    0.884  0.883 [0.804, 0.910]
DecodeUtf8/UTF-16LE/nonascii-16                 0.460    0.517  0.883 [0.838, 0.898]
DecodeUtf16/UTF-8/ascii-16                      0.795    0.899  0.884 [0.795, 0.905]
DecodeUtf8/UTF-16LE/invalid-16                  0.459    0.518  0.884 [0.872, 0.899]
DecodeUtf16/UTF-8/subtitles-16                  0.796    0.898  0.886 [0.881, 0.894]
DecodeUtf8/macintosh/mail-4096                  4.928    5.574  0.886 [0.877, 0.954]
DecodeUtf8/ISO-8859-13/subtitles-64             2.216    2.503  0.888 [0.879, 0.894]
DecodeUtf8/Big5/csv-256                         0.665    0.749  0.893 [0.874, 0.976]
DecodeUtf8/windows-1251/invalid-16              0.471    0.527  0.893 [0.883, 0.913]
DecodeUtf16/Big5/subtitles-256                  0.941    1.050  0.896 [0.891, 0.950]
DecodeUtf8/windows-1257/mail-256                5.080    5.533  0.901 [0.863, 0.930]
DecodeUtf8/macintosh/subtitles-65536            4.724    5.211  0.905 [0.893, 0.932]
DecodeUtf8/Shift_JIS/web-256                    1.317    1.455  0.906 [0.890, 0.923]
DecodeUtf8/Shift_JIS/csv-256                    0.641    0.703  0.908 [0.898, 0.915]
DecodeUtf16/UTF-8/invalid-65536                 0.066    0.073  0.910 [0.904, 0.931]
DecodeUtf8/macintosh/web-65536                  4.635    5.052  0.920 [0.906, 0.948]
DecodeUtf8/UTF-16BE/invalid-16                  0.467    0.495  0.930 [0.863, 0.946]
DecodeUtf8/UTF-8/nonascii-16                    0.662    0.711  0.933 [0.915, 0.997]
DecodeUtf16/Big5/csv-256                        0.905    0.967  0.936 [0.927, 0.971]
DecodeUtf8/macintosh/csv-4096                   4.432    4.704  0.941 [0.925, 0.950]
DecodeUtf8/UTF-16BE/mixed-16                    0.569    0.607  0.942 [0.937, 0.977]
DecodeUtf16/UTF-8/invalid-256                   0.144    0.154  0.946 [0.919, 0.963]
DecodeUtf8/ISO-8859-3/subtitles-256             3.277    3.452  0.947 [0.890, 0.977]
DecodeUtf8/macintosh/mail-65536                 4.705    4.947  0.949 [0.937, 0.972]
DecodeUtf8/UTF-8/mixed-64                       2.785    2.943  0.951 [0.946, 0.959]
DecodeUtf8/ISO-8859-2/mail-256                  5.448    5.693  0.954 [0.928, 0.967]
DecodeUtf16/UTF-16LE/invalid-65536              1.621    1.697  0.957 [0.924, 0.972]
DecodeUtf8/Shift_JIS/nonascii-16                0.391    0.404  0.958 [0.951, 0.999]
DecodeUtf8/EUC-KR/mail-4096                     0.929    0.976  0.959 [0.951, 0.996]
DecodeUtf8/UTF-8/ascii-4096                    47.466   48.767  0.969 [0.924, 0.986]
DecodeUtf8/ISO-8859-3/subtitles-64              1.856    1.907  0.970 [0.905, 0.974]
DecodeUtf8/ISO-8859-3/web-256                   4.245    4.363  0.972 [0.926, 0.989]
DecodeUtf8/EUC-KR/web-256                       1.922    1.960  0.978 [0.965, 0.994]
DecodeUtf8/UTF-16BE/invalid-256                 0.687    0.699  0.980 [0.966, 0.988]
DecodeUtf8/EUC-KR/mail-256                      1.606    1.631  0.985 [0.982, 0.990]
```

### The family aggregates (scratch script)

```text
Throughput, inputs of 4 KiB to 1 MiB: zig's geomean GB/s, and its geomean ratio to each arm
(above 1, zig is faster); vs rust also the interval of the group's geomean over rounds,
and the rows slower than encoding_rs beyond their 95% interval.

family       op           shapes     rows zig GB/s rust GB/s     rust      icu    iconv libiconv       go      rust 95%   <1
UTF-8        DecodeUtf8   realistic     9    13.74     10.08     1.36    12.04    45.48    51.33    30.08  [1.36, 1.38]    0
UTF-8        DecodeUtf8   synthetic    11     6.30      5.01     1.26     8.56    40.10    50.87    15.03  [1.24, 1.28]    1
UTF-8        DecodeUtf16  realistic     9     4.51      0.99     4.57     8.51     9.79    14.58        -  [4.57, 5.10]    0
UTF-8        DecodeUtf16  synthetic    11     3.46      1.10     3.17     6.06    14.38    22.35        -  [3.15, 3.24]    1
UTF-8        EncodeUtf8   realistic     9    14.12     61.06     0.23    12.39    46.75    52.54    44.80  [0.23, 0.23]    9
UTF-8        EncodeUtf8   synthetic    11    15.83     49.42     0.32    13.72    44.48    55.61    36.76  [0.31, 0.32]   11
UTF-8        EncodeUtf16  realistic     9     9.91      1.01     9.72    11.59    24.78    37.38        -  [9.68, 9.88]    0
UTF-8        EncodeUtf16  synthetic    11    14.21      1.48     9.65    11.75    30.41    43.01        -  [9.46, 9.70]    0
UTF-16       DecodeUtf8   realistic    18     6.80      1.13     6.01     8.75    14.93    21.95    21.09  [5.92, 6.13]    0
UTF-16       DecodeUtf8   synthetic    22     7.35      1.49     4.93     8.23    21.06    30.83    26.40  [4.90, 5.03]    0
UTF-16       DecodeUtf16  realistic    18    37.54      2.60    14.42    12.29    43.79    91.36        - [14.42, 15.14]    0
UTF-16       DecodeUtf16  synthetic    22    18.45      2.40     7.61     6.86    35.34    73.71        -  [7.48, 7.99]    1
single-byte  DecodeUtf8   realistic   252     3.51      0.97     3.64     5.92    12.33    18.48     7.82  [3.60, 3.66]    6
single-byte  DecodeUtf8   synthetic   308     5.51      0.79     6.97     9.36    19.82    30.86    13.37  [6.95, 7.03]    0
single-byte  DecodeUtf16  realistic   252     7.66      1.47     5.19     3.97    15.77    41.08        -  [5.13, 5.19]    0
single-byte  DecodeUtf16  synthetic   308     8.08      1.23     6.56     4.72    17.81    41.48        -  [6.54, 6.64]    0
single-byte  EncodeUtf8   realistic   252     1.89      0.51     3.67     3.49     6.56     8.18     8.60  [3.66, 3.68]    0
single-byte  EncodeUtf8   synthetic   308     2.02      0.42     4.84     3.55     7.80     8.48    14.08  [4.82, 4.87]    0
single-byte  EncodeUtf16  realistic   252     7.20      1.23     5.84    10.37    14.65    20.16        -  [5.82, 5.87]    0
single-byte  EncodeUtf16  synthetic   308     4.65      0.71     6.54     6.42    11.59    13.73        -  [6.54, 6.60]    0
Japanese     DecodeUtf8   realistic    27     0.65      0.38     1.72     3.12     2.46     4.14     3.09  [1.68, 1.77]    3
Japanese     DecodeUtf8   synthetic    33     1.27      0.53     2.41     6.84     5.78    10.16     6.99  [2.39, 2.43]    1
Japanese     DecodeUtf16  realistic    27     1.09      0.49     2.24     3.62     2.60     6.00        -  [2.18, 2.29]    0
Japanese     DecodeUtf16  synthetic    33     1.54      0.58     2.66     5.88     5.06    11.66        -  [2.58, 2.70]    0
Japanese     EncodeUtf8   realistic    27     0.54      0.04    13.69     2.01     5.33     3.00     1.78 [13.27, 13.73]    0
Japanese     EncodeUtf8   synthetic    33     0.99      0.14     7.08     5.49    12.26     7.45     3.40  [6.98, 7.10]    0
Japanese     EncodeUtf16  realistic    27     0.63      0.03    18.20     2.04     6.24     3.68        - [17.59, 18.29]    0
Japanese     EncodeUtf16  synthetic    33     1.21      0.14     8.51     4.90    12.56     7.89        -  [8.34, 8.59]    0
Chinese      DecodeUtf8   realistic    27     0.69      0.37     1.84     2.87     2.43     4.60     3.22  [1.80, 1.86]    4
Chinese      DecodeUtf8   synthetic    33     1.28      0.64     1.99     6.41     7.00    13.60     7.23  [1.96, 2.01]    0
Chinese      DecodeUtf16  realistic    27     0.97      0.53     1.84     2.65     1.94     5.79        -  [1.81, 1.86]    3
Chinese      DecodeUtf16  synthetic    33     1.34      0.71     1.90     4.15     4.73    13.05        -  [1.88, 1.91]    1
Chinese      EncodeUtf8   realistic    27     0.57      0.01    38.97     1.29     1.61     3.26     1.32 [38.33, 39.20]    0
Chinese      EncodeUtf8   synthetic    33     1.14      0.07    15.74     4.64     5.05    11.18     3.75 [15.35, 16.23]    0
Chinese      EncodeUtf16  realistic    27     0.72      0.01    54.44     1.25     1.61     3.67        - [53.56, 55.60]    0
Chinese      EncodeUtf16  synthetic    33     1.25      0.08    16.58     3.08     4.23     9.68        - [16.32, 16.76]    0
Korean       DecodeUtf8   realistic     9     0.71      0.62     1.14     2.56     2.92     4.43     3.14  [1.13, 1.19]    1
Korean       DecodeUtf8   synthetic    11     1.34      0.92     1.46     5.42     5.45     9.63     5.11  [1.42, 1.50]    0
Korean       DecodeUtf16  realistic     9     0.83      0.61     1.36     1.71     2.14     4.78        -  [1.35, 1.48]    0
Korean       DecodeUtf16  synthetic    11     1.41      0.87     1.64     3.65     4.08     9.44        -  [1.60, 1.67]    0
Korean       EncodeUtf8   realistic     9     0.51      0.10     5.00     0.96     1.81     2.93     1.39  [4.70, 5.02]    0
Korean       EncodeUtf8   synthetic    11     1.05      0.30     3.54     2.60     8.29     6.54     2.70  [3.44, 3.67]    0
Korean       EncodeUtf16  realistic     9     0.90      0.11     8.05     1.58     2.15     4.22        -  [7.60, 8.12]    0
Korean       EncodeUtf16  synthetic    11     1.48      0.31     4.79     3.17     8.18     7.73        -  [4.61, 4.82]    0

Per call at 16 bytes: median over the family's rows (all 8 shapes) of each arm's median ns,
on the rows the arm shares with zig; zig/arm is the median of the per-row ratios of arm ns to
zig ns (above 1, zig is faster).

family       op           rows  zig ns     rust ns  ratio      icu ns  ratio    iconv ns  ratio libiconv ns  ratio       go ns  ratio
UTF-8        DecodeUtf8      8    19.0        15.6   0.84        72.4   3.82       102.4   5.37        84.7   4.47        41.6   2.21
UTF-8        DecodeUtf16     8    20.5        18.1   0.88        33.4   1.61        99.6   4.91        87.9   4.32           -      -
UTF-8        EncodeUtf8      8    11.9         9.2   0.78        78.8   6.70       103.3   8.68        84.9   7.22        36.6   3.08
UTF-8        EncodeUtf16     8    12.8        15.3   1.20        37.0   2.88       110.0   8.62        85.2   6.66           -      -
UTF-16       DecodeUtf8     16    14.9        16.8   1.12        87.6   5.87        86.8   5.82        52.4   3.37        38.2   2.52
UTF-16       DecodeUtf16    16    13.1        19.3   1.48        31.5   2.42        89.7   6.90        54.2   4.14           -      -
single-byte  DecodeUtf8    224     9.9        13.8   1.39        96.0   9.61       106.1  10.50        84.3   8.19        28.6   2.82
single-byte  DecodeUtf16   224    10.2        13.7   1.36        36.0   3.56       109.8  10.14        86.0   8.40           -      -
single-byte  EncodeUtf8    224     9.0        14.9   1.66        88.0   9.67       112.6  12.22        89.4   9.50        35.9   3.98
single-byte  EncodeUtf16   224    10.2        15.8   1.55        58.2   5.63       122.6  11.56        86.9   8.29           -      -
Japanese     DecodeUtf8     24    29.3        34.0   1.23       121.4   5.19       108.4   3.89        90.7   3.04        54.2   2.36
Japanese     DecodeUtf16    24    27.5        30.2   1.21        51.8   4.25       105.3   4.20        94.6   3.30           -      -
Japanese     EncodeUtf8     24    22.1        28.2   1.27       121.1   8.11       107.7  10.59        96.4   4.74        38.0   2.19
Japanese     EncodeUtf16    24    22.3        29.5   1.35        61.4   5.52       117.9  11.26        99.7   5.49           -      -
Chinese      DecodeUtf8     24     9.6        14.5   1.52       111.2  11.62       111.1  10.74        95.2   8.64        64.8   5.80
Chinese      DecodeUtf16    24    10.8        14.6   1.36        52.0   4.78       101.2   9.21        87.9   8.09           -      -
Chinese      EncodeUtf8     24     8.5        12.7   1.56        92.8   9.54       106.7  12.45       103.3  10.72        35.3   3.95
Chinese      EncodeUtf16    24     9.1        13.8   1.56        60.8   6.56       116.1  12.84       105.8  10.16           -      -
Korean       DecodeUtf8      8     9.2        14.1   1.53       110.0  11.98       101.2  10.89        94.3  10.17        47.6   5.00
Korean       DecodeUtf16     8    10.2        14.5   1.44        51.5   5.05       100.8   9.79        99.1   9.76           -      -
Korean       EncodeUtf8      8     8.6        13.2   1.53        81.1   9.34       105.6  12.18        95.0  10.97        35.9   4.09
Korean       EncodeUtf16     8     9.5        14.1   1.51        57.9   6.24       114.6  12.15       101.8  10.69           -      -

All rows: geomean of per-row median ratios, by direction
decode    rust 3.03 (3432 rows, 76 below)  icu 5.38 (3302 rows, 20 below)  iconv 11.89 (3214 rows, 6 below)  libiconv 17.36 (3124 rows, 1 below)  go 6.62 (1680 rows, 5 below)
encode    rust 4.19 (3256 rows, 47 below)  icu 5.01 (3160 rows, 272 below)  iconv 8.89 (3186 rows, 14 below)  libiconv 9.46 (3092 rows, 7 below)  go 6.47 (1576 rows, 12 below)
all       rust 3.55 (6688 rows, 123 below)  icu 5.20 (6462 rows, 292 below)  iconv 10.29 (6400 rows, 20 below)  libiconv 12.83 (6216 rows, 8 below)  go 6.55 (3256 rows, 17 below)
```

### The CPU-level run: configuration and equivalence

```text
zig: ReleaseFast, native, a1774d2-dirty
rust: encoding_rs 0.8.44; icu 78.3; go: x/text v0.43.0
buffers: input 0 bytes past a page, output 2048; 20 ms a sample, 10 rounds
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor @ 2.60GHz

rust       6688 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-rust.txt), 12 skipped
zig        7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-zig.txt), 4 skipped
zigv3      7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-zigv3.txt), 4 skipped
zigbase    7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-zigbase.txt), 4 skipped
```

### The CJK decode A/B: configuration, equivalence, and summary against encoding_rs

```text
zig: ReleaseFast, native, a1774d2-dirty
rust: encoding_rs 0.8.44; icu 78.3; go: x/text v0.43.0
buffers: input 0 bytes past a page, output 2048; 20 ms a sample, 10 rounds
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor @ 2.60GHz

rust       6688 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-rust.txt), 12 skipped
zig        7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-zig.txt), 4 skipped
cjk        7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-cjk.txt), 4 skipped
sb         7040 rows match the reference,    0 differ (zig-out/bench-compare/check-diff-sb.txt), 4 skipped

zig/arm, geomean              rows  zig GB/s     rust     ±   <1    ~   slowest vs rust
DecodeUtf8/GBK                  44      1.13     1.98    2%    0    0   1.52 [1.49, 1.57] ascii-16
DecodeUtf16/GBK                 44      1.30     1.81    1%    0    0   1.15 [1.14, 1.16] subtitles-64
DecodeUtf8/Big5                 44      1.01     1.26    1%   11    1   0.79 [0.78, 0.81] subtitles-4096
DecodeUtf16/Big5                44      1.10     1.23    2%    9    5   0.78 [0.77, 0.93] nonascii-256
DecodeUtf8/EUC-JP               44      1.18     1.86    1%    0    0   1.22 [1.20, 1.22] subtitles-16
DecodeUtf16/EUC-JP              44      1.45     1.66    1%    0    1   1.14 [1.13, 1.16] subtitles-64
DecodeUtf8/Shift_JIS            44      0.95     1.31    1%   10    2   0.75 [0.74, 0.75] nonascii-4096
DecodeUtf16/Shift_JIS           44      1.15     1.60    1%    0    0   1.09 [1.07, 1.10] subtitles-64
DecodeUtf8/EUC-KR               44      1.16     1.33    2%    2    1   0.96 [0.94, 1.00] mail-4096
DecodeUtf16/EUC-KR              44      1.25     1.48    2%    0    0   1.14 [1.13, 1.22] mixed-256
all                            440      1.16     1.53         32   10

ns/call, median      bytes       zig      rust  zig/rust
DecodeUtf8              16      11.2      14.4      1.49
DecodeUtf8              64      52.6      61.4      1.43
DecodeUtf8             256     302.5     365.6      1.60
DecodeUtf16             16      11.8      14.5      1.36
DecodeUtf16             64      40.9      48.6      1.40
DecodeUtf16            256     225.1     305.6      1.36
```

### `just bench-rodata`

```text
zig build rodata -- zig-out/bin/bench-zig zig-out/bin/bench-rust
zig-out/bin/bench-zig:
  single_byte.zig             29 of  29 arrays,  29 copies,    7424 bytes
  gb18030_ranges.zig           2 of   2 arrays,   2 copies,     824 bytes
  jis0208.zig                  6 of   6 arrays,   6 copies,   36785 bytes
  jis0212.zig                  2 of   2 arrays,   2 copies,   13026 bytes
  iso_2022_jp_katakana.zig page_of: 2 bytes, too short to find, not counted
  iso_2022_jp_katakana.zig     1 of   1 arrays,   1 copies,     192 bytes
  gb18030.zig                  6 of   6 arrays,   6 copies,   81470 bytes
  big5.zig                     6 of   6 arrays,   6 copies,   83532 bytes
  euc_kr.zig                   6 of   6 arrays,   6 copies,   83846 bytes
  total                       307099 bytes
zig-out/bin/bench-rust:
  single_byte.zig             27 of  29 arrays,  27 copies,    6912 bytes
  gb18030_ranges.zig           2 of   2 arrays,   2 copies,     824 bytes
  iso_2022_jp_katakana.zig page_of: 2 bytes, too short to find, not counted
  total                         7736 bytes
nm -S -C zig-out/bin/bench-rust | awk '$3 == "r" && $4 ~ /^encoding_rs::data::/ { n += strtonum("0x" $2) } END { print "zig-out/bin/bench-rust: encoding_rs::data, " n " bytes" }'
zig-out/bin/bench-rust: encoding_rs::data, 124497 bytes
size -A zig-out/bin/bench-zig zig-out/bin/bench-rust | grep -E '^(zig-out|\.rodata|\.text) '
.rodata            419998   16777792
.text              555049   17224016
.text                435842    32848
.rodata              186652   471040
```

### `bench/comptime/sizes.sh`

```text
== ReleaseSmall
program             rodata      text   +rodata     +text
both                204907    127487    186218     35354
ct_1252              19738     97914      1049      5781
ct_1252_sniff        22080    108535      3391     16402
ct_all_label        204939    127378    186250     35245
ct_enc_1252          20464     97844      1775      5711
ct_enc_sjis          55489     94729     36800      2596
ct_euc_kr            66251     94792     47562      2659
ct_gb18030           67451     97025     48762      4892
ct_nocjk_label       36963    110263     18274     18130
ct_sjis              35219     95431     16530      3298
ct_utf8_1252         28867    102749     10178     10616
label                27234     92433      8545       300
none                 18689     92133         0         0
rt_1252             197328    127029    178639     34896
rt_enc_label        186649    111751    167960     19618
rt_label            204939    127378    186250     35245
== ReleaseFast
program             rodata      text   +rodata     +text
both                274754    441353    187834     43872
ct_1252              88465    405641      1545      8160
ct_1252_sniff        91295    418665      4375     21184
ct_all_label        274818    441081    187898     43600
ct_enc_1252          89143    405577      2223      8096
ct_enc_sjis         123720    402361     36800      4880
ct_euc_kr           134490    402569     47570      5088
ct_gb18030          135674    404793     48754      7312
ct_nocjk_label      106186    421289     19266     23808
ct_sjis             103490    403257     16570      5776
ct_utf8_1252         97722    412489     10802     15008
label                95457    398553      8537      1072
none                 86920    397481         0         0
rt_1252             267199    440377    180279     42896
rt_enc_label        255936    424169    169016     26688
rt_label            274818    441081    187898     43600
```

### ReleaseSmall by target, net of `none` (host, x86-64-v3, baseline, aarch64)

```text
== ReleaseSmall
both                204907    127487    186218     35354
ct_1252              19738     97914      1049      5781
ct_1252_sniff        22080    108535      3391     16402
ct_all_label        204939    127378    186250     35245
ct_enc_1252          20464     97844      1775      5711
ct_enc_sjis          55489     94729     36800      2596
ct_euc_kr            66251     94792     47562      2659
ct_gb18030           67451     97025     48762      4892
ct_nocjk_label       36963    110263     18274     18130
ct_sjis              35219     95431     16530      3298
ct_utf8_1252         28867    102749     10178     10616
label                27234     92433      8545       300
none                 18689     92133         0         0
rt_1252             197328    127029    178639     34896
rt_enc_label        186649    111751    167960     19618
rt_label            204939    127378    186250     35245
== small-x86_64_v3
both                261053    140415    242477     48466
ct_1252              69588    104199     51012     12250
ct_1252_sniff        70978    121223     52402     29274
ct_all_label        261053    140325    242477     48376
ct_enc_1252          72914    105514     54338     13565
ct_enc_sjis          55376     94561     36800      2612
ct_euc_kr            66136     94615     47560      2666
ct_gb18030           67360     96849     48784      4900
ct_nocjk_label       93069    123022     74493     31073
ct_sjis              35128     95253     16552      3304
ct_utf8_1252         78509    112282     59933     20333
label                27114     92254      8538       305
none                 18576     91949         0         0
rt_1252             253458    139964    234882     48015
rt_enc_label        238399    122529    219823     30580
rt_label            261053    140325    242477     48376
== small-baseline
both                275223    158195    256727     66839
ct_1252              91046    108706     72550     17350
ct_1252_sniff        92180    139029     73684     47673
ct_all_label        275231    158062    256735     66706
ct_enc_1252          98300    112859     79804     21503
ct_enc_sjis          55280     94009     36784      2653
ct_euc_kr            66048     94001     47552      2645
ct_gb18030           67248     96179     48752      4823
ct_nocjk_label      107183    141319     88687     49963
ct_sjis              35024     94611     16528      3255
ct_utf8_1252         99687    124210     81191     32854
label                27024     91547      8528       191
none                 18496     91356         0         0
rt_1252             267636    157769    249140     66413
rt_enc_label        263909    138036    245413     46680
rt_label            275231    158062    256735     66706
== small-aarch64
both                226496    122964    212224     33588
ct_1252              35440     94176     21168      4800
ct_1252_sniff        36624    104724     22352     15348
ct_all_label        226496    122740    212224     33364
ct_enc_1252          38880     97760     24608      8384
ct_enc_sjis          51056     92184     36784      2808
ct_euc_kr            61824     92296     47552      2920
ct_gb18030           63040     94208     48768      4832
ct_nocjk_label       58640    106792     44368     17416
ct_sjis              30800     92684     16528      3308
ct_utf8_1252         44224    100096     29952     10720
label                22800     89784      8528       408
none                 14272     89376         0         0
rt_1252             218896    122324    204624     32948
rt_enc_label        204160    112664    189888     23288
rt_label            226496    122740    212224     33364
```

### `just detect-score`: accuracy and bytes needed

Accuracy, the percentage of samples guessed right, by encoding and size in bytes (each cell: zig / chardetng / uchardet). The last row averages the encodings.

| Encoding     | 16             | 32             | 64             | 128            | 256            | 1024           | 4096           | article        |
| ------------ | -------------- | -------------- | -------------- | -------------- | -------------- | -------------- | -------------- | -------------- |
| windows-1252 | 91/96/84       | 94/96/84       | 96/96/85       | 98/98/86       | 98/97/85       | 99/98/89       | 99/99/89       | 99/99/90       |
| windows-1250 | 75/89/84       | 83/92/89       | 86/93/91       | 92/95/96       | 97/95/98       | 99/96/98       | 98/99/98       | 99/98/99       |
| ISO-8859-2   | 74/90/81       | 80/93/86       | 85/95/89       | 92/96/93       | 97/96/95       | 99/97/97       | 99/99/97       | 99/99/97       |
| windows-1251 | 99/87/90       | 100/98/94      | 100/100/96     | 100/99/97      | 100/100/98     | 100/100/99     | 100/100/100    | 100/100/99     |
| KOI8-U       | 99/96/68       | 100/100/68     | 100/100/67     | 100/100/68     | 100/100/67     | 100/100/65     | 100/100/63     | 100/100/66     |
| ISO-8859-5   | 99/98/96       | 100/99/99      | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| IBM866       | 99/99/89       | 99/100/96      | 100/100/97     | 100/100/100    | 100/99/99      | 100/100/99     | 100/100/99     | 100/100/100    |
| windows-1253 | 99/96/100      | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/98     | 100/100/98     | 100/100/94     | 100/100/100    |
| ISO-8859-7   | 99/96/98       | 100/100/100    | 100/100/100    | 99/99/99       | 97/98/99       | 95/100/98      | 96/96/92       | 95/100/90      |
| windows-1254 | 92/85/67       | 93/89/77       | 99/93/76       | 100/95/76      | 100/99/74      | 99/99/67       | 100/99/62      | 100/100/67     |
| windows-1255 | 100/97/96      | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/99     | 100/100/100    |
| ISO-8859-8   | 96/81/96       | 100/92/99      | 100/96/100     | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| windows-1256 | 100/95/72      | 99/98/86       | 100/100/89     | 100/100/91     | 100/100/95     | 100/100/97     | 100/100/99     | 100/100/98     |
| ISO-8859-6   | 96/78/93       | 99/91/99       | 100/98/99      | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/98/100     |
| windows-1257 | 72/62/72       | 80/64/84       | 92/70/82       | 97/75/70       | 100/81/56      | 100/94/29      | 100/98/2       | 100/95/10      |
| ISO-8859-4   | 59/67/72       | 77/65/83       | 89/65/91       | 95/72/95       | 99/70/99       | 100/82/100     | 100/90/100     | 100/80/100     |
| ISO-8859-13  | 64/56/72       | 83/65/91       | 90/61/97       | 97/75/99       | 99/84/99       | 99/94/100      | 98/97/100      | 100/95/100     |
| windows-1258 | 90/77/78       | 98/92/86       | 100/94/100     | 99/100/99      | 99/99/99       | 100/100/100    | 100/100/100    | 100/100/100    |
| windows-874  | 100/96/75      | 100/100/90     | 100/99/93      | 100/100/91     | 100/100/94     | 100/100/97     | 100/100/96     | 100/100/95     |
| Shift_JIS    | 100/95/82      | 100/97/97      | 100/100/98     | 100/100/99     | 100/100/96     | 100/100/98     | 100/100/100    | 100/100/100    |
| EUC-JP       | 100/97/78      | 100/100/95     | 100/100/97     | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| ISO-2022-JP  | 100/100/100    | 99/100/100     | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| EUC-KR       | 100/98/81      | 100/96/92      | 100/98/98      | 100/97/99      | 100/98/99      | 100/100/100    | 100/100/100    | 100/100/100    |
| GBK          | 98/96/61       | 100/99/97      | 100/100/99     | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| Big5         | 99/97/45       | 99/100/91      | 100/100/97     | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    | 100/100/100    |
| mean         | 92.0/88.9/81.1 | 95.3/93.0/91.4 | 97.4/94.2/93.6 | 98.7/95.9/94.2 | 99.4/96.6/94.0 | 99.6/98.4/93.2 | 99.6/99.0/91.6 | 99.7/98.6/92.5 |

Bytes needed: over each encoding's articles, the median and 90th percentile of the shortest prefix from which every longer one is guessed right (of 16, 24, 32, 48, 64, ... bytes, and the whole article); an article guessed wrong in full counts as never, `-`.

| Encoding     | articles | zig median | zig p90 | zig never | chardetng median | chardetng p90 | chardetng never | uchardet median | uchardet p90 | uchardet never |
| ------------ | -------- | ---------- | ------- | --------- | ---------------- | ------------- | --------------- | --------------- | ------------ | -------------- |
| windows-1252 | 500      | 16         | 16      | 5         | 16               | 16            | 6               | 16              | 6407         | 49             |
| windows-1250 | 158      | 16         | 192     | 1         | 16               | 96            | 3               | 16              | 96           | 2              |
| ISO-8859-2   | 158      | 16         | 128     | 1         | 16               | 64            | 2               | 16              | 192          | 4              |
| windows-1251 | 119      | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 64           | 1              |
| KOI8-U       | 119      | 16         | 16      | 0         | 16               | 16            | 0               | 24              | -            | 40             |
| ISO-8859-5   | 119      | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 16           | 0              |
| IBM866       | 119      | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 24           | 0              |
| windows-1253 | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 16           | 0              |
| ISO-8859-7   | 20       | 16         | 16      | 1         | 16               | 16            | 0               | 16              | 16           | 2              |
| windows-1254 | 60       | 16         | 64      | 0         | 16               | 96            | 0               | 48              | -            | 20             |
| windows-1255 | 39       | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 24           | 0              |
| ISO-8859-8   | 39       | 16         | 16      | 0         | 16               | 64            | 0               | 16              | 16           | 0              |
| windows-1256 | 60       | 16         | 16      | 0         | 16               | 24            | 0               | 16              | 96           | 1              |
| ISO-8859-6   | 60       | 16         | 16      | 0         | 16               | 24            | 1               | 16              | 16           | 0              |
| windows-1257 | 40       | 16         | 64      | 0         | 48               | 1023          | 2               | -               | -            | 36             |
| ISO-8859-4   | 40       | 16         | 96      | 0         | 96               | -             | 8               | 16              | 64           | 0              |
| ISO-8859-13  | 40       | 16         | 96      | 0         | 48               | 512           | 2               | 16              | 64           | 0              |
| windows-1258 | 20       | 16         | 96      | 0         | 16               | 128           | 0               | 16              | 48           | 0              |
| windows-874  | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 16           | 1              |
| Shift_JIS    | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 24           | 0              |
| EUC-JP       | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 16              | 24           | 0              |
| ISO-2022-JP  | 20       | 15         | 16      | 0         | 15               | 16            | 0               | 15              | 16           | 0              |
| EUC-KR       | 20       | 15         | 16      | 0         | 16               | 96            | 0               | 16              | 48           | 0              |
| GBK          | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 24              | 48           | 0              |
| Big5         | 20       | 16         | 16      | 0         | 16               | 16            | 0               | 24              | 32           | 0              |

### Detection speed, five runs pinned to core 3

```text
zig	10557511 bytes x 12	61.8 MB/s	(sink 0)
zig	32-byte windows x 362840	5589 ns per call	(sink 0)
chardetng	10557511 bytes x 2	9.9 MB/s	(sink 0)
chardetng	32-byte windows x 308414	6604 ns per call	(sink 0)
uchardet	10557511 bytes x 1	5.1 MB/s	(sink 15)
uchardet	32-byte windows x 181420	11051 ns per call	(sink 15)
zig	10557511 bytes x 9	61.5 MB/s	(sink 0)
zig	32-byte windows x 272130	5564 ns per call	(sink 0)
chardetng	10557511 bytes x 2	9.8 MB/s	(sink 0)
chardetng	32-byte windows x 235846	6520 ns per call	(sink 0)
uchardet	10557511 bytes x 1	5.1 MB/s	(sink 15)
uchardet	32-byte windows x 136065	11053 ns per call	(sink 25)
zig	10557511 bytes x 9	59.2 MB/s	(sink 0)
zig	32-byte windows x 272130	5582 ns per call	(sink 0)
chardetng	10557511 bytes x 2	9.4 MB/s	(sink 0)
chardetng	32-byte windows x 226775	6688 ns per call	(sink 1)
uchardet	10557511 bytes x 1	5.1 MB/s	(sink 15)
uchardet	32-byte windows x 145136	10885 ns per call	(sink 15)
zig	10557511 bytes x 9	60.9 MB/s	(sink 0)
zig	32-byte windows x 281201	5440 ns per call	(sink 51)
chardetng	10557511 bytes x 2	10.0 MB/s	(sink 0)
chardetng	32-byte windows x 235846	6594 ns per call	(sink 0)
uchardet	10557511 bytes x 1	5.2 MB/s	(sink 15)
uchardet	32-byte windows x 145136	10651 ns per call	(sink 15)
zig	10557511 bytes x 9	62.4 MB/s	(sink 0)
zig	32-byte windows x 272130	5540 ns per call	(sink 0)
chardetng	10557511 bytes x 2	9.9 MB/s	(sink 0)
chardetng	32-byte windows x 235846	6598 ns per call	(sink 0)
uchardet	10557511 bytes x 1	5.1 MB/s	(sink 15)
uchardet	32-byte windows x 136065	11820 ns per call	(sink 25)
```
