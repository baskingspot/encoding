# CJK table diet: runs in the rank encode tables, and the candidates measured against them, 2026-11-02

Wave 2, CJK. The owner keeps the rank encode tables (plan decision 2) for
their speed, 4-19x encoding_rs, and asked for them smaller without giving
it up; a program that only decodes never links them (link-size-20261102.md).
Machine, harness, and arms as in cjk-fast-paths-20261102.md: Intel(R)
Xeon(R) Processor @ 2.60GHz (Ice Lake-SP), Zig 0.16 ReleaseFast for the
host CPU, encoding_rs 0.8.44, `just arms=... bench-compare 10 FILTER` with
`BENCHTIME_MS=20`, each arm pinned to core 3, rows timed back to back in
rotating order, benchstat. Table bytes are counted from the generated
arrays and checked with `zig build rodata` on the bench binary.

Headline: gb18030 and EUC-KR now generate in `flat_runs`, chinese_rank
with runs in the encode table. The tables go from 333,073 to 307,099
bytes, 2.68x to 2.47x encoding_rs's 124,497. gb18030's encode table is
54,316 bytes against 33,590 (-38%), EUC-KR's 41,594 against 36,346
(-13%). GBK and gb18030 encode 0.87x to 0.90x as fast geomean, still
13x to 17x encoding_rs; EUC-KR 0.99x. Every other table and every decode
row is unchanged. The other candidates cost more speed than the bytes
were worth: a coarser block index (5,915 bytes, 5% of encode), rows
decode tables (11,016 bytes on EUC-KR, 4% to 9% of decode), and a run
word read on every lookup (10,790 more bytes than `flat_runs`, for 12% to
15% of encode on all three encodings).

## The tables, before and after

`zig build rodata -- zig-out/bin/bench-zig` on the arm of this branch's
code and tables (`nx`) and on `main` (`2130053`), bytes; encoding_rs's
from wave 1 (`nm` of its bench binary, per family):

| table              | layout before    |  before | layout after     |   after |  change |
| ------------------ | ---------------- | ------: | ---------------- | ------: | ------: |
| jis0208            | `japanese_paged` |  36,785 | `japanese_paged` |  36,785 |       0 |
| jis0212            | `japanese_paged` |  13,026 | `japanese_paged` |  13,026 |       0 |
| gb18030            | `chinese_rank`   | 102,196 | `flat_runs`      |  81,470 | -20,726 |
| big5               | `chinese_rank`   |  83,532 | `chinese_rank`   |  83,532 |       0 |
| euc_kr             | `chinese_rank`   |  89,094 | `flat_runs`      |  83,846 |  -5,248 |
| total (all tables) |                  | 333,073 |                  | 307,099 | -25,974 |

| family   |  before |   after | encoding_rs | before/rs | after/rs |
| -------- | ------: | ------: | ----------: | --------: | -------: |
| Japanese |  50,003 |  50,003 |      26,262 |      1.90 |     1.90 |
| Chinese  | 186,552 | 165,826 |      69,526 |      2.68 |     2.39 |
| Korean   |  89,094 |  83,846 |      21,770 |      4.09 |     3.85 |
| all      | 333,073 | 307,099 |     124,497 |      2.68 |     2.47 |

(Japanese is jis0208, jis0212, and the katakana table; Chinese adds
index gb18030 ranges, 824 bytes, to gb18030 and Big5.) Split by
direction:

| table   | decode | encode before | encode after |
| ------- | -----: | ------------: | -----------: |
| gb18030 | 47,880 |        54,316 |       33,590 |
| euc_kr  | 47,500 |        41,594 |       36,346 |
| big5    | 42,040 |        41,492 |       41,492 |
| jis0208 | 16,475 |        20,310 |       20,310 |

`.rodata` of `bench-zig`: 446,006 bytes on `main`, 420,022 on `nx`.

## Runs

A rank table has, per block of 64 code points, a bit per code point and
where the block's pointers start; a code point's pointer is the one at
the count of bits below it. Large parts of the CJK indexes give
consecutive code points consecutive pointers: GBK's extension hanzi
(GBK/3 and GBK/4, 14,240 of index gb18030's 23,940 pointers) are the
unified ideographs that GB2312 lacks, in code point order, and the UHC
Hangul (8,822 of index EUC-KR's 17,048) the syllables that KS X 1001
lacks. In a block of the CJK or Hangul ranges they interleave with
GB2312's or KS X 1001's characters, which are ordered by reading or
radical and so look random. A block whose code points include such a run
(entries, not necessarily adjacent, whose pointers go up by one) needs
only the run's first pointer, plus a bit per code point saying which are
in it.

Four versions, each generated from the index alone by gen/layouts/runs.zig
(the last is the commit) and checked by test-layouts on every index:

1. **`runs`**: the longest run of every block, a second word per block
   marking it, and a lookup that ranks either among the run or among the
   rest, branching on which; plus a coarser block index (below). gb18030
   encode 26,474 bytes, EUC-KR 30,688.
2. **`rb`**: the same table, the lookup without the branch (a mask from
   the run bit selects both counts).
3. **`rc`**: `rb` with chinese_rank's block index, a u16 per 64 code
   points. gb18030 27,466 bytes, EUC-KR 31,680.
4. **`flat_runs`** (`nx` in the runs): the code points outside the run
   keep chinese_rank's bit word and lookup unchanged, and the run has a
   word of its own, read only when the first lacks the code point. A
   block keeps its run only if the run is at least half the block and not
   all of it; otherwise the run would put common characters on the
   second path, which text takes and leaves every few characters (GB2312's
   punctuation `、。`, its full-width forms). gb18030 33,590 bytes, EUC-KR
   36,346; Big5 and jis0208 have too few runs to pay for the words and
   come out as chinese_rank.

Encode, ratio to the same code with chinese_rank tables, geomean over
each operation's 44 rows (`runs` from the first run below, `rb` and `rc`
from the second, `nx` against `main` from the third):

| op                  | runs |   rb |   rc |   nx |
| ------------------- | ---: | ---: | ---: | ---: |
| GBK/EncodeUtf8      | 0.81 | 0.82 | 0.87 | 0.89 |
| GBK/EncodeUtf16     | 0.81 | 0.83 | 0.86 | 0.88 |
| gb18030/EncodeUtf8  | 0.80 | 0.81 | 0.86 | 0.90 |
| gb18030/EncodeUtf16 | 0.81 | 0.82 | 0.85 | 0.87 |
| EUC-KR/EncodeUtf8   | 0.89 | 0.84 | 0.88 | 0.99 |
| EUC-KR/EncodeUtf16  | 0.84 | 0.81 | 0.86 | 0.99 |
| Big5/EncodeUtf8     | 0.95 | 0.95 | 1.00 | 1.00 |
| Big5/EncodeUtf16    | 0.94 | 0.95 | 0.99 | 1.00 |

The encode loop is bound by its instructions, about six cycles a
character on Chinese text, so the run word's load and the extra count
show on every character when every lookup reads them (`runs`, `rb`,
`rc`); with the branch removed (`rb`) nothing changes, so it is not
mispredictions. `flat_runs` reads the run word only for code points in
runs. EUC-KR's corpus has 2 to 16 of them per 64 KiB (`①`, `〈`), so its
encode is unchanged. The GBK and gb18030 corpus is traditional Chinese,
whose `國`, `為`, `會` are GBK extension hanzi, and its `，` is in the
run of U+FF00 to U+FF3F: 18% of its characters take the second path,
hence 0.87x to 0.90x. Simplified Chinese, GB2312's own characters, would
take it far less; the corpus has none to show it.

Per call at 16 bytes, geomean ns: GBK encode from UTF-8 12.4 against
12.6, gb18030 11.8 against 12.1, EUC-KR 13.3 against 13.3; encoding_rs
57.2, 56.9, and 32.0.

**Recommendation.** EUC-KR: take it, 5,248 bytes at no measured cost.
gb18030: taken in this branch as the trade the owner's "speed and memory
count equally" asks for, 20% of gb18030's bytes for 11% of an encode
speed that stays 13x encoding_rs while the bytes are 2.4x; going back is
one word in gen/sources.zig and `just gen`. Big5 and jis0208: no runs
to take.

## A coarser block index

chinese_rank's block index is a u16 per 64 code points from U+0000:
2,048 bytes on gb18030, EUC-KR, and jis0208, and 6,086 on Big5, which
reaches U+2F8xx with plane 1 empty. The `runs` arm had a u16 per 4096
code points (the block before the chunk's first) and a u8 offset per 64,
two loads that do not depend on each other: 1,056 bytes, and 3,139 on
Big5, 5,915 saved over the four. Its cost is Big5's column of `runs`
against `rc`: 5% of encode, for one add and a select on the block
number. Not taken; a two-level index (a chunk per 4096 code points, one
more dependent load) would save 8,300 and cost more.

## Rows decode tables, measured and not taken

`rows_runs` cut each row of an index (the pointers of one lead byte) to
its columns from its first code point to its last, with a u32 per row
(where its cells start, its first column, its width), and the codecs
looked up `decodeAt(row, col)` without the multiply, so the lookup was a
row word, a window check, and a cell instead of a multiply and a cell.
Bytes, against the layouts in use:

| table   | in use |   rows |  saved |
| ------- | -----: | -----: | -----: |
| euc_kr  | 47,500 | 36,484 | 11,016 |
| big5    | 42,040 | 40,234 |  1,806 |
| jis0208 | 16,475 | 16,100 |    375 |
| jis0212 | 13,026 | 12,666 |    360 |
| gb18030 | 47,880 | 48,384 |   -504 |

Index EUC-KR's rows from lead 0xC7 have nothing in columns 0 to 95
(5,376 empty pointers), which is the saving there. Decode with them, the
`rows` arm against `runs` (the same encode tables) in the first run:
EUC-KR 0.91x to UTF-8 and 0.96x to UTF-16, Big5 0.96x and 0.92x,
Shift_JIS 0.93x and 0.93x, EUC-JP 0.99x and 0.97x, gb18030 level. The row
word's fields cost more instructions than the multiply they replace, on
the decode loop whose margin over encoding_rs is the smallest (Korean
text to UTF-8 is level with it). Not taken, and `decodeAt` went with it.

## Candidates counted and not built

- **Narrow pages.** Pages of 16 or 32 pointers whose code points lie
  within 255 of each other (GBK's extension hanzi, the UHC Hangul) could
  hold a u8 offset per pointer: gb18030's decode 37,172 bytes against
  47,880, EUC-KR's 30,228 against 47,500. It is a paged lookup plus a
  branch on the page's kind, and pages alone cost EUC-KR 5% of decode
  (korean-20261102.md).
- **Big5's plane-2 bits.** 143 of their 619 words have a bit set; a u8
  index per word would save 1,300 bytes for a load on every Big5
  character.
- **Sharing.** Across the four tables, 5 decode pages of 32 pointers and
  59 encode bit words recur, about 800 bytes; within tables, 648 encode
  words recur (534 of them all ones), but sharing them needs a u16 per
  block, which costs nearly what it saves.
- **Packed pointers.** The encode pointers in 15 bits (14 for jis0208)
  instead of 16 would save about 6,000 bytes over the four tables for a
  shift and a mask on every lookup.

## Method

The arms, each a `bench-zig` built from a worktree of this branch with
`gen/sources.zig` set and `just gen`:

- `runs`: gb18030, Big5, and EUC-KR in the first `flat_runs`, jis0208 in
  a `paged_runs` with the same encode table.
- `rows`: as `runs`, with Big5, EUC-KR, jis0208, and jis0212 in
  `rows_runs` and the codecs calling `decodeAt`.
- `rb` and `rc`: `runs` with the encode changes named above.
- `nx`: this branch's code and tables (and the Japanese fast path of
  cjk-fast-paths-20261102.md, which no encode row runs).

Each arm's tables passed test-layouts; `just oracle 20000` on the `rows`
arm found 0 mismatches in 78,777,837 comparisons. The runs:

- `BENCHTIME_MS=20 just arms="rust zig main runs rows" bench-compare 10 '/(Shift_JIS|EUC-JP|ISO-2022-JP|GBK|gb18030|Big5|EUC-KR)/'`
- `BENCHTIME_MS=20 just arms="rust zig j0 ja jb runs rb rc" bench-compare 10 '^Decode[^/]*/(Shift_JIS|EUC-JP)/' '^Encode[^/]*/(GBK|gb18030|EUC-KR|Big5)/'`
- `BENCHTIME_MS=20 just arms="rust zig main nx" bench-compare 10` with the same filter.

## Raw output

`zig build rodata` on `nx` and encoding_rs's arm, with `size -A` of
`nx`, `main`, and encoding_rs's arm (`.rodata`, `.text`):

```text
/tmp/w/arm-nx/bin/bench-zig:
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
zig-out/bin/bench-rust: encoding_rs::data, 124497 bytes
.rodata            420022   16777792
.text              551497   17223808
.rodata            446006   16777792
.text              550921   17249792
.text                435842    32848
.rodata              186652   471040
```

benchstat, `main` against `nx`, every encode row of the third run, GB/s:

```text
                                     │     main      │                  nx                   │
                                     │     GB/s      │     GB/s       vs base                │
EncodeUtf8/GBK/ascii-16                  2.638 ± 23%     2.612 ± 18%        ~ (p=0.631 n=10)
EncodeUtf8/GBK/csv-16                    2.535 ±  7%     2.636 ± 22%        ~ (p=0.353 n=10)
EncodeUtf8/GBK/invalid-16               472.6m ± 27%    506.7m ± 14%        ~ (p=0.579 n=10)
EncodeUtf8/GBK/mail-16                   2.620 ± 21%     2.623 ± 22%        ~ (p=1.000 n=10)
EncodeUtf8/GBK/mixed-16                 619.9m ± 27%    661.2m ± 13%        ~ (p=0.631 n=10)
EncodeUtf8/GBK/nonascii-16              626.4m ± 24%    490.4m ± 17%  -21.70% (p=0.000 n=10)
EncodeUtf8/GBK/subtitles-16              2.629 ± 23%     2.557 ± 27%        ~ (p=0.739 n=10)
EncodeUtf8/GBK/web-16                    2.540 ± 24%     2.537 ± 22%        ~ (p=0.684 n=10)
EncodeUtf8/GBK/ascii-64                  8.038 ±  9%     8.116 ±  3%        ~ (p=0.684 n=10)
EncodeUtf8/GBK/csv-64                    1.386 ±  6%     1.358 ± 11%        ~ (p=0.424 n=10)
EncodeUtf8/GBK/invalid-64               496.2m ±  9%    461.3m ± 12%        ~ (p=0.063 n=10)
EncodeUtf8/GBK/mail-64                   8.527 ± 20%     8.740 ± 19%        ~ (p=0.617 n=10)
EncodeUtf8/GBK/mixed-64                 514.8m ± 26%    494.2m ± 24%        ~ (p=0.218 n=10)
EncodeUtf8/GBK/nonascii-64              665.9m ± 17%    559.2m ± 23%  -16.02% (p=0.019 n=10)
EncodeUtf8/GBK/subtitles-64             973.1m ± 23%    987.5m ± 16%        ~ (p=0.796 n=10)
EncodeUtf8/GBK/web-64                    8.043 ± 13%     8.428 ±  9%        ~ (p=0.123 n=10)
EncodeUtf8/GBK/csv-256                  792.3m ± 22%    737.7m ±  1%   -6.89% (p=0.000 n=10)
EncodeUtf8/GBK/subtitles-256            756.7m ±  5%    699.5m ± 10%        ~ (p=0.052 n=10)
EncodeUtf8/GBK/ascii-256                 17.72 ± 17%     17.30 ± 19%        ~ (p=0.579 n=10)
EncodeUtf8/GBK/invalid-256              522.5m ± 14%    485.2m ± 17%        ~ (p=0.075 n=10)
EncodeUtf8/GBK/mail-256                  1.162 ± 14%     1.060 ±  9%   -8.75% (p=0.019 n=10)
EncodeUtf8/GBK/mixed-256                528.6m ± 19%    463.1m ± 12%  -12.39% (p=0.000 n=10)
EncodeUtf8/GBK/nonascii-256             709.8m ± 11%    604.9m ± 11%  -14.77% (p=0.002 n=10)
EncodeUtf8/GBK/web-256                   1.356 ± 12%     1.306 ± 10%        ~ (p=0.481 n=10)
EncodeUtf8/GBK/csv-4096                 697.2m ± 17%    610.1m ± 11%        ~ (p=0.063 n=10)
EncodeUtf8/GBK/ascii-4096                23.11 ±  3%     24.03 ± 17%   +4.02% (p=0.015 n=10)
EncodeUtf8/GBK/invalid-4096             505.9m ±  5%    496.4m ± 10%        ~ (p=0.494 n=10)
EncodeUtf8/GBK/mail-4096                783.4m ±  7%    684.4m ± 23%        ~ (p=0.075 n=10)
EncodeUtf8/GBK/mixed-4096               568.9m ± 21%    510.1m ± 15%  -10.34% (p=0.011 n=10)
EncodeUtf8/GBK/nonascii-4096            646.9m ± 11%    456.8m ± 11%  -29.39% (p=0.000 n=10)
EncodeUtf8/GBK/subtitles-4096           743.7m ± 10%    717.6m ± 14%        ~ (p=0.247 n=10)
EncodeUtf8/GBK/web-4096                 714.7m ±  8%    579.2m ± 11%  -18.95% (p=0.000 n=10)
EncodeUtf8/GBK/mail-65536               749.9m ± 12%    540.3m ± 10%  -27.96% (p=0.000 n=10)
EncodeUtf8/GBK/web-65536                647.8m ± 19%    453.7m ± 10%  -29.96% (p=0.000 n=10)
EncodeUtf8/GBK/ascii-65536               25.62 ± 20%     25.87 ±  6%        ~ (p=1.000 n=10)
EncodeUtf8/GBK/csv-65536                725.5m ± 13%    554.1m ±  6%  -23.63% (p=0.000 n=10)
EncodeUtf8/GBK/invalid-65536            292.2m ± 11%    207.1m ± 12%  -29.14% (p=0.000 n=10)
EncodeUtf8/GBK/mixed-65536              533.8m ±  3%    399.1m ±  3%  -25.24% (p=0.000 n=10)
EncodeUtf8/GBK/nonascii-65536           637.8m ± 21%    423.2m ±  7%  -33.64% (p=0.000 n=10)
EncodeUtf8/GBK/subtitles-65536          708.0m ±  7%    517.0m ±  7%  -26.97% (p=0.000 n=10)
EncodeUtf8/GBK/web-1048576              630.9m ± 15%    467.4m ± 13%  -25.91% (p=0.000 n=10)
EncodeUtf8/GBK/ascii-1048576             18.87 ± 17%     18.50 ± 20%        ~ (p=0.796 n=10)
EncodeUtf8/GBK/mixed-1048576            525.6m ± 19%    396.1m ± 18%  -24.63% (p=0.000 n=10)
EncodeUtf8/GBK/nonascii-1048576         629.0m ± 18%    467.8m ± 14%  -25.63% (p=0.000 n=10)
EncodeUtf16/GBK/ascii-16                 4.605 ± 28%     4.735 ± 21%        ~ (p=0.796 n=10)
EncodeUtf16/GBK/csv-16                   4.528 ±  3%     4.629 ±  4%        ~ (p=0.123 n=10)
EncodeUtf16/GBK/invalid-16              669.7m ±  6%    563.0m ±  8%  -15.93% (p=0.000 n=10)
EncodeUtf16/GBK/mail-16                  4.620 ±  3%     4.675 ± 15%        ~ (p=0.105 n=10)
EncodeUtf16/GBK/mixed-16               1022.2m ± 12%    957.5m ±  3%   -6.32% (p=0.002 n=10)
EncodeUtf16/GBK/nonascii-16             600.2m ±  5%    527.4m ± 12%  -12.14% (p=0.000 n=10)
EncodeUtf16/GBK/subtitles-16             4.659 ±  5%     4.632 ±  6%        ~ (p=0.684 n=10)
EncodeUtf16/GBK/web-16                   4.731 ± 19%     4.650 ± 21%        ~ (p=0.631 n=10)
EncodeUtf16/GBK/ascii-64                 14.58 ±  7%     14.46 ± 27%        ~ (p=0.971 n=10)
EncodeUtf16/GBK/csv-64                   2.898 ±  4%     2.785 ±  4%   -3.91% (p=0.035 n=10)
EncodeUtf16/GBK/invalid-64              568.1m ± 25%    552.4m ± 19%        ~ (p=0.436 n=10)
EncodeUtf16/GBK/mail-64                  15.37 ± 18%     15.36 ± 14%        ~ (p=0.631 n=10)
EncodeUtf16/GBK/mixed-64                555.4m ± 11%    525.9m ± 19%        ~ (p=0.123 n=10)
EncodeUtf16/GBK/nonascii-64             683.2m ± 12%    518.7m ± 23%  -24.09% (p=0.002 n=10)
EncodeUtf16/GBK/subtitles-64             1.618 ± 22%     1.526 ± 16%   -5.71% (p=0.023 n=10)
EncodeUtf16/GBK/web-64                   14.61 ± 18%     14.52 ±  5%        ~ (p=0.165 n=10)
EncodeUtf16/GBK/csv-256                  1.135 ± 23%     1.031 ±  6%   -9.09% (p=0.002 n=10)
EncodeUtf16/GBK/subtitles-256            1.097 ± 19%     1.074 ± 21%        ~ (p=0.393 n=10)
EncodeUtf16/GBK/ascii-256                28.65 ± 20%     29.82 ± 12%        ~ (p=0.684 n=10)
EncodeUtf16/GBK/invalid-256             572.3m ±  9%    547.6m ± 22%        ~ (p=0.218 n=10)
EncodeUtf16/GBK/mail-256                 2.447 ± 16%     2.344 ± 12%        ~ (p=0.143 n=10)
EncodeUtf16/GBK/mixed-256               503.5m ± 23%    460.8m ± 17%   -8.49% (p=0.015 n=10)
EncodeUtf16/GBK/nonascii-256            734.6m ±  9%    607.7m ± 16%  -17.28% (p=0.007 n=10)
EncodeUtf16/GBK/web-256                  2.911 ± 18%     2.917 ± 17%        ~ (p=1.000 n=10)
EncodeUtf16/GBK/csv-4096                891.0m ± 20%    784.4m ±  5%  -11.97% (p=0.000 n=10)
EncodeUtf16/GBK/ascii-4096               41.86 ±  5%     44.78 ± 16%        ~ (p=0.063 n=10)
EncodeUtf16/GBK/invalid-4096            603.9m ± 15%    554.6m ± 26%   -8.15% (p=0.043 n=10)
EncodeUtf16/GBK/mail-4096              1074.9m ± 20%    972.9m ± 22%   -9.48% (p=0.035 n=10)
EncodeUtf16/GBK/mixed-4096              551.7m ± 14%    464.5m ± 12%  -15.81% (p=0.003 n=10)
EncodeUtf16/GBK/nonascii-4096           704.3m ± 18%    565.2m ± 17%  -19.75% (p=0.009 n=10)
EncodeUtf16/GBK/subtitles-4096         1000.6m ± 17%    911.9m ± 13%        ~ (p=0.075 n=10)
EncodeUtf16/GBK/web-4096                866.3m ±  5%    753.0m ± 19%  -13.08% (p=0.011 n=10)
EncodeUtf16/GBK/mail-65536             1080.8m ± 11%    734.1m ± 24%  -32.08% (p=0.000 n=10)
EncodeUtf16/GBK/web-65536               782.1m ± 10%    496.7m ±  7%  -36.49% (p=0.000 n=10)
EncodeUtf16/GBK/ascii-65536              42.66 ± 13%     44.57 ± 21%        ~ (p=0.353 n=10)
EncodeUtf16/GBK/csv-65536              1014.2m ± 15%    851.4m ±  8%  -16.06% (p=0.000 n=10)
EncodeUtf16/GBK/invalid-65536           316.1m ± 20%    229.3m ±  8%  -27.44% (p=0.000 n=10)
EncodeUtf16/GBK/mixed-65536             467.0m ±  9%    365.8m ± 12%  -21.68% (p=0.000 n=10)
EncodeUtf16/GBK/nonascii-65536          753.7m ± 14%    406.8m ± 26%  -46.02% (p=0.000 n=10)
EncodeUtf16/GBK/subtitles-65536         991.2m ±  9%    675.8m ±  7%  -31.83% (p=0.000 n=10)
EncodeUtf16/GBK/web-1048576             748.4m ±  5%    486.0m ±  9%  -35.06% (p=0.000 n=10)
EncodeUtf16/GBK/ascii-1048576            18.14 ± 12%     18.33 ± 12%        ~ (p=0.796 n=10)
EncodeUtf16/GBK/mixed-1048576           472.3m ± 22%    375.4m ±  6%  -20.51% (p=0.000 n=10)
EncodeUtf16/GBK/nonascii-1048576        692.9m ±  9%    393.1m ± 20%  -43.28% (p=0.000 n=10)
EncodeUtf8/gb18030/ascii-16              2.536 ±  7%     2.543 ± 12%        ~ (p=0.853 n=10)
EncodeUtf8/gb18030/csv-16                2.555 ± 18%     2.541 ± 13%        ~ (p=0.853 n=10)
EncodeUtf8/gb18030/invalid-16           646.0m ± 11%    610.1m ± 21%        ~ (p=0.247 n=10)
EncodeUtf8/gb18030/mail-16               2.554 ± 25%     2.552 ±  8%        ~ (p=0.928 n=10)
EncodeUtf8/gb18030/mixed-16             639.8m ± 18%    638.0m ± 15%        ~ (p=0.724 n=10)
EncodeUtf8/gb18030/nonascii-16          674.1m ± 12%    592.9m ± 17%        ~ (p=0.105 n=10)
EncodeUtf8/gb18030/subtitles-16          2.625 ± 17%     2.565 ± 20%        ~ (p=0.796 n=10)
EncodeUtf8/gb18030/web-16                2.558 ± 18%     2.544 ± 21%        ~ (p=0.853 n=10)
EncodeUtf8/gb18030/ascii-64              7.993 ± 11%     8.171 ±  9%        ~ (p=0.353 n=10)
EncodeUtf8/gb18030/csv-64                1.392 ±  9%     1.434 ± 17%        ~ (p=0.481 n=10)
EncodeUtf8/gb18030/invalid-64           388.8m ±  9%    372.8m ±  5%   -4.12% (p=0.005 n=10)
EncodeUtf8/gb18030/mail-64               7.992 ±  7%     8.136 ±  2%        ~ (p=0.353 n=10)
EncodeUtf8/gb18030/mixed-64             521.0m ±  3%    483.9m ±  3%   -7.12% (p=0.002 n=10)
EncodeUtf8/gb18030/nonascii-64          636.4m ± 21%    553.3m ± 14%  -13.06% (p=0.004 n=10)
EncodeUtf8/gb18030/subtitles-64         954.8m ±  1%    930.1m ±  2%   -2.58% (p=0.001 n=10)
EncodeUtf8/gb18030/web-64                8.406 ±  7%     8.664 ±  6%        ~ (p=0.529 n=10)
EncodeUtf8/gb18030/csv-256              864.1m ±  8%    842.4m ± 11%        ~ (p=0.529 n=10)
EncodeUtf8/gb18030/subtitles-256        800.1m ±  8%    812.7m ± 11%        ~ (p=0.739 n=10)
EncodeUtf8/gb18030/ascii-256             17.84 ± 10%     17.26 ±  9%        ~ (p=0.739 n=10)
EncodeUtf8/gb18030/invalid-256          423.3m ± 19%    400.8m ± 21%   -5.32% (p=0.043 n=10)
EncodeUtf8/gb18030/mail-256              1.313 ± 14%     1.209 ± 10%        ~ (p=0.105 n=10)
EncodeUtf8/gb18030/mixed-256            580.6m ± 17%    504.7m ± 20%        ~ (p=0.105 n=10)
EncodeUtf8/gb18030/nonascii-256         667.9m ± 25%    575.5m ± 27%  -13.82% (p=0.029 n=10)
EncodeUtf8/gb18030/web-256               1.422 ± 13%     1.572 ± 15%        ~ (p=0.280 n=10)
EncodeUtf8/gb18030/csv-4096             710.2m ± 21%    644.9m ±  4%   -9.20% (p=0.002 n=10)
EncodeUtf8/gb18030/ascii-4096            23.06 ± 11%     23.06 ±  7%        ~ (p=0.971 n=10)
EncodeUtf8/gb18030/invalid-4096         409.7m ± 25%    424.5m ± 15%        ~ (p=0.739 n=10)
EncodeUtf8/gb18030/mail-4096            819.3m ± 19%    735.5m ± 23%  -10.23% (p=0.011 n=10)
EncodeUtf8/gb18030/mixed-4096           567.5m ±  6%    485.8m ± 17%  -14.41% (p=0.004 n=10)
EncodeUtf8/gb18030/nonascii-4096        664.9m ±  9%    554.2m ± 26%  -16.65% (p=0.011 n=10)
EncodeUtf8/gb18030/subtitles-4096       767.5m ± 23%    701.6m ± 26%        ~ (p=0.165 n=10)
EncodeUtf8/gb18030/web-4096             719.5m ± 19%    664.8m ± 17%        ~ (p=0.143 n=10)
EncodeUtf8/gb18030/mail-65536           760.5m ± 11%    558.6m ±  7%  -26.55% (p=0.000 n=10)
EncodeUtf8/gb18030/web-65536            655.2m ±  4%    472.0m ± 26%  -27.97% (p=0.000 n=10)
EncodeUtf8/gb18030/ascii-65536           25.23 ± 27%     25.31 ±  6%        ~ (p=0.971 n=10)
EncodeUtf8/gb18030/csv-65536            721.8m ± 25%    618.3m ± 24%  -14.33% (p=0.015 n=10)
EncodeUtf8/gb18030/invalid-65536        278.4m ± 23%    203.0m ± 24%  -27.10% (p=0.000 n=10)
EncodeUtf8/gb18030/mixed-65536          556.4m ± 10%    418.9m ± 21%  -24.72% (p=0.000 n=10)
EncodeUtf8/gb18030/nonascii-65536       706.4m ± 16%    453.7m ± 24%  -35.77% (p=0.000 n=10)
EncodeUtf8/gb18030/subtitles-65536      726.4m ± 13%    538.2m ± 11%  -25.90% (p=0.000 n=10)
EncodeUtf8/gb18030/web-1048576          654.5m ±  7%    473.0m ± 10%  -27.74% (p=0.000 n=10)
EncodeUtf8/gb18030/ascii-1048576         18.81 ± 16%     19.44 ± 10%        ~ (p=0.912 n=10)
EncodeUtf8/gb18030/mixed-1048576        528.0m ± 12%    387.9m ±  6%  -26.53% (p=0.000 n=10)
EncodeUtf8/gb18030/nonascii-1048576     641.8m ± 11%    436.7m ±  9%  -31.95% (p=0.000 n=10)
EncodeUtf16/gb18030/ascii-16             4.782 ± 15%     4.660 ± 10%        ~ (p=0.739 n=10)
EncodeUtf16/gb18030/csv-16               4.723 ±  8%     4.642 ±  6%        ~ (p=0.218 n=10)
EncodeUtf16/gb18030/invalid-16          917.4m ±  9%    788.1m ±  9%  -14.10% (p=0.029 n=10)
EncodeUtf16/gb18030/mail-16              4.717 ±  7%     4.638 ±  6%        ~ (p=0.739 n=10)
EncodeUtf16/gb18030/mixed-16           1041.3m ±  7%    964.8m ±  5%   -7.35% (p=0.002 n=10)
EncodeUtf16/gb18030/nonascii-16         606.0m ±  8%    563.8m ± 16%   -6.96% (p=0.011 n=10)
EncodeUtf16/gb18030/subtitles-16         4.695 ±  9%     4.617 ± 14%        ~ (p=0.247 n=10)
EncodeUtf16/gb18030/web-16               4.908 ±  6%     4.862 ±  6%        ~ (p=0.700 n=10)
EncodeUtf16/gb18030/ascii-64             15.18 ±  8%     14.54 ± 12%        ~ (p=0.190 n=10)
EncodeUtf16/gb18030/csv-64               2.872 ± 10%     2.873 ± 10%        ~ (p=0.739 n=10)
EncodeUtf16/gb18030/invalid-64          483.6m ± 16%    456.8m ± 20%   -5.55% (p=0.035 n=10)
EncodeUtf16/gb18030/mail-64              14.71 ± 20%     14.97 ± 19%        ~ (p=0.796 n=10)
EncodeUtf16/gb18030/mixed-64            606.9m ± 10%    542.1m ± 18%        ~ (p=0.089 n=10)
EncodeUtf16/gb18030/nonascii-64         632.0m ± 21%    502.9m ± 21%  -20.42% (p=0.001 n=10)
EncodeUtf16/gb18030/subtitles-64         1.745 ±  7%     1.722 ± 13%        ~ (p=0.739 n=10)
EncodeUtf16/gb18030/web-64               14.60 ± 17%     14.59 ±  9%        ~ (p=0.631 n=10)
EncodeUtf16/gb18030/csv-256              1.181 ± 23%     1.097 ± 14%   -7.12% (p=0.005 n=10)
EncodeUtf16/gb18030/subtitles-256        1.206 ± 14%     1.076 ± 19%        ~ (p=0.105 n=10)
EncodeUtf16/gb18030/ascii-256            27.54 ± 12%     30.06 ± 13%   +9.18% (p=0.043 n=10)
EncodeUtf16/gb18030/invalid-256         549.8m ± 19%    534.2m ± 13%        ~ (p=0.280 n=10)
EncodeUtf16/gb18030/mail-256             2.277 ± 12%     2.192 ± 14%        ~ (p=0.086 n=10)
EncodeUtf16/gb18030/mixed-256           503.2m ± 17%    443.9m ± 21%  -11.78% (p=0.035 n=10)
EncodeUtf16/gb18030/nonascii-256        696.8m ± 17%    571.5m ± 17%  -17.98% (p=0.000 n=10)
EncodeUtf16/gb18030/web-256              2.809 ± 19%     2.815 ± 21%        ~ (p=0.579 n=10)
EncodeUtf16/gb18030/csv-4096            894.0m ± 15%    804.6m ± 10%   -9.99% (p=0.005 n=10)
EncodeUtf16/gb18030/ascii-4096           43.58 ± 16%     42.77 ± 11%        ~ (p=0.912 n=10)
EncodeUtf16/gb18030/invalid-4096        521.2m ± 10%    468.1m ± 13%  -10.19% (p=0.043 n=10)
EncodeUtf16/gb18030/mail-4096          1077.3m ± 13%    972.5m ±  3%   -9.74% (p=0.006 n=10)
EncodeUtf16/gb18030/mixed-4096          492.0m ± 23%    458.5m ± 15%        ~ (p=0.063 n=10)
EncodeUtf16/gb18030/nonascii-4096       766.7m ±  9%    604.6m ± 18%  -21.14% (p=0.001 n=10)
EncodeUtf16/gb18030/subtitles-4096     1005.2m ± 12%    968.3m ± 16%        ~ (p=0.105 n=10)
EncodeUtf16/gb18030/web-4096            919.1m ± 13%    768.8m ±  7%  -16.36% (p=0.000 n=10)
EncodeUtf16/gb18030/mail-65536         1075.0m ± 13%    733.9m ± 12%  -31.73% (p=0.000 n=10)
EncodeUtf16/gb18030/web-65536           766.3m ± 12%    494.9m ± 10%  -35.41% (p=0.000 n=10)
EncodeUtf16/gb18030/ascii-65536          41.73 ± 23%     42.35 ± 29%        ~ (p=0.143 n=10)
EncodeUtf16/gb18030/csv-65536           942.1m ± 11%    816.8m ± 13%  -13.30% (p=0.001 n=10)
EncodeUtf16/gb18030/invalid-65536       288.7m ± 19%    212.9m ± 20%  -26.24% (p=0.000 n=10)
EncodeUtf16/gb18030/mixed-65536         489.5m ± 21%    372.9m ± 19%  -23.83% (p=0.000 n=10)
EncodeUtf16/gb18030/nonascii-65536      704.9m ± 27%    402.7m ± 28%  -42.88% (p=0.000 n=10)
EncodeUtf16/gb18030/subtitles-65536    1044.9m ± 19%    714.2m ± 21%  -31.65% (p=0.000 n=10)
EncodeUtf16/gb18030/web-1048576         822.3m ± 15%    489.1m ± 21%  -40.52% (p=0.000 n=10)
EncodeUtf16/gb18030/ascii-1048576        19.20 ±  9%     18.98 ± 11%        ~ (p=0.631 n=10)
EncodeUtf16/gb18030/mixed-1048576       458.4m ±  5%    356.8m ±  5%  -22.16% (p=0.000 n=10)
EncodeUtf16/gb18030/nonascii-1048576    707.8m ± 19%    403.1m ± 10%  -43.06% (p=0.000 n=10)
EncodeUtf8/Big5/ascii-16                 2.558 ± 18%     2.500 ± 20%        ~ (p=0.579 n=10)
EncodeUtf8/Big5/csv-16                   2.444 ± 15%     2.492 ± 15%        ~ (p=0.393 n=10)
EncodeUtf8/Big5/invalid-16              384.3m ± 13%    379.6m ± 12%        ~ (p=0.165 n=10)
EncodeUtf8/Big5/mail-16                  2.478 ± 20%     2.569 ± 17%        ~ (p=0.739 n=10)
EncodeUtf8/Big5/mixed-16                589.6m ± 20%    583.6m ± 25%        ~ (p=0.754 n=10)
EncodeUtf8/Big5/nonascii-16             590.1m ±  2%    598.1m ± 26%   +1.36% (p=0.027 n=10)
EncodeUtf8/Big5/subtitles-16             2.436 ± 14%     2.393 ± 17%        ~ (p=0.853 n=10)
EncodeUtf8/Big5/web-16                   2.428 ± 21%     2.398 ± 20%        ~ (p=0.353 n=10)
EncodeUtf8/Big5/ascii-64                 7.653 ± 26%     7.576 ± 20%        ~ (p=0.393 n=10)
EncodeUtf8/Big5/csv-64                   1.371 ±  7%     1.470 ±  8%        ~ (p=0.128 n=10)
EncodeUtf8/Big5/invalid-64              457.2m ± 15%    455.5m ±  8%        ~ (p=0.725 n=10)
EncodeUtf8/Big5/mail-64                  7.947 ± 21%     7.984 ± 21%        ~ (p=0.700 n=10)
EncodeUtf8/Big5/mixed-64                588.6m ± 18%    565.1m ± 21%        ~ (p=0.393 n=10)
EncodeUtf8/Big5/nonascii-64             644.3m ± 25%    644.2m ± 24%        ~ (p=0.684 n=10)
EncodeUtf8/Big5/subtitles-64            977.9m ± 24%    965.9m ±  6%        ~ (p=0.579 n=10)
EncodeUtf8/Big5/web-64                   7.591 ± 19%     7.858 ± 20%        ~ (p=0.075 n=10)
EncodeUtf8/Big5/subtitles-256           826.4m ± 24%    864.9m ± 20%        ~ (p=0.404 n=10)
EncodeUtf8/Big5/ascii-256                16.67 ± 10%     16.23 ±  7%        ~ (p=0.218 n=10)
EncodeUtf8/Big5/csv-256                 851.7m ± 19%    849.2m ± 19%        ~ (p=0.481 n=10)
EncodeUtf8/Big5/invalid-256             427.9m ±  9%    425.0m ±  8%        ~ (p=0.579 n=10)
EncodeUtf8/Big5/mail-256                 1.385 ±  5%     1.436 ± 23%        ~ (p=0.280 n=10)
EncodeUtf8/Big5/mixed-256               566.1m ±  5%    544.0m ± 26%        ~ (p=0.579 n=10)
EncodeUtf8/Big5/nonascii-256            673.9m ± 10%    702.8m ± 22%        ~ (p=0.063 n=10)
EncodeUtf8/Big5/web-256                  1.427 ±  5%     1.460 ±  4%        ~ (p=0.393 n=10)
EncodeUtf8/Big5/csv-4096                785.1m ± 14%    780.2m ±  6%        ~ (p=0.436 n=10)
EncodeUtf8/Big5/ascii-4096               24.59 ±  6%     22.70 ±  6%   -7.66% (p=0.029 n=10)
EncodeUtf8/Big5/invalid-4096            396.1m ±  4%    390.4m ± 18%        ~ (p=0.289 n=10)
EncodeUtf8/Big5/mail-4096               894.8m ± 23%    896.9m ±  7%        ~ (p=0.986 n=10)
EncodeUtf8/Big5/mixed-4096              564.8m ± 13%    544.1m ± 16%        ~ (p=0.315 n=10)
EncodeUtf8/Big5/nonascii-4096           694.0m ± 13%    692.5m ± 24%        ~ (p=0.971 n=10)
EncodeUtf8/Big5/subtitles-4096          771.5m ±  5%    786.1m ± 11%        ~ (p=0.481 n=10)
EncodeUtf8/Big5/web-4096                762.7m ± 17%    765.5m ±  8%        ~ (p=0.955 n=10)
EncodeUtf8/Big5/csv-65536               729.1m ± 22%    723.4m ± 10%        ~ (p=0.529 n=10)
EncodeUtf8/Big5/subtitles-65536         770.8m ± 21%    785.7m ± 19%        ~ (p=0.739 n=10)
EncodeUtf8/Big5/web-65536               688.2m ± 26%    692.3m ± 13%        ~ (p=0.617 n=10)
EncodeUtf8/Big5/ascii-65536              25.37 ± 27%     25.53 ± 11%        ~ (p=0.971 n=10)
EncodeUtf8/Big5/invalid-65536           230.3m ±  6%    226.1m ±  9%        ~ (p=0.138 n=10)
EncodeUtf8/Big5/mail-65536              845.2m ±  6%    848.7m ±  6%        ~ (p=0.353 n=10)
EncodeUtf8/Big5/mixed-65536             563.6m ±  9%    547.5m ±  6%        ~ (p=0.218 n=10)
EncodeUtf8/Big5/nonascii-65536          712.6m ± 23%    695.8m ± 25%        ~ (p=0.954 n=10)
EncodeUtf8/Big5/ascii-1048576            19.27 ± 16%     18.45 ± 20%        ~ (p=0.912 n=10)
EncodeUtf8/Big5/mixed-1048576           561.1m ± 20%    552.4m ± 19%        ~ (p=0.529 n=10)
EncodeUtf8/Big5/nonascii-1048576        686.2m ± 19%    704.5m ± 14%        ~ (p=0.756 n=10)
EncodeUtf8/Big5/web-1048576             771.9m ± 13%    754.3m ± 15%        ~ (p=0.631 n=10)
EncodeUtf16/Big5/ascii-16                4.932 ± 20%     4.795 ± 22%        ~ (p=0.436 n=10)
EncodeUtf16/Big5/csv-16                  4.647 ±  6%     4.757 ± 15%        ~ (p=0.684 n=10)
EncodeUtf16/Big5/invalid-16             378.9m ±  6%    378.2m ±  8%        ~ (p=0.869 n=10)
EncodeUtf16/Big5/mail-16                 4.650 ± 12%     4.726 ±  8%        ~ (p=0.912 n=10)
EncodeUtf16/Big5/mixed-16               936.4m ± 13%   1032.4m ± 13%  +10.25% (p=0.029 n=10)
EncodeUtf16/Big5/nonascii-16            692.4m ± 21%    675.2m ± 20%        ~ (p=0.853 n=10)
EncodeUtf16/Big5/subtitles-16            4.664 ± 12%     4.693 ± 10%        ~ (p=0.739 n=10)
EncodeUtf16/Big5/web-16                  4.659 ± 12%     4.661 ± 11%        ~ (p=0.853 n=10)
EncodeUtf16/Big5/ascii-64                14.96 ± 20%     14.46 ± 24%        ~ (p=0.739 n=10)
EncodeUtf16/Big5/csv-64                  2.980 ± 28%     2.967 ± 27%        ~ (p=0.436 n=10)
EncodeUtf16/Big5/invalid-64             684.1m ± 21%    682.4m ± 22%        ~ (p=0.971 n=10)
EncodeUtf16/Big5/mail-64                 14.57 ± 18%     14.82 ± 15%        ~ (p=0.912 n=10)
EncodeUtf16/Big5/mixed-64               554.7m ± 14%    574.5m ± 11%        ~ (p=0.353 n=10)
EncodeUtf16/Big5/nonascii-64            726.3m ± 20%    715.1m ± 18%        ~ (p=0.796 n=10)
EncodeUtf16/Big5/subtitles-64            1.790 ±  8%     1.746 ± 10%        ~ (p=0.739 n=10)
EncodeUtf16/Big5/web-64                  14.64 ±  8%     14.06 ±  5%        ~ (p=0.123 n=10)
EncodeUtf16/Big5/subtitles-256           1.278 ±  9%     1.264 ± 11%        ~ (p=0.912 n=10)
EncodeUtf16/Big5/ascii-256               29.44 ±  9%     29.27 ±  7%        ~ (p=0.796 n=10)
EncodeUtf16/Big5/csv-256                 1.316 ± 14%     1.207 ±  8%   -8.28% (p=0.005 n=10)
EncodeUtf16/Big5/invalid-256            541.5m ±  6%    540.5m ±  7%        ~ (p=1.000 n=10)
EncodeUtf16/Big5/mail-256                3.156 ± 15%     2.974 ± 19%        ~ (p=0.353 n=10)
EncodeUtf16/Big5/mixed-256              523.7m ± 18%    570.8m ± 14%        ~ (p=0.739 n=10)
EncodeUtf16/Big5/nonascii-256           802.8m ± 18%    831.8m ± 13%        ~ (p=0.436 n=10)
EncodeUtf16/Big5/web-256                 3.265 ± 23%     3.108 ± 26%        ~ (p=0.218 n=10)
EncodeUtf16/Big5/csv-4096               982.0m ±  3%   1011.0m ±  7%        ~ (p=0.105 n=10)
EncodeUtf16/Big5/ascii-4096              44.35 ± 17%     39.22 ± 10%  -11.57% (p=0.011 n=10)
EncodeUtf16/Big5/invalid-4096           500.6m ±  9%    519.0m ± 18%        ~ (p=0.912 n=10)
EncodeUtf16/Big5/mail-4096               1.526 ±  9%     1.512 ±  9%        ~ (p=0.811 n=10)
EncodeUtf16/Big5/mixed-4096             486.9m ±  8%    471.4m ± 27%        ~ (p=0.971 n=10)
EncodeUtf16/Big5/nonascii-4096          836.0m ± 16%    813.4m ±  9%        ~ (p=0.280 n=10)
EncodeUtf16/Big5/subtitles-4096          1.155 ± 18%     1.120 ± 15%        ~ (p=0.481 n=10)
EncodeUtf16/Big5/web-4096               994.4m ± 23%    993.4m ±  8%        ~ (p=0.698 n=10)
EncodeUtf16/Big5/csv-65536              975.0m ± 14%    988.9m ± 20%        ~ (p=0.529 n=10)
EncodeUtf16/Big5/subtitles-65536         1.152 ±  8%     1.124 ± 16%        ~ (p=1.000 n=10)
EncodeUtf16/Big5/web-65536              882.0m ± 14%    883.4m ± 24%        ~ (p=0.725 n=10)
EncodeUtf16/Big5/ascii-65536             41.25 ± 11%     41.03 ± 26%        ~ (p=0.853 n=10)
EncodeUtf16/Big5/invalid-65536          251.2m ± 12%    261.3m ± 15%        ~ (p=0.288 n=10)
EncodeUtf16/Big5/mail-65536              1.393 ± 28%     1.345 ± 30%        ~ (p=0.280 n=10)
EncodeUtf16/Big5/mixed-65536            468.2m ± 19%    462.9m ±  9%        ~ (p=0.063 n=10)
EncodeUtf16/Big5/nonascii-65536         781.2m ± 21%    779.2m ± 27%        ~ (p=0.912 n=10)
EncodeUtf16/Big5/ascii-1048576           17.18 ±  7%     17.55 ±  9%        ~ (p=0.971 n=10)
EncodeUtf16/Big5/mixed-1048576          460.6m ± 13%    503.6m ± 16%        ~ (p=0.123 n=10)
EncodeUtf16/Big5/nonascii-1048576       789.4m ± 23%    836.0m ± 16%        ~ (p=0.280 n=10)
EncodeUtf16/Big5/web-1048576            852.1m ± 25%    934.3m ± 14%        ~ (p=0.631 n=10)
EncodeUtf8/EUC-KR/ascii-16               2.440 ±  6%     2.431 ± 12%        ~ (p=0.393 n=10)
EncodeUtf8/EUC-KR/csv-16                 2.446 ± 18%     2.433 ± 15%        ~ (p=0.631 n=10)
EncodeUtf8/EUC-KR/invalid-16            570.8m ± 12%    562.8m ± 10%        ~ (p=0.393 n=10)
EncodeUtf8/EUC-KR/mail-16                2.439 ± 22%     2.412 ± 22%        ~ (p=0.143 n=10)
EncodeUtf8/EUC-KR/mixed-16              484.3m ± 12%    467.8m ±  9%        ~ (p=0.089 n=10)
EncodeUtf8/EUC-KR/nonascii-16           473.8m ± 13%    502.3m ±  8%        ~ (p=0.869 n=10)
EncodeUtf8/EUC-KR/subtitles-16           2.435 ±  5%     2.437 ± 26%        ~ (p=0.617 n=10)
EncodeUtf8/EUC-KR/web-16                 2.533 ± 23%     2.660 ± 17%        ~ (p=0.579 n=10)
EncodeUtf8/EUC-KR/csv-64                 1.213 ± 21%     1.189 ± 22%        ~ (p=0.247 n=10)
EncodeUtf8/EUC-KR/ascii-64               7.732 ± 11%     7.586 ± 12%        ~ (p=0.280 n=10)
EncodeUtf8/EUC-KR/invalid-64            465.1m ± 18%    447.1m ± 13%   -3.86% (p=0.011 n=10)
EncodeUtf8/EUC-KR/mail-64                8.203 ±  6%     7.821 ±  9%        ~ (p=0.165 n=10)
EncodeUtf8/EUC-KR/mixed-64              480.2m ± 18%    481.4m ± 20%        ~ (p=0.615 n=10)
EncodeUtf8/EUC-KR/nonascii-64           529.4m ± 20%    516.3m ± 22%        ~ (p=0.105 n=10)
EncodeUtf8/EUC-KR/subtitles-64          873.0m ±  7%    857.6m ± 21%        ~ (p=0.061 n=10)
EncodeUtf8/EUC-KR/web-64                 7.735 ± 12%     7.626 ±  9%        ~ (p=0.143 n=10)
EncodeUtf8/EUC-KR/csv-256               698.0m ±  6%    665.6m ± 15%        ~ (p=0.315 n=10)
EncodeUtf8/EUC-KR/ascii-256              17.89 ±  6%     17.81 ± 18%        ~ (p=0.853 n=10)
EncodeUtf8/EUC-KR/invalid-256           492.5m ±  6%    481.1m ± 14%        ~ (p=0.306 n=10)
EncodeUtf8/EUC-KR/mail-256               1.221 ±  7%     1.232 ±  7%        ~ (p=0.971 n=10)
EncodeUtf8/EUC-KR/mixed-256             479.8m ±  9%    480.7m ± 10%        ~ (p=0.739 n=10)
EncodeUtf8/EUC-KR/nonascii-256          512.5m ± 11%    508.5m ± 24%        ~ (p=0.684 n=10)
EncodeUtf8/EUC-KR/subtitles-256         668.0m ±  9%    692.3m ±  7%        ~ (p=0.853 n=10)
EncodeUtf8/EUC-KR/web-256                1.498 ±  7%     1.496 ±  7%        ~ (p=0.631 n=10)
EncodeUtf8/EUC-KR/subtitles-4096        704.2m ±  9%    672.0m ± 10%        ~ (p=0.529 n=10)
EncodeUtf8/EUC-KR/ascii-4096             22.59 ± 27%     22.88 ±  2%        ~ (p=0.143 n=10)
EncodeUtf8/EUC-KR/csv-4096              591.8m ±  5%    571.5m ± 29%        ~ (p=0.481 n=10)
EncodeUtf8/EUC-KR/invalid-4096          431.7m ± 23%    410.8m ± 20%        ~ (p=0.086 n=10)
EncodeUtf8/EUC-KR/mail-4096             753.1m ± 12%    823.3m ± 14%        ~ (p=0.684 n=10)
EncodeUtf8/EUC-KR/mixed-4096            488.2m ±  9%    501.6m ±  8%        ~ (p=0.796 n=10)
EncodeUtf8/EUC-KR/nonascii-4096         526.8m ± 14%    495.2m ± 19%        ~ (p=0.315 n=10)
EncodeUtf8/EUC-KR/web-4096              749.1m ±  9%    731.8m ±  8%        ~ (p=0.436 n=10)
EncodeUtf8/EUC-KR/ascii-65536            25.26 ±  9%     25.75 ± 14%        ~ (p=0.280 n=10)
EncodeUtf8/EUC-KR/csv-65536             588.0m ±  6%    547.8m ± 11%        ~ (p=0.063 n=10)
EncodeUtf8/EUC-KR/invalid-65536         260.2m ± 19%    268.0m ± 14%        ~ (p=1.000 n=10)
EncodeUtf8/EUC-KR/mail-65536            577.2m ± 15%    558.7m ±  8%        ~ (p=0.218 n=10)
EncodeUtf8/EUC-KR/mixed-65536           432.6m ± 12%    443.8m ±  7%        ~ (p=0.853 n=10)
EncodeUtf8/EUC-KR/nonascii-65536        462.7m ±  4%    456.6m ± 13%        ~ (p=0.912 n=10)
EncodeUtf8/EUC-KR/subtitles-65536       522.5m ± 18%    539.4m ± 15%        ~ (p=0.739 n=10)
EncodeUtf8/EUC-KR/web-65536             545.5m ± 26%    544.6m ± 23%        ~ (p=0.529 n=10)
EncodeUtf8/EUC-KR/ascii-1048576          20.84 ± 14%     20.43 ± 10%        ~ (p=0.631 n=10)
EncodeUtf8/EUC-KR/mixed-1048576         464.1m ± 11%    453.2m ± 15%        ~ (p=0.971 n=10)
EncodeUtf8/EUC-KR/nonascii-1048576      466.8m ± 21%    469.5m ± 22%        ~ (p=0.853 n=10)
EncodeUtf8/EUC-KR/web-1048576           514.8m ± 18%    507.5m ± 27%        ~ (p=0.481 n=10)
EncodeUtf16/EUC-KR/ascii-16              4.668 ± 12%     4.837 ±  8%        ~ (p=1.000 n=10)
EncodeUtf16/EUC-KR/csv-16                4.695 ± 16%     4.836 ± 13%        ~ (p=0.579 n=10)
EncodeUtf16/EUC-KR/invalid-16           797.2m ± 13%    795.3m ± 13%        ~ (p=0.684 n=10)
EncodeUtf16/EUC-KR/mail-16               4.659 ±  6%     4.758 ± 20%        ~ (p=0.481 n=10)
EncodeUtf16/EUC-KR/mixed-16              1.141 ± 19%     1.160 ± 14%        ~ (p=0.971 n=10)
EncodeUtf16/EUC-KR/nonascii-16          810.1m ± 16%    827.8m ± 16%        ~ (p=0.393 n=10)
EncodeUtf16/EUC-KR/subtitles-16          5.074 ± 17%     5.520 ± 18%        ~ (p=0.739 n=10)
EncodeUtf16/EUC-KR/web-16                4.854 ±  6%     4.629 ±  1%        ~ (p=0.105 n=10)
EncodeUtf16/EUC-KR/csv-64                3.444 ± 12%     3.369 ± 17%        ~ (p=0.516 n=10)
EncodeUtf16/EUC-KR/ascii-64              14.18 ± 20%     14.57 ± 15%        ~ (p=0.912 n=10)
EncodeUtf16/EUC-KR/invalid-64           678.2m ±  9%    670.1m ± 22%        ~ (p=0.579 n=10)
EncodeUtf16/EUC-KR/mail-64               14.52 ± 18%     13.88 ± 23%        ~ (p=0.280 n=10)
EncodeUtf16/EUC-KR/mixed-64             616.4m ± 14%    606.4m ± 19%        ~ (p=0.631 n=10)
EncodeUtf16/EUC-KR/nonascii-64          785.7m ± 19%    835.0m ± 12%        ~ (p=0.853 n=10)
EncodeUtf16/EUC-KR/subtitles-64          2.505 ±  7%     2.497 ± 10%        ~ (p=0.631 n=10)
EncodeUtf16/EUC-KR/web-64                14.18 ± 12%     14.01 ± 17%        ~ (p=0.684 n=10)
EncodeUtf16/EUC-KR/csv-256               1.305 ± 12%     1.291 ± 24%        ~ (p=0.971 n=10)
EncodeUtf16/EUC-KR/ascii-256             28.64 ± 21%     27.77 ±  6%        ~ (p=0.165 n=10)
EncodeUtf16/EUC-KR/invalid-256          729.1m ± 17%    729.2m ± 14%        ~ (p=0.684 n=10)
EncodeUtf16/EUC-KR/mail-256              2.841 ±  9%     2.827 ± 11%        ~ (p=0.436 n=10)
EncodeUtf16/EUC-KR/mixed-256            559.1m ± 11%    549.1m ± 11%        ~ (p=0.353 n=10)
EncodeUtf16/EUC-KR/nonascii-256         875.8m ± 17%    860.2m ± 21%        ~ (p=0.165 n=10)
EncodeUtf16/EUC-KR/subtitles-256         1.269 ± 12%     1.242 ± 16%        ~ (p=0.436 n=10)
EncodeUtf16/EUC-KR/web-256               3.329 ± 13%     3.355 ± 15%        ~ (p=0.436 n=10)
EncodeUtf16/EUC-KR/subtitles-4096        1.170 ±  9%     1.148 ± 10%   -1.91% (p=0.043 n=10)
EncodeUtf16/EUC-KR/ascii-4096            39.74 ±  7%     39.56 ± 12%        ~ (p=0.247 n=10)
EncodeUtf16/EUC-KR/csv-4096             965.6m ±  6%    941.4m ± 27%        ~ (p=0.631 n=10)
EncodeUtf16/EUC-KR/invalid-4096         545.8m ± 15%    527.0m ± 18%        ~ (p=0.912 n=10)
EncodeUtf16/EUC-KR/mail-4096             1.354 ± 16%     1.303 ± 19%        ~ (p=0.393 n=10)
EncodeUtf16/EUC-KR/mixed-4096           527.6m ± 12%    512.3m ±  7%        ~ (p=0.280 n=10)
EncodeUtf16/EUC-KR/nonascii-4096        920.2m ± 10%    918.8m ±  7%        ~ (p=0.579 n=10)
EncodeUtf16/EUC-KR/web-4096              1.389 ± 21%     1.338 ± 23%        ~ (p=0.436 n=10)
EncodeUtf16/EUC-KR/ascii-65536           42.71 ± 23%     41.13 ± 27%        ~ (p=0.481 n=10)
EncodeUtf16/EUC-KR/csv-65536            857.3m ± 19%    831.4m ± 26%        ~ (p=0.529 n=10)
EncodeUtf16/EUC-KR/invalid-65536        268.1m ± 20%    272.4m ± 10%        ~ (p=0.515 n=10)
EncodeUtf16/EUC-KR/mail-65536           876.8m ± 18%    879.4m ± 15%        ~ (p=0.684 n=10)
EncodeUtf16/EUC-KR/mixed-65536          483.4m ± 20%    482.1m ± 20%        ~ (p=0.811 n=10)
EncodeUtf16/EUC-KR/nonascii-65536       904.6m ± 22%    930.4m ± 15%        ~ (p=0.912 n=10)
EncodeUtf16/EUC-KR/subtitles-65536      784.5m ±  1%    765.1m ±  3%        ~ (p=0.075 n=10)
EncodeUtf16/EUC-KR/web-65536            873.8m ±  3%    867.6m ±  2%   -0.72% (p=0.001 n=10)
EncodeUtf16/EUC-KR/ascii-1048576         17.55 ±  8%     17.31 ±  5%        ~ (p=0.853 n=10)
EncodeUtf16/EUC-KR/mixed-1048576        487.0m ± 22%    498.4m ± 13%        ~ (p=0.699 n=10)
EncodeUtf16/EUC-KR/nonascii-1048576     890.8m ± 12%    875.5m ± 18%        ~ (p=0.579 n=10)
EncodeUtf16/EUC-KR/web-1048576          808.4m ± 27%    800.1m ± 11%        ~ (p=0.143 n=10)
geomean                                  1.479           1.388         -6.12%
```
