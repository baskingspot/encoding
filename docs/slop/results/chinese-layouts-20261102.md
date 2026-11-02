# Chinese table layouts and encoder lookups (plan decisions 1 and 2), 2026-11-02

Plan decision 1 is the layout of the CJK tables, decision 2 the encoder's
reverse lookup. Both are measured here on index gb18030 and index Big5, the
Chinese family's tables, on the codecs of `63b0159`, against encoding_rs
0.8.44: decode and encode speed on the corpus and its synthetic shapes from
16 bytes to 64 KiB, and the bytes the tables take.

Headline: `chinese_rank` is the recommendation, and the committed tables
use it. Decode is a flat u16 array by pointer with a bit per pointer for
code points in plane 2; encode is a rank table (a bit per code point, a
u16 base per 64 code points, the pointers in code point order). Over the
44 gb18030 and 44 Big5 rows of each direction, geomean against encoding_rs:
decode 1.35x (gb18030 to UTF-8), 1.46x (to UTF-16), 1.07x and 1.12x
(Big5); encode 14.8x and 18.7x (gb18030 from UTF-8 and UTF-16), 12.4x and
15.2x (Big5). The tables take 102,196 bytes for gb18030 and 83,532 for
Big5, plus 824 for the gb18030 ranges: 186,552 bytes against `flat`'s
311,506, and against encoding_rs's 69,526 (29,490 + 40,036), which serve
both directions because its encoders search the decode tables.

The memory-first alternative is `chinese_scan`: the same decode tables and
no encode table, 90,744 bytes in all, with decode unchanged and encode at
1.0x (gb18030) and 2.2x (Big5) encoding_rs. That is the owner's choice
between table bytes and encode speed; see the recommendation.

## The layouts

Each is a generator under `gen/layouts/` that writes the same interface
(`decode(pointer) ?u21`, `encode(cp) ?u16`), so the codecs do not change
between them. They were built from halves in `gen/layouts/chinese_parts.zig`;
only `chinese_rank` stays in the tree, and `git log -- gen/layouts/chinese_parts.zig`
finds the others.

| Layout           | Decode table                                                                                                                                                                                                     | Encode lookup                                                                                                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flat` (wave 0)  | an array by pointer, u16 (u32 for an index with code points above U+FFFF, as Big5)                                                                                                                               | every code point sorted, with its pointer, bisection                                                                                                                                   |
| `chinese_ranged` | runs of pointers whose code points go up by one stored as a start and a code point, the rest flat; bisection over the segment starts (the shortest run worth a segment is chosen per index for the fewest bytes) | the same in reverse: runs where the pointer goes up with the code point, as a start code point, pointer, and length, bisection                                                         |
| `chinese_hash`   | flat u16, with a bit per pointer marking code points in plane 2 (Big5's HKSCS)                                                                                                                                   | a perfect hash: three code points a bucket, an 8-bit pilot each, the fullest table that places (85–90%), slots holding the u16 pointer, checked by decoding it                         |
| `chinese_rank`   | as `chinese_hash`                                                                                                                                                                                                | a bit per code point in blocks of 64, a u16 block index for each 64 code points, and the pointers in code point order: the pointer is at the block's base plus the count of bits below |
| `chinese_paged`  | pages of 32 pointers: a page whose code points lie within 255 of each other is a base and a byte each, any other u16 (with the plane-2 bit), identical pages shared; a u32 per page says which                   | as `chinese_rank`                                                                                                                                                                      |
| `chinese_scan`   | as `chinese_hash`                                                                                                                                                                                                | none: a 32-lane vector search of the decode table for the first pointer with the code point (the last for Big5's six), as the standard defines the index pointer and encoding_rs does  |

`flat` is measured with a one-line change to its generator (requested
below): its `decode` returned `if (cp == 0) null else @intCast(cp)`, which
LLVM lowers as a select between a stack temporary and a constant null
followed by a load, a store-forwarding stall on every character. With the
change, gb18030 decode of pure Chinese to UTF-16 goes from 227 to 680 MB/s
on the same table. Every Chinese layout returns early instead.

## Bytes

The static data each layout's generated file declares, per index, in bytes
(decode + encode), counted from the generated arrays. `test-layouts` builds
every layout on every index, so the Japanese and Korean indexes are here
too. The gb18030 ranges table (824 bytes) is the same under every layout
and is not counted.

| index                |                   flat |         chinese_ranged |           chinese_hash |           chinese_rank |         chinese_paged |      chinese_scan |
| -------------------- | ---------------------: | ---------------------: | ---------------------: | ---------------------: | --------------------: | ----------------: |
| gb18030              | 143636 (47880 + 95756) |  85076 (33296 + 51780) | 111534 (47880 + 63654) | 102196 (47880 + 54316) | 88608 (34292 + 54316) | 47880 (47880 + 0) |
| big5                 | 167046 (79128 + 87918) | 136199 (41216 + 94983) |  79855 (42040 + 37815) |  83532 (42040 + 41492) | 83344 (41852 + 41492) | 42040 (42040 + 0) |
| jis0208              |  51512 (22208 + 29304) |  55267 (21592 + 33675) |  41115 (22208 + 18907) |  42518 (22208 + 20310) | 36162 (15852 + 20310) | 22208 (22208 + 0) |
| jis0208_shift_jis    |  51512 (22208 + 29304) |  55267 (21592 + 33675) |  41115 (22208 + 18907) |  42518 (22208 + 20310) | 36162 (15852 + 20310) | 22208 (22208 + 0) |
| jis0212              |      14422 (14422 + 0) |      14392 (14392 + 0) |      14422 (14422 + 0) |      14422 (14422 + 0) |       7624 (7624 + 0) | 14422 (14422 + 0) |
| euc_kr               | 115692 (47500 + 68192) |  82233 (40118 + 42115) |  92375 (47500 + 44875) |  89094 (47500 + 41594) | 72438 (30844 + 41594) | 47500 (47500 + 0) |
| iso_2022_jp_katakana |        378 (126 + 252) |        362 (132 + 230) |        290 (126 + 164) |        684 (126 + 558) |        630 (72 + 558) |     126 (126 + 0) |

`.rodata` of the `bench-zig` binary (every codec, ReleaseFast), the same
build with each layout for both Chinese indexes: `flat` 430,469, `chinese_ranged`
341,061, `chinese_hash` 311,173, `chinese_rank` 305,509, `chinese_paged`
291,749, `chinese_scan` 209,765. The differences match the table above to
within a few bytes of alignment (flat to rank: 124,960 against 124,954).
encoding_rs 0.8.44's Chinese tables, by `nm --size-sort` of the Rust bench
binary: 29,490 bytes for gb18030 and 40,036 for Big5.

## Speed

Geomean GB/s over the 44 rows of each operation (corpus web, mail,
subtitles, and CSV plus synthetic ascii and nonascii shapes, 16 bytes to
64 KiB), and the ratio to encoding_rs. `zig` is `flat` with the
early-return fix below.

| op/encoding         | rust GB/s (×rust) | zig GB/s (×rust) | ranged GB/s (×rust) | hash GB/s (×rust) | rank GB/s (×rust) | paged GB/s (×rust) | scan GB/s (×rust) |
| ------------------- | ----------------: | ---------------: | ------------------: | ----------------: | ----------------: | -----------------: | ----------------: |
| DecodeUtf16/Big5    |             0.852 |     1.004 (1.17) |        0.537 (0.63) |      0.948 (1.11) |      0.959 (1.12) |       0.871 (1.02) |      0.920 (1.08) |
| DecodeUtf8/Big5     |             0.774 |     0.819 (1.06) |        0.502 (0.65) |      0.827 (1.07) |      0.825 (1.07) |       0.695 (0.90) |      0.781 (1.01) |
| EncodeUtf16/Big5    |             0.089 |     0.361 (4.03) |        0.374 (4.18) |      0.640 (7.15) |     1.356 (15.15) |      1.357 (15.18) |      0.194 (2.16) |
| EncodeUtf8/Big5     |             0.076 |     0.338 (4.42) |        0.330 (4.33) |      0.541 (7.08) |     0.944 (12.36) |      0.942 (12.33) |      0.174 (2.28) |
| DecodeUtf16/gb18030 |             0.710 |     1.076 (1.52) |        0.338 (0.47) |      1.080 (1.52) |      1.036 (1.46) |       0.878 (1.23) |      1.051 (1.48) |
| DecodeUtf8/gb18030  |             0.651 |     0.873 (1.34) |        0.288 (0.44) |      0.887 (1.36) |      0.878 (1.35) |       0.710 (1.09) |      0.882 (1.36) |
| EncodeUtf16/gb18030 |             0.073 |     0.358 (4.93) |        0.368 (5.06) |      0.669 (9.20) |     1.349 (18.65) |      1.344 (18.53) |      0.073 (1.01) |
| EncodeUtf8/gb18030  |             0.065 |     0.326 (5.04) |        0.320 (4.94) |      0.563 (8.69) |     0.960 (14.79) |      0.963 (14.86) |      0.068 (1.04) |

ns/call at 16 bytes, median over the 8 shapes of the per-row medians

| op/encoding         | rust |  zig | ranged | hash | rank | paged | scan |
| ------------------- | ---: | ---: | -----: | ---: | ---: | ----: | ---: |
| DecodeUtf16/Big5    | 13.9 | 12.6 |   11.8 | 10.8 | 11.3 |  10.7 | 11.6 |
| DecodeUtf8/Big5     | 12.9 | 19.6 |   19.4 | 19.5 | 19.6 |  19.6 | 19.6 |
| EncodeUtf16/Big5    | 13.1 | 15.3 |   15.4 | 15.1 | 15.2 |  15.3 | 15.1 |
| EncodeUtf8/Big5     | 12.4 | 14.4 |   14.4 | 14.5 | 14.4 |  14.5 | 14.6 |
| DecodeUtf16/gb18030 | 14.3 | 11.8 |   11.8 | 11.9 | 11.5 |  11.6 | 11.5 |
| DecodeUtf8/gb18030  | 13.5 | 19.4 |   19.5 | 19.5 | 19.6 |  19.6 | 19.7 |
| EncodeUtf16/gb18030 | 14.1 | 11.8 |   12.0 | 11.5 | 11.2 |  11.3 | 12.1 |
| EncodeUtf8/gb18030  | 12.1 | 10.9 |   10.8 | 10.3 | 10.6 |  10.5 | 10.3 |

The Chinese-heavy rows at 64 KiB, MB/s, carry the decision:

| row                                 | rust | zig (flat) | ranged | hash | rank | paged | scan |
| ----------------------------------- | ---: | ---------: | -----: | ---: | ---: | ----: | ---: |
| DecodeUtf8/gb18030/web-65536        |  246 |        523 |     56 |  542 |  515 |   297 |  527 |
| DecodeUtf8/gb18030/nonascii-65536   |  234 |        483 |     49 |  541 |  510 |   273 |  527 |
| DecodeUtf8/gb18030/subtitles-65536  |  303 |        614 |     67 |  637 |  616 |   367 |  625 |
| DecodeUtf16/gb18030/web-65536       |  279 |        677 |     58 |  681 |  639 |   360 |  646 |
| DecodeUtf16/gb18030/nonascii-65536  |  262 |        704 |     51 |  702 |  664 |   328 |  669 |
| DecodeUtf16/gb18030/subtitles-65536 |  328 |        780 |     71 |  803 |  686 |   430 |  755 |
| EncodeUtf8/gb18030/web-65536        |   13 |         55 |     49 |  224 |  525 |   524 |   13 |
| EncodeUtf8/gb18030/nonascii-65536   |   12 |         49 |     45 |  206 |  503 |   498 |   11 |
| EncodeUtf8/gb18030/subtitles-65536  |   15 |         62 |     56 |  260 |  577 |   587 |   15 |
| EncodeUtf16/gb18030/web-65536       |   10 |         44 |     40 |  195 |  648 |   644 |   10 |
| EncodeUtf16/gb18030/nonascii-65536  |    8 |         34 |     31 |  154 |  571 |   577 |    8 |
| EncodeUtf16/gb18030/subtitles-65536 |   14 |         62 |     56 |  276 |  862 |   860 |   14 |
| DecodeUtf8/Big5/subtitles-65536     |  380 |        556 |    231 |  544 |  556 |   420 |  496 |
| DecodeUtf8/Big5/web-65536           |  340 |        483 |    192 |  481 |  494 |   359 |  432 |
| DecodeUtf8/Big5/nonascii-65536      |  303 |        465 |    175 |  468 |  468 |   331 |  429 |
| DecodeUtf16/Big5/subtitles-65536    |  485 |        724 |    241 |  613 |  652 |   533 |  585 |
| DecodeUtf16/Big5/web-65536          |  450 |        625 |    198 |  539 |  553 |   466 |  487 |
| DecodeUtf16/Big5/nonascii-65536     |  475 |        610 |    174 |  590 |  553 |   432 |  525 |
| EncodeUtf8/Big5/subtitles-65536     |   20 |         71 |     62 |  266 |  663 |   637 |   49 |
| EncodeUtf8/Big5/web-65536           |   18 |         62 |     54 |  230 |  566 |   577 |   44 |
| EncodeUtf8/Big5/nonascii-65536      |   16 |         58 |     50 |  216 |  545 |   552 |   41 |
| EncodeUtf16/Big5/subtitles-65536    |   18 |         62 |     59 |  263 |  995 |  1007 |   48 |
| EncodeUtf16/Big5/web-65536          |   13 |         46 |     42 |  188 |  736 |   736 |   34 |
| EncodeUtf16/Big5/nonascii-65536     |   11 |         37 |     34 |  154 |  635 |   643 |   27 |

- Decode: every layout with a flat u16 decode array (flat, hash, rank,
  scan) runs within noise of the others, 1.06–1.52x encoding_rs. Two-level
  pages (`paged`) save 13.6 KB on gb18030 and nothing on Big5 and cost
  about 45% on Chinese text (gb18030 nonascii to UTF-8: 273 against 510
  MB/s): the page lookup and the base add sit on the dependency chain of
  every character. Ranged decode bisects on every character and runs at
  0.44–0.65x encoding_rs.
- Encode: bisection over the flat encode table (`flat`) and over runs
  (`ranged`) both run at 4–5x encoding_rs, a dozen dependent loads a
  character. The perfect hash is two loads plus a check and runs at 7–9x;
  it cannot pack its slots above 85–90% with 8-bit pilots, so it is not
  smaller than rank either. The rank table is a load of a 64-bit block, a
  popcount, a load of the base, and a load of the pointer, all from one
  code point: 12–19x encoding_rs, 0.5–1.0 GB/s on Chinese text. A vector
  scan of the decode table matches encoding_rs (which also searches) on
  gb18030 and is 2.2x on Big5, where the scan stops earlier.
- Short inputs: per-call cost at 16 bytes does not depend on the layout.
  Decode to UTF-16 and encode from UTF-8 beat encoding_rs; decode to UTF-8
  is about 6 ns slower on every layout and on the single-byte codecs too,
  which puts it in the shared `Decoder`/`codecs` UTF-8 entry, not in the
  tables; encode from UTF-16 and Big5 encode are 1–2 ns slower.

## `flat` and the `?u21` stall

`flat` is measured with a one-line change to its generator (requested in
the wave 1 report): its `decode` returned `if (cp == 0) null else
@intCast(cp)`, which LLVM lowers as a select between a stack temporary and
a constant null followed by a three-byte store and a wider load: a
store-forwarding stall on every character. With
`if (cp == 0) return null; return @intCast(cp);` gb18030 decode of pure
Chinese to UTF-16 goes from 227 to 680 MB/s on the same table. Every
Chinese layout returns early, and main has the fix since `5aabeb9`.

## Against the Japanese layouts

The Japanese orb measured its layouts on the same indexes
(`japanese-tables-20261102.md`) and recommends `japanese_paged`: pages of
32 to 128 entries behind a page index, empty pages shared, for decode, and
a 64-code-point bitmap with a popcount rank for encode. The two orbs' rank
encoders came out the same structure and the same size to the byte (54,316
on gb18030, 41,492 on Big5, 20,310 on jis0208, 41,594 on euc_kr), so the
layouts differ only in decode.

Bytes, decode + encode (the Japanese numbers from its report, the same
generator output):

| index                | `chinese_rank`            | `japanese_paged`          | `japanese_rows`           |
| -------------------- | ------------------------- | ------------------------- | ------------------------- |
| gb18030              | 47,880 + 54,316 = 102,196 | 48,572 + 54,316 = 102,888 | 48,632 + 54,316 = 102,948 |
| big5                 | 42,040 + 41,492 = 83,532  | 76,443 + 41,492 = 117,935 | 75,972 + 41,492 = 117,464 |
| jis0208              | 22,208 + 20,310 = 42,518  | 16,475 + 20,310 = 36,785  | 16,220 + 20,310 = 36,530  |
| jis0212              | 14,422                    | 13,026                    | 12,722                    |
| iso_2022_jp_katakana | 126 + 558 = 684           | 194 + 362 = 556           | 130 + 362 = 492           |
| euc_kr               | 47,500 + 41,594 = 89,094  | 41,166 + 41,594 = 82,760  | 37,316 + 41,594 = 78,910  |

gb18030 is dense (nearly every pointer below 23,940 has a code point), so
pages share nothing and the page index costs 692 bytes. Big5 is where the
plane-2 bit pays: without it every page holding an HKSCS code point stores
u32, and `japanese_paged` is 34,403 bytes larger. On the Japanese and
Korean indexes, which have empty rows, pages save 5.7 KB on jis0208 and
6.3 KB on euc_kr. `.rodata` of `bench-zig` with each on both Chinese
indexes: `chinese_rank` 355,869, `japanese_paged` 390,941, `japanese_rows`
390,525.

Speed, `just arms="rust zig japanese_paged japanese_rows" bench-compare 6
'gb18030|Big5'` on `c88326e` (rebased on main `280ac05`; `zig` is
`chinese_rank`), geomean GB/s over 44 rows and the ratio to encoding_rs:

| op/encoding         | rust GB/s (×rust) | zig GB/s (×rust) | japanese_paged GB/s (×rust) | japanese_rows GB/s (×rust) |
| ------------------- | ----------------: | ---------------: | --------------------------: | -------------------------: |
| DecodeUtf16/Big5    |             0.804 |     0.817 (1.02) |                0.768 (0.97) |               0.755 (0.93) |
| DecodeUtf8/Big5     |             0.740 |     0.793 (1.07) |                0.735 (0.99) |               0.696 (0.94) |
| EncodeUtf16/Big5    |             0.087 |    1.302 (15.01) |               1.299 (14.96) |              1.288 (14.83) |
| EncodeUtf8/Big5     |             0.075 |    0.898 (12.06) |               0.900 (12.07) |              0.907 (12.15) |
| DecodeUtf16/gb18030 |             0.679 |     0.897 (1.32) |                0.880 (1.29) |               0.866 (1.27) |
| DecodeUtf8/gb18030  |             0.631 |     0.862 (1.37) |                0.812 (1.29) |               0.761 (1.21) |
| EncodeUtf16/gb18030 |             0.072 |    1.330 (18.55) |               1.327 (18.48) |              1.326 (18.50) |
| EncodeUtf8/gb18030  |             0.063 |    0.934 (14.84) |               0.923 (14.74) |              0.925 (14.75) |

ns/call at 16 bytes, median over the 8 shapes of the per-row medians

| op/encoding         | rust |  zig | japanese_paged | japanese_rows |
| ------------------- | ---: | ---: | -------------: | ------------: |
| DecodeUtf16/Big5    | 16.1 | 20.4 |           20.4 |          20.2 |
| DecodeUtf8/Big5     | 13.2 | 18.7 |           18.9 |          18.7 |
| EncodeUtf16/Big5    | 13.5 | 15.4 |           15.6 |          15.3 |
| EncodeUtf8/Big5     | 13.3 | 15.5 |           16.2 |          15.3 |
| DecodeUtf16/gb18030 | 14.4 | 20.1 |           20.7 |          20.3 |
| DecodeUtf8/gb18030  | 13.7 | 19.7 |           19.4 |          20.4 |
| EncodeUtf16/gb18030 | 13.9 | 11.4 |           11.9 |          11.9 |
| EncodeUtf8/gb18030  | 13.4 | 10.2 |           10.8 |          11.1 |

Decode of Chinese text at 64 KiB, MB/s:

| row                                | rust | zig (rank) | japanese_paged | japanese_rows |
| ---------------------------------- | ---: | ---------: | -------------: | ------------: |
| DecodeUtf8/gb18030/web-65536       |  236 |        505 |            477 |           431 |
| DecodeUtf8/gb18030/nonascii-65536  |  231 |        519 |            474 |           428 |
| DecodeUtf16/gb18030/web-65536      |  252 |        584 |            609 |           577 |
| DecodeUtf16/gb18030/nonascii-65536 |  261 |        674 |            614 |           594 |
| DecodeUtf8/Big5/web-65536          |  333 |        482 |            397 |           362 |
| DecodeUtf8/Big5/nonascii-65536     |  277 |        427 |            350 |           330 |
| DecodeUtf16/Big5/web-65536         |  426 |        515 |            479 |           448 |
| DecodeUtf16/Big5/nonascii-65536    |  470 |        500 |            399 |           438 |

Encode ties, as it should with the same table. Decode with pages is 2–7%
slower geomean (gb18030 to UTF-8: 1.29x against 1.37x encoding_rs; Big5
to UTF-8: 0.99x against 1.07x), and up to 20% on Big5's Chinese rows (nonascii to UTF-16: 399
against 500 MB/s); rows is slower again. Per-call cost at 16 bytes is the
same for all three.

The 16-byte decode-to-UTF-16 rows cost about 20 ns here against 11.5 ns
before the rebase, on every arm and on windows-1252 too (`web-16`: 11.6 ns
on the pre-rebase build, 19.5 ns after, interleaved on one core), so it
is in the shared decoder path that the rebase brought in with the
Japanese family, not in the tables.

## Recommendation

Decision 1, the table layout: a flat u16 array by pointer for decode, with
the plane-2 bit for Big5's HKSCS code points (so Big5 stops paying u32 a
pointer: 42,040 bytes against 79,128). Two-level pages and ranges are
smaller only on gb18030 and cost too much decode speed. Against
`japanese_paged` on the Chinese indexes, flat-with-bit is smaller (by 692
bytes on gb18030 and 34,403 on Big5) and decodes 2–7% faster. Pages pay
where an index has empty rows (jis0208, euc_kr), which the Chinese ones do
not. One generator could serve every family: `japanese_paged` with the
plane-2 bit, falling back to no page index when pages save nothing,
would give the Chinese tables this layout's size and decode path and the
Japanese ones paged's (not built or measured here).

Decision 2, the encoder lookup: the rank table. It is the fastest by 2x
over the perfect hash and about 3x over bisection, and smaller than both
(54,316 bytes on gb18030 against 63,654 and 95,756; 41,492 on Big5 against
37,815 and 87,918). It is generated from the index alone, with no search
for seeds.

The cost is bytes: 186.6 KB of Chinese tables against encoding_rs's 69.5
KB. `chinese_scan` would be 90.7 KB with encode at encoding_rs's speed;
the plan says speed and memory count equally and encoding_rs is the bar on
both, and neither layout clears both bars. Rank is ahead of encoding_rs on
speed by more than it is behind on bytes, so it is the recommendation, with
the trade recorded for the owner.

## Method

Intel(R) Xeon(R) Processor @ 2.60GHz (4 vCPUs, AVX-512), in an orb. Zig
0.16 ReleaseFast for the host CPU. One `bench-zig` arm per layout, built
by setting `.layout` on both Chinese entries in `gen/sources.zig`,
regenerating, and building. `just arms="rust zig ranged hash rank paged
scan" bench-compare 6 'gb18030|Big5'`: each arm is a server pinned to one
core (`taskset`), the seven time each row back to back in rotating order,
6 rounds of 50 ms samples, then benchstat with encoding_rs 0.8.44 as the
base. Every arm's output matched the reference on all rows it ran (5,984
rows each, 0 differ). Table bytes are counted from each generated file's
arrays.

## Raw output

The run against the Japanese layouts,
`benchstat rust.txt zig.txt japanese_paged.txt japanese_rows.txt`, GB/s:

```text
zig: ReleaseFast, native, c88326e
rust: encoding_rs 0.8.44; icu 78.3; go: x/text v0.43.0
buffers: input 0 bytes past a page, output 2048; 50 ms a sample, 6 rounds
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor @ 2.60GHz
                                     │     rust      │                   zig                   │             japanese_paged              │              japanese_rows              │
                                     │     GB/s      │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │
DecodeUtf8/gb18030/ascii-16            1154.4m ± 49%     791.9m ± 24%          ~ (p=0.240 n=6)     824.5m ± 26%          ~ (p=0.240 n=6)     761.8m ± 20%          ~ (p=0.240 n=6)
DecodeUtf8/gb18030/csv-16              1229.3m ± 46%     831.8m ± 27%    -32.34% (p=0.041 n=6)     843.2m ± 29%    -31.41% (p=0.041 n=6)     823.9m ± 27%    -32.98% (p=0.041 n=6)
DecodeUtf8/gb18030/invalid-16           241.5m ± 43%     461.4m ± 46%    +91.06% (p=0.002 n=6)     408.4m ± 46%    +69.11% (p=0.041 n=6)     380.6m ± 42%    +57.62% (p=0.041 n=6)
DecodeUtf8/gb18030/mail-16             1237.7m ± 39%     841.3m ± 23%    -32.03% (p=0.041 n=6)     826.2m ±  6%          ~ (p=0.065 n=6)     815.5m ±  3%          ~ (p=0.065 n=6)
DecodeUtf8/gb18030/mixed-16             371.0m ±  4%     452.3m ± 13%    +21.90% (p=0.002 n=6)     427.2m ±  5%    +15.16% (p=0.002 n=6)     376.4m ± 11%          ~ (p=0.699 n=6)
DecodeUtf8/gb18030/nonascii-16          379.8m ±  9%     402.4m ±  9%          ~ (p=0.699 n=6)     340.0m ± 14%    -10.47% (p=0.004 n=6)     306.5m ±  6%    -19.29% (p=0.002 n=6)
DecodeUtf8/gb18030/subtitles-16        1218.9m ±  5%     832.0m ± 19%    -31.74% (p=0.002 n=6)     825.1m ± 18%    -32.31% (p=0.002 n=6)     820.8m ±  3%    -32.66% (p=0.002 n=6)
DecodeUtf8/gb18030/web-16              1190.5m ± 20%     835.4m ± 13%    -29.83% (p=0.002 n=6)     836.0m ±  3%    -29.77% (p=0.002 n=6)     815.5m ± 11%    -31.50% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-64              3.299 ± 22%      3.079 ±  5%          ~ (p=0.394 n=6)      3.065 ± 12%          ~ (p=0.240 n=6)      3.126 ± 10%          ~ (p=0.394 n=6)
DecodeUtf8/gb18030/csv-64              1124.7m ± 33%    1239.4m ± 33%          ~ (p=0.180 n=6)    1116.0m ± 36%          ~ (p=1.000 n=6)     974.8m ± 29%    -13.33% (p=0.026 n=6)
DecodeUtf8/gb18030/invalid-64           201.1m ± 26%     389.0m ± 30%    +93.48% (p=0.002 n=6)     360.2m ± 28%    +79.18% (p=0.002 n=6)     324.1m ± 12%    +61.18% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-64               3.375 ± 14%      3.019 ±  8%    -10.56% (p=0.041 n=6)      3.008 ± 24%    -10.88% (p=0.026 n=6)      3.137 ± 16%     -7.06% (p=0.041 n=6)
DecodeUtf8/gb18030/mixed-64             382.8m ± 50%     417.8m ± 35%          ~ (p=0.180 n=6)     421.9m ± 31%          ~ (p=0.093 n=6)     405.3m ± 40%          ~ (p=0.180 n=6)
DecodeUtf8/gb18030/nonascii-64          476.6m ± 40%     484.1m ± 34%          ~ (p=0.589 n=6)     405.9m ± 49%          ~ (p=0.093 n=6)     336.1m ± 22%    -29.47% (p=0.026 n=6)
DecodeUtf8/gb18030/subtitles-64         899.6m ± 46%     918.4m ± 53%          ~ (p=0.937 n=6)     812.8m ± 51%          ~ (p=0.132 n=6)     717.2m ± 39%    -20.27% (p=0.041 n=6)
DecodeUtf8/gb18030/web-64                3.358 ± 44%      3.116 ± 27%          ~ (p=0.394 n=6)      3.131 ± 26%          ~ (p=0.394 n=6)      3.165 ± 27%          ~ (p=0.394 n=6)
DecodeUtf8/gb18030/csv-256              414.2m ± 44%     646.7m ± 43%          ~ (p=0.132 n=6)     589.9m ± 44%          ~ (p=0.132 n=6)     524.9m ± 41%          ~ (p=0.132 n=6)
DecodeUtf8/gb18030/subtitles-256        482.8m ± 39%     707.8m ± 56%    +46.58% (p=0.041 n=6)     636.1m ± 51%    +31.74% (p=0.041 n=6)     551.1m ± 43%          ~ (p=0.180 n=6)
DecodeUtf8/gb18030/ascii-256             6.033 ± 37%      9.795 ± 37%    +62.36% (p=0.004 n=6)      9.630 ± 36%    +59.64% (p=0.004 n=6)      9.769 ± 37%    +61.93% (p=0.009 n=6)
DecodeUtf8/gb18030/invalid-256          241.1m ± 39%     380.4m ± 41%    +57.76% (p=0.015 n=6)     355.4m ± 40%    +47.38% (p=0.026 n=6)     322.9m ± 36%          ~ (p=0.065 n=6)
DecodeUtf8/gb18030/mail-256            1029.3m ± 48%     832.5m ± 46%          ~ (p=0.818 n=6)     828.1m ± 39%          ~ (p=1.000 n=6)    1004.1m ± 51%          ~ (p=0.485 n=6)
DecodeUtf8/gb18030/mixed-256            315.7m ± 49%     410.7m ± 40%    +30.07% (p=0.041 n=6)     391.2m ± 42%    +23.91% (p=0.041 n=6)     383.6m ± 44%    +21.50% (p=0.041 n=6)
DecodeUtf8/gb18030/nonascii-256         381.7m ± 45%     520.2m ± 54%    +36.27% (p=0.041 n=6)     458.1m ± 53%    +19.99% (p=0.041 n=6)     402.3m ± 50%          ~ (p=0.310 n=6)
DecodeUtf8/gb18030/web-256               1.397 ±  4%      1.470 ± 53%          ~ (p=0.132 n=6)      1.353 ± 52%          ~ (p=0.180 n=6)      1.227 ± 17%    -12.17% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-4096             385.2m ± 36%     564.0m ± 32%    +46.41% (p=0.026 n=6)     520.5m ± 37%    +35.12% (p=0.041 n=6)     452.8m ± 30%          ~ (p=0.065 n=6)
DecodeUtf8/gb18030/ascii-4096            8.293 ± 36%     18.940 ± 43%   +128.38% (p=0.002 n=6)     19.045 ± 45%   +129.65% (p=0.002 n=6)     19.040 ± 43%   +129.60% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-4096         232.8m ± 45%     362.9m ± 28%    +55.87% (p=0.002 n=6)     353.5m ± 35%    +51.79% (p=0.015 n=6)     346.8m ± 41%    +48.94% (p=0.026 n=6)
DecodeUtf8/gb18030/mail-4096            465.2m ± 51%     650.8m ± 56%          ~ (p=0.180 n=6)     609.6m ± 47%    +31.04% (p=0.026 n=6)     481.3m ± 32%          ~ (p=0.394 n=6)
DecodeUtf8/gb18030/mixed-4096           286.8m ± 36%     405.5m ±  3%    +41.36% (p=0.002 n=6)     383.5m ±  5%    +33.69% (p=0.002 n=6)     373.3m ± 49%    +30.14% (p=0.041 n=6)
DecodeUtf8/gb18030/nonascii-4096        375.2m ± 15%     532.6m ± 20%    +41.93% (p=0.002 n=6)     485.5m ± 19%    +29.38% (p=0.002 n=6)     411.0m ± 12%          ~ (p=0.065 n=6)
DecodeUtf8/gb18030/subtitles-4096       505.1m ± 22%     653.3m ±  7%    +29.33% (p=0.002 n=6)     603.6m ± 13%    +19.50% (p=0.002 n=6)     506.8m ±  3%          ~ (p=0.699 n=6)
DecodeUtf8/gb18030/web-4096             422.9m ± 16%     590.0m ±  4%    +39.52% (p=0.002 n=6)     536.8m ±  6%    +26.92% (p=0.002 n=6)     459.5m ±  9%     +8.65% (p=0.015 n=6)
DecodeUtf8/gb18030/mail-65536           316.9m ± 12%     661.2m ± 16%   +108.63% (p=0.002 n=6)     606.0m ±  8%    +91.20% (p=0.002 n=6)     539.7m ± 14%    +70.28% (p=0.002 n=6)
DecodeUtf8/gb18030/web-65536            236.4m ± 24%     504.6m ± 34%   +113.45% (p=0.002 n=6)     476.8m ± 12%   +101.69% (p=0.002 n=6)     431.2m ± 14%    +82.38% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-65536           8.805 ± 12%     20.944 ±  9%   +137.86% (p=0.002 n=6)     21.651 ± 11%   +145.89% (p=0.002 n=6)     21.814 ± 11%   +147.73% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-65536            409.6m ±  8%     606.5m ±  8%    +48.07% (p=0.002 n=6)     535.0m ± 58%          ~ (p=0.065 n=6)     481.8m ±  5%    +17.64% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-65536        87.35m ± 39%    209.45m ± 30%   +139.78% (p=0.002 n=6)    205.85m ± 31%   +135.66% (p=0.002 n=6)    203.45m ± 32%   +132.91% (p=0.002 n=6)
DecodeUtf8/gb18030/mixed-65536          227.8m ±  6%     405.7m ± 17%    +78.06% (p=0.002 n=6)     388.4m ±  9%    +70.46% (p=0.002 n=6)     375.6m ± 23%    +64.85% (p=0.002 n=6)
DecodeUtf8/gb18030/nonascii-65536       230.6m ± 11%     519.4m ± 20%   +125.27% (p=0.002 n=6)     473.8m ± 13%   +105.53% (p=0.002 n=6)     427.5m ±  8%    +85.43% (p=0.002 n=6)
DecodeUtf8/gb18030/subtitles-65536      299.5m ± 30%     629.0m ± 16%   +109.96% (p=0.002 n=6)     558.1m ± 37%    +86.31% (p=0.002 n=6)     519.9m ± 21%    +73.56% (p=0.002 n=6)
DecodeUtf8/gb18030/web-1048576          236.2m ± 43%     516.0m ± 56%   +118.48% (p=0.026 n=6)     481.0m ± 18%   +103.68% (p=0.002 n=6)     420.0m ±  3%    +77.85% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-1048576         7.968 ± 33%     18.489 ± 46%   +132.03% (p=0.002 n=6)     16.707 ± 38%   +109.66% (p=0.002 n=6)     17.492 ± 40%   +119.52% (p=0.002 n=6)
DecodeUtf8/gb18030/mixed-1048576        213.1m ± 52%     378.2m ± 46%          ~ (p=0.132 n=6)     341.0m ± 46%          ~ (p=0.132 n=6)     369.9m ± 52%          ~ (p=0.132 n=6)
DecodeUtf8/gb18030/nonascii-1048576     215.8m ± 26%     437.3m ± 53%          ~ (p=0.056 n=6)     420.2m ± 43%    +94.72% (p=0.002 n=6)     415.7m ± 12%    +92.61% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-16           1110.7m ± 45%     799.7m ± 24%          ~ (p=0.065 n=6)     791.7m ± 23%          ~ (p=0.065 n=6)     789.6m ± 22%          ~ (p=0.065 n=6)
DecodeUtf16/gb18030/csv-16             1130.3m ±  5%     808.9m ±  7%    -28.43% (p=0.002 n=6)     790.2m ±  9%    -30.09% (p=0.002 n=6)     806.1m ±  7%    -28.69% (p=0.002 n=6)
DecodeUtf16/gb18030/invalid-16          263.9m ±  3%     479.2m ±  7%    +81.56% (p=0.002 n=6)     463.6m ±  5%    +75.69% (p=0.002 n=6)     449.8m ±  6%    +70.44% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-16            1119.3m ± 13%     805.5m ±  9%    -28.03% (p=0.002 n=6)     769.3m ± 13%    -31.27% (p=0.002 n=6)     805.8m ± 25%    -28.01% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-16            376.5m ± 13%     426.1m ± 24%          ~ (p=0.065 n=6)     361.0m ± 28%          ~ (p=0.240 n=6)     375.1m ± 21%          ~ (p=0.699 n=6)
DecodeUtf16/gb18030/nonascii-16         537.2m ± 10%     363.2m ± 20%    -32.39% (p=0.002 n=6)     379.2m ± 12%    -29.41% (p=0.002 n=6)     394.2m ± 22%    -26.62% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-16       1116.5m ± 39%     816.3m ± 18%    -26.89% (p=0.041 n=6)     779.1m ±  6%          ~ (p=0.065 n=6)     786.5m ± 14%    -29.56% (p=0.041 n=6)
DecodeUtf16/gb18030/web-16             1136.5m ± 14%     792.7m ±  8%    -30.24% (p=0.002 n=6)     799.6m ± 11%    -29.64% (p=0.002 n=6)     795.0m ± 18%    -30.05% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-64             2.792 ±  7%      2.940 ±  9%          ~ (p=0.240 n=6)      2.951 ±  7%          ~ (p=0.065 n=6)      2.955 ± 12%          ~ (p=0.310 n=6)
DecodeUtf16/gb18030/csv-64               1.374 ± 35%      1.399 ± 33%          ~ (p=0.818 n=6)      1.259 ± 38%          ~ (p=0.132 n=6)      1.338 ± 25%          ~ (p=0.589 n=6)
DecodeUtf16/gb18030/invalid-64          233.1m ± 30%     397.5m ± 37%    +70.55% (p=0.009 n=6)     381.1m ± 18%    +63.49% (p=0.002 n=6)     404.2m ± 21%    +73.42% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-64              2.853 ± 32%      3.052 ± 19%          ~ (p=0.240 n=6)      2.820 ± 19%          ~ (p=0.937 n=6)      2.963 ± 18%          ~ (p=0.065 n=6)
DecodeUtf16/gb18030/mixed-64            440.5m ±  8%     467.9m ± 15%          ~ (p=0.065 n=6)     463.9m ±  8%     +5.32% (p=0.026 n=6)     449.6m ± 17%          ~ (p=0.589 n=6)
DecodeUtf16/gb18030/nonascii-64         604.3m ± 32%     515.8m ± 11%          ~ (p=0.240 n=6)     503.8m ± 39%          ~ (p=0.240 n=6)     499.6m ± 40%          ~ (p=0.180 n=6)
DecodeUtf16/gb18030/subtitles-64       1230.1m ± 27%     981.8m ± 38%    -20.19% (p=0.041 n=6)     941.1m ± 44%    -23.49% (p=0.026 n=6)     918.4m ± 37%    -25.34% (p=0.015 n=6)
DecodeUtf16/gb18030/web-64               2.875 ± 37%      2.910 ± 22%          ~ (p=0.485 n=6)      2.855 ± 21%          ~ (p=0.699 n=6)      2.993 ± 24%          ~ (p=0.310 n=6)
DecodeUtf16/gb18030/csv-256             485.6m ± 33%     709.8m ± 40%    +46.14% (p=0.026 n=6)     694.1m ± 42%    +42.92% (p=0.026 n=6)     668.1m ± 25%    +37.58% (p=0.015 n=6)
DecodeUtf16/gb18030/subtitles-256       602.2m ± 26%     807.2m ± 19%    +34.03% (p=0.002 n=6)     795.5m ± 31%    +32.09% (p=0.024 n=6)     755.8m ± 30%    +25.50% (p=0.041 n=6)
DecodeUtf16/gb18030/ascii-256            5.243 ± 29%      8.797 ± 38%    +67.80% (p=0.004 n=6)      9.399 ± 43%    +79.27% (p=0.009 n=6)      8.724 ± 39%    +66.39% (p=0.009 n=6)
DecodeUtf16/gb18030/invalid-256         289.8m ±  7%     418.3m ± 45%          ~ (p=0.065 n=6)     398.2m ± 46%          ~ (p=0.065 n=6)     382.0m ± 30%          ~ (p=0.065 n=6)
DecodeUtf16/gb18030/mail-256             1.327 ± 44%      1.317 ± 19%          ~ (p=1.000 n=6)      1.234 ±  5%          ~ (p=0.065 n=6)      1.276 ±  2%          ~ (p=0.093 n=6)
DecodeUtf16/gb18030/mixed-256           365.4m ± 47%     429.7m ± 27%    +17.59% (p=0.041 n=6)     422.0m ±  2%    +15.47% (p=0.002 n=6)     415.0m ± 31%    +13.56% (p=0.041 n=6)
DecodeUtf16/gb18030/nonascii-256        428.4m ± 31%     535.2m ± 29%    +24.94% (p=0.026 n=6)     540.8m ± 10%    +26.23% (p=0.002 n=6)     554.3m ± 44%    +29.39% (p=0.041 n=6)
DecodeUtf16/gb18030/web-256              1.757 ± 20%      1.574 ± 19%    -10.44% (p=0.041 n=6)      1.452 ± 20%    -17.39% (p=0.026 n=6)      1.479 ± 36%    -15.83% (p=0.026 n=6)
DecodeUtf16/gb18030/csv-4096            503.6m ± 37%     616.1m ± 38%    +22.35% (p=0.041 n=6)     594.5m ± 43%          ~ (p=0.180 n=6)     572.2m ± 44%          ~ (p=0.180 n=6)
DecodeUtf16/gb18030/ascii-4096           6.631 ± 28%     18.456 ± 44%   +178.34% (p=0.002 n=6)     18.563 ± 38%   +179.95% (p=0.002 n=6)     17.939 ± 43%   +170.54% (p=0.002 n=6)
DecodeUtf16/gb18030/invalid-4096        248.5m ± 30%     407.4m ±  9%    +63.96% (p=0.002 n=6)     400.6m ±  7%    +61.21% (p=0.002 n=6)     381.4m ± 39%    +53.48% (p=0.026 n=6)
DecodeUtf16/gb18030/mail-4096           615.8m ±  9%     682.2m ± 39%          ~ (p=0.240 n=6)     752.3m ± 45%          ~ (p=0.132 n=6)     688.9m ± 44%          ~ (p=0.065 n=6)
DecodeUtf16/gb18030/mixed-4096          297.1m ± 39%     428.9m ± 28%    +44.40% (p=0.015 n=6)     427.8m ± 30%    +44.02% (p=0.015 n=6)     398.7m ± 29%    +34.22% (p=0.015 n=6)
DecodeUtf16/gb18030/nonascii-4096       423.9m ± 40%     529.3m ± 35%          ~ (p=0.093 n=6)     585.9m ± 46%          ~ (p=0.093 n=6)     530.4m ± 43%          ~ (p=0.240 n=6)
DecodeUtf16/gb18030/subtitles-4096      590.1m ± 41%     636.4m ± 28%          ~ (p=0.394 n=6)     648.9m ± 32%          ~ (p=0.240 n=6)     694.0m ± 48%          ~ (p=0.180 n=6)
DecodeUtf16/gb18030/web-4096            426.2m ± 28%     637.4m ± 30%    +49.54% (p=0.041 n=6)     549.1m ± 24%          ~ (p=0.093 n=6)     547.4m ± 26%          ~ (p=0.132 n=6)
DecodeUtf16/gb18030/mail-65536          340.9m ±  5%     702.9m ±  9%   +106.16% (p=0.002 n=6)     729.2m ± 16%   +113.89% (p=0.002 n=6)     701.6m ± 17%   +105.79% (p=0.002 n=6)
DecodeUtf16/gb18030/web-65536           252.4m ± 10%     584.5m ± 33%   +131.56% (p=0.002 n=6)     608.6m ±  8%   +141.13% (p=0.002 n=6)     577.2m ± 11%   +128.68% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-65536          7.714 ±  4%     18.102 ±  6%   +134.66% (p=0.002 n=6)     18.321 ±  6%   +137.49% (p=0.002 n=6)     18.649 ± 12%   +141.75% (p=0.002 n=6)
DecodeUtf16/gb18030/csv-65536           530.0m ± 30%     694.2m ± 14%    +30.99% (p=0.002 n=6)     691.0m ± 28%    +30.39% (p=0.041 n=6)     654.5m ± 20%    +23.50% (p=0.026 n=6)
DecodeUtf16/gb18030/invalid-65536       91.15m ± 19%    214.80m ± 18%   +135.66% (p=0.002 n=6)    220.70m ± 10%   +142.13% (p=0.002 n=6)    210.30m ±  8%   +130.72% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-65536         253.0m ± 20%     433.5m ±  4%    +71.33% (p=0.002 n=6)     411.1m ± 20%    +62.44% (p=0.002 n=6)     406.1m ± 28%    +60.48% (p=0.002 n=6)
DecodeUtf16/gb18030/nonascii-65536      260.9m ± 23%     674.2m ±  5%   +158.48% (p=0.002 n=6)     614.1m ±  4%   +135.42% (p=0.002 n=6)     593.6m ±  5%   +127.56% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-65536     316.3m ± 17%     705.2m ±  8%   +122.95% (p=0.002 n=6)     718.8m ±  5%   +127.25% (p=0.002 n=6)     697.8m ±  6%   +120.60% (p=0.002 n=6)
DecodeUtf16/gb18030/web-1048576         254.9m ±  6%     599.8m ±  8%   +135.35% (p=0.002 n=6)     593.7m ± 22%   +132.96% (p=0.002 n=6)     563.4m ± 11%   +121.05% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-1048576        7.075 ± 16%      9.163 ± 10%    +29.50% (p=0.002 n=6)      9.110 ± 16%    +28.75% (p=0.002 n=6)      9.252 ±  9%    +30.76% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-1048576       226.3m ±  9%     400.9m ± 20%    +77.15% (p=0.002 n=6)     395.6m ± 25%    +74.81% (p=0.002 n=6)     398.9m ± 12%    +76.27% (p=0.002 n=6)
DecodeUtf16/gb18030/nonascii-1048576    249.2m ± 35%     668.0m ± 50%   +168.06% (p=0.002 n=6)     615.3m ± 53%   +146.89% (p=0.002 n=6)     497.0m ± 40%    +99.46% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-16              1.325 ±  6%      1.574 ± 48%          ~ (p=0.065 n=6)      1.572 ± 49%          ~ (p=0.065 n=6)      1.565 ± 40%          ~ (p=0.394 n=6)
EncodeUtf8/gb18030/csv-16                1.291 ± 27%      1.577 ± 31%    +22.19% (p=0.041 n=6)      1.515 ± 18%    +17.37% (p=0.026 n=6)      1.446 ± 21%    +12.01% (p=0.041 n=6)
EncodeUtf8/gb18030/invalid-16           9.450m ± 19%   475.100m ± 15%  +4927.51% (p=0.002 n=6)   397.100m ± 25%  +4102.12% (p=0.002 n=6)   473.550m ± 23%  +4911.11% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-16               1.184 ± 22%      1.574 ± 42%          ~ (p=0.065 n=6)      1.489 ± 26%          ~ (p=0.093 n=6)      1.458 ± 39%          ~ (p=0.394 n=6)
EncodeUtf8/gb18030/mixed-16             21.60m ± 45%    458.05m ± 47%  +2020.60% (p=0.002 n=6)    441.10m ± 45%  +1942.13% (p=0.002 n=6)    435.80m ± 45%  +1917.59% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-16          17.15m ± 38%    455.00m ± 12%  +2553.06% (p=0.002 n=6)    435.75m ± 47%  +2440.82% (p=0.002 n=6)    448.85m ± 49%  +2517.20% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-16          1.219 ± 35%      1.576 ± 21%    +29.27% (p=0.015 n=6)      1.567 ± 15%          ~ (p=0.065 n=6)      1.457 ± 34%          ~ (p=0.132 n=6)
EncodeUtf8/gb18030/web-16                1.350 ± 14%      1.567 ± 30%          ~ (p=0.180 n=6)      1.487 ± 24%          ~ (p=0.240 n=6)      1.507 ± 31%          ~ (p=0.065 n=6)
EncodeUtf8/gb18030/ascii-64              3.133 ±  6%      5.263 ± 22%    +67.98% (p=0.002 n=6)      5.378 ± 27%    +71.66% (p=0.002 n=6)      4.960 ± 18%    +58.31% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-64               43.45m ± 22%   1008.70m ± 10%  +2221.52% (p=0.002 n=6)   1066.25m ± 23%  +2353.97% (p=0.002 n=6)   1068.65m ±  6%  +2359.49% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-64           12.10m ± 11%    293.50m ± 20%  +2325.62% (p=0.002 n=6)    304.90m ± 31%  +2419.83% (p=0.002 n=6)    309.05m ±  4%  +2454.13% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-64               3.194 ± 24%      4.990 ± 22%    +56.22% (p=0.002 n=6)      5.261 ± 11%    +64.71% (p=0.002 n=6)      5.301 ± 11%    +65.97% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-64             20.55m ±  6%    441.70m ± 23%  +2049.39% (p=0.002 n=6)    461.15m ±  3%  +2144.04% (p=0.002 n=6)    454.95m ±  9%  +2113.87% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-64          16.90m ± 12%    495.40m ± 14%  +2831.36% (p=0.002 n=6)    498.35m ± 16%  +2848.82% (p=0.002 n=6)    491.85m ± 10%  +2810.36% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-64         27.30m ± 10%    798.85m ± 12%  +2826.19% (p=0.002 n=6)    774.55m ± 21%  +2737.18% (p=0.002 n=6)    798.00m ±  7%  +2823.08% (p=0.002 n=6)
EncodeUtf8/gb18030/web-64                3.183 ±  5%      5.304 ± 17%    +66.63% (p=0.002 n=6)      5.079 ± 11%    +59.55% (p=0.002 n=6)      5.208 ± 13%    +63.62% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-256              12.50m ± 14%    624.40m ±  3%  +4895.20% (p=0.002 n=6)    611.50m ± 26%  +4792.00% (p=0.002 n=6)    604.20m ±  8%  +4733.60% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-256        15.95m ±  7%    644.00m ± 16%  +3937.62% (p=0.002 n=6)    638.85m ±  9%  +3905.33% (p=0.002 n=6)    632.10m ±  4%  +3863.01% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-256             5.163 ±  9%     12.748 ± 23%   +146.93% (p=0.002 n=6)     11.995 ± 26%   +132.33% (p=0.002 n=6)     11.652 ± 42%   +125.69% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-256          14.10m ± 38%    313.05m ± 26%  +2120.21% (p=0.002 n=6)    328.30m ± 17%  +2228.37% (p=0.002 n=6)    323.30m ± 13%  +2192.91% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-256             28.50m ± 39%    986.35m ±  5%  +3360.88% (p=0.002 n=6)    947.60m ± 27%  +3224.91% (p=0.002 n=6)    969.35m ± 11%  +3301.23% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-256            15.85m ± 43%    433.90m ± 18%  +2637.54% (p=0.002 n=6)    441.15m ± 20%  +2683.28% (p=0.002 n=6)    443.15m ± 22%  +2695.90% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-256         11.70m ± 43%    485.10m ± 23%  +4046.15% (p=0.002 n=6)    430.05m ± 19%  +3575.64% (p=0.002 n=6)    499.10m ± 24%  +4165.81% (p=0.002 n=6)
EncodeUtf8/gb18030/web-256              40.90m ± 41%   1179.55m ± 28%  +2783.99% (p=0.002 n=6)   1154.10m ± 26%  +2721.76% (p=0.002 n=6)   1184.80m ± 30%  +2796.82% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-4096             13.60m ± 38%    539.95m ± 24%  +3870.22% (p=0.002 n=6)    536.25m ± 21%  +3843.01% (p=0.002 n=6)    561.55m ± 27%  +4029.04% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-4096            6.542 ± 29%     19.754 ± 41%   +201.98% (p=0.002 n=6)     19.527 ± 29%   +198.51% (p=0.002 n=6)     18.994 ± 25%   +190.36% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-4096         10.85m ± 42%    333.50m ± 30%  +2973.73% (p=0.002 n=6)    307.35m ± 23%  +2732.72% (p=0.002 n=6)    341.70m ± 35%  +3049.31% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-4096            13.55m ± 12%    566.85m ± 14%  +4083.39% (p=0.002 n=6)    608.30m ± 16%  +4389.30% (p=0.002 n=6)    567.40m ± 27%  +4087.45% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-4096           15.75m ± 12%    436.15m ± 18%  +2669.21% (p=0.002 n=6)    431.75m ± 18%  +2641.27% (p=0.002 n=6)    437.60m ± 15%  +2678.41% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-4096        10.75m ± 15%    487.70m ±  8%  +4436.74% (p=0.002 n=6)    489.60m ± 21%  +4454.42% (p=0.002 n=6)    458.20m ± 26%  +4162.33% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-4096       14.70m ± 18%    573.70m ± 26%  +3802.72% (p=0.002 n=6)    537.85m ± 15%  +3558.84% (p=0.002 n=6)    575.55m ±  8%  +3815.31% (p=0.002 n=6)
EncodeUtf8/gb18030/web-4096             12.70m ±  5%    538.10m ± 19%  +4137.01% (p=0.002 n=6)    539.30m ±  6%  +4146.46% (p=0.002 n=6)    537.50m ±  5%  +4132.28% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-65536           15.35m ± 15%    596.45m ± 17%  +3785.67% (p=0.002 n=6)    593.35m ± 13%  +3765.47% (p=0.002 n=6)    582.90m ± 18%  +3697.39% (p=0.002 n=6)
EncodeUtf8/gb18030/web-65536            12.75m ± 11%    476.90m ± 11%  +3640.39% (p=0.002 n=6)    494.70m ±  9%  +3780.00% (p=0.002 n=6)    481.85m ±  9%  +3679.22% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-65536           6.526 ± 25%     21.755 ± 14%   +233.35% (p=0.002 n=6)     21.350 ± 12%   +227.13% (p=0.002 n=6)     20.776 ± 33%   +218.35% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-65536            14.15m ± 17%    553.95m ± 18%  +3814.84% (p=0.002 n=6)    551.65m ± 19%  +3798.59% (p=0.002 n=6)    571.25m ±  9%  +3937.10% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-65536        10.80m ± 10%    222.80m ± 13%  +1962.96% (p=0.002 n=6)    227.90m ±  4%  +2010.19% (p=0.002 n=6)    231.55m ±  7%  +2043.98% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-65536          15.60m ± 24%    423.50m ±  5%  +2614.74% (p=0.002 n=6)    420.25m ±  5%  +2593.91% (p=0.002 n=6)    430.15m ± 17%  +2657.37% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-65536       11.45m ± 14%    478.80m ±  5%  +4081.66% (p=0.002 n=6)    473.65m ± 25%  +4036.68% (p=0.002 n=6)    473.20m ± 29%  +4032.75% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-65536      14.15m ± 39%    571.05m ± 41%  +3935.69% (p=0.002 n=6)    542.60m ± 36%  +3734.63% (p=0.002 n=6)    510.30m ± 34%  +3506.36% (p=0.002 n=6)
EncodeUtf8/gb18030/web-1048576          11.50m ± 37%    443.15m ± 33%  +3753.48% (p=0.002 n=6)    461.40m ± 37%  +3912.17% (p=0.002 n=6)    472.80m ± 35%  +4011.30% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-1048576         6.337 ± 30%     17.488 ± 43%   +175.94% (p=0.002 n=6)     18.233 ± 40%   +187.71% (p=0.002 n=6)     17.844 ± 46%   +181.57% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-1048576        14.95m ± 40%    426.80m ± 41%  +2754.85% (p=0.002 n=6)    426.35m ± 40%  +2751.84% (p=0.002 n=6)    418.70m ± 38%  +2700.67% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-1048576     11.30m ± 41%    481.20m ± 40%  +4158.41% (p=0.002 n=6)    488.05m ± 41%  +4219.03% (p=0.002 n=6)    455.35m ± 35%  +3929.65% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-16             2.350 ± 47%      2.799 ± 47%    +19.14% (p=0.041 n=6)      2.580 ± 42%          ~ (p=0.485 n=6)      2.719 ± 47%          ~ (p=0.240 n=6)
EncodeUtf16/gb18030/csv-16               2.316 ± 46%      2.857 ± 47%    +23.37% (p=0.041 n=6)      2.823 ± 46%    +21.89% (p=0.041 n=6)      2.803 ± 45%          ~ (p=0.093 n=6)
EncodeUtf16/gb18030/invalid-16          8.200m ± 34%   632.300m ± 47%  +7610.98% (p=0.002 n=6)   627.700m ± 47%  +7554.88% (p=0.002 n=6)   639.450m ± 48%  +7698.17% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-16              2.345 ± 46%      2.840 ± 47%    +21.08% (p=0.041 n=6)      2.888 ± 48%    +23.15% (p=0.041 n=6)      2.688 ± 44%          ~ (p=0.132 n=6)
EncodeUtf16/gb18030/mixed-16            26.25m ± 48%    774.55m ± 49%  +2850.67% (p=0.002 n=6)    758.05m ± 48%  +2787.81% (p=0.002 n=6)    772.45m ± 49%  +2842.67% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-16         12.15m ± 46%    464.05m ± 48%  +3719.34% (p=0.002 n=6)    447.55m ± 45%  +3583.54% (p=0.002 n=6)    470.80m ± 48%  +3774.90% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-16         2.423 ± 48%      2.853 ± 46%    +17.75% (p=0.041 n=6)      2.921 ± 49%    +20.59% (p=0.041 n=6)      2.889 ± 48%    +19.25% (p=0.041 n=6)
EncodeUtf16/gb18030/web-16               2.289 ± 45%      2.834 ± 45%    +23.80% (p=0.041 n=6)      2.854 ± 48%          ~ (p=0.180 n=6)      2.927 ±  5%    +27.87% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-64             5.784 ± 17%      9.280 ± 13%    +60.43% (p=0.002 n=6)      8.749 ± 10%    +51.25% (p=0.002 n=6)      8.934 ± 18%    +54.46% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-64              71.60m ±  5%   2234.05m ± 10%  +3020.18% (p=0.002 n=6)   2151.55m ± 51%  +2904.96% (p=0.002 n=6)   2288.10m ± 11%  +3095.67% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-64          13.30m ± 45%    382.95m ± 38%  +2779.32% (p=0.002 n=6)    413.65m ± 43%  +3010.15% (p=0.002 n=6)    404.05m ±  7%  +2937.97% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-64              5.828 ± 38%      9.638 ± 13%    +65.39% (p=0.002 n=6)      9.636 ± 12%    +65.34% (p=0.002 n=6)      9.352 ±  9%    +60.48% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-64            21.80m ±  1%    510.85m ±  2%  +2243.35% (p=0.002 n=6)    509.05m ±  3%  +2235.09% (p=0.002 n=6)    502.35m ±  6%  +2204.36% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-64         11.15m ± 12%    548.60m ±  2%  +4820.18% (p=0.002 n=6)    553.70m ± 10%  +4865.92% (p=0.002 n=6)    561.35m ± 13%  +4934.53% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-64        36.05m ± 11%   1493.15m ±  6%  +4041.89% (p=0.002 n=6)   1493.60m ±  8%  +4043.13% (p=0.002 n=6)   1470.05m ±  9%  +3977.81% (p=0.002 n=6)
EncodeUtf16/gb18030/web-64               6.119 ± 13%      9.462 ±  8%    +54.64% (p=0.002 n=6)      9.560 ± 12%    +56.25% (p=0.002 n=6)      9.487 ± 10%    +55.05% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-256             12.25m ±  8%    938.70m ± 29%  +7562.86% (p=0.002 n=6)    921.00m ±  8%  +7418.37% (p=0.002 n=6)    933.10m ±  5%  +7517.14% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-256       14.95m ± 16%    938.40m ± 10%  +6176.92% (p=0.002 n=6)    950.60m ± 14%  +6258.53% (p=0.002 n=6)    940.85m ± 14%  +6193.31% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-256            10.35 ± 10%      20.50 ±  6%    +98.10% (p=0.002 n=6)      19.09 ±  9%    +84.47% (p=0.002 n=6)      20.53 ± 15%    +98.33% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-256         15.05m ±  3%    443.90m ± 11%  +2849.50% (p=0.002 n=6)    438.75m ±  5%  +2815.28% (p=0.002 n=6)    425.55m ±  7%  +2727.57% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-256            39.55m ±  3%   2092.20m ±  7%  +5190.01% (p=0.002 n=6)   2039.40m ±  6%  +5056.51% (p=0.002 n=6)   2066.50m ± 20%  +5125.03% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-256           16.00m ±  3%    431.95m ±  3%  +2599.69% (p=0.002 n=6)    436.55m ±  2%  +2628.44% (p=0.002 n=6)    428.90m ±  5%  +2580.62% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-256        7.250m ±  9%   541.700m ±  7%  +7371.72% (p=0.002 n=6)   549.850m ±  4%  +7484.14% (p=0.002 n=6)   543.400m ±  7%  +7395.17% (p=0.002 n=6)
EncodeUtf16/gb18030/web-256             57.85m ±  9%   2552.10m ± 10%  +4311.58% (p=0.002 n=6)   2630.50m ± 20%  +4447.10% (p=0.002 n=6)   2618.05m ± 14%  +4425.58% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-4096            11.10m ±  4%    709.75m ± 17%  +6294.14% (p=0.002 n=6)    732.35m ± 13%  +6497.75% (p=0.002 n=6)    726.40m ±  5%  +6444.14% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-4096           12.10 ±  7%      31.00 ± 15%   +156.18% (p=0.002 n=6)      30.50 ± 27%   +152.09% (p=0.002 n=6)      31.83 ±  9%   +163.04% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-4096        11.15m ±  7%    419.85m ±  5%  +3665.47% (p=0.002 n=6)    420.35m ±  4%  +3669.96% (p=0.002 n=6)    409.65m ±  5%  +3573.99% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-4096           13.30m ±  4%    898.95m ± 20%  +6659.02% (p=0.002 n=6)    914.75m ± 26%  +6777.82% (p=0.002 n=6)    926.40m ±  5%  +6865.41% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-4096          16.20m ±  7%    415.20m ±  2%  +2462.96% (p=0.002 n=6)    417.15m ± 10%  +2475.00% (p=0.002 n=6)    417.20m ±  3%  +2475.31% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-4096       7.500m ±  9%   568.950m ±  9%  +7486.00% (p=0.002 n=6)   539.850m ±  8%  +7098.00% (p=0.002 n=6)   562.450m ± 10%  +7399.33% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-4096      13.55m ± 23%    886.55m ±  6%  +6442.80% (p=0.002 n=6)    891.20m ± 14%  +6477.12% (p=0.002 n=6)    894.75m ±  5%  +6503.32% (p=0.002 n=6)
EncodeUtf16/gb18030/web-4096            10.00m ± 11%    709.20m ± 16%  +6992.00% (p=0.002 n=6)    709.15m ± 32%  +6991.50% (p=0.002 n=6)    717.05m ± 31%  +7070.50% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-65536          15.15m ±  9%    875.35m ± 31%  +5677.89% (p=0.002 n=6)    908.80m ± 18%  +5898.68% (p=0.002 n=6)    910.15m ±  4%  +5907.59% (p=0.002 n=6)
EncodeUtf16/gb18030/web-65536           9.600m ±  5%   612.750m ± 12%  +6282.81% (p=0.002 n=6)   618.650m ± 20%  +6344.27% (p=0.002 n=6)   601.300m ±  9%  +6163.54% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-65536          12.67 ±  8%      34.82 ± 16%   +174.83% (p=0.002 n=6)      34.17 ±  5%   +169.67% (p=0.002 n=6)      33.31 ± 12%   +162.87% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-65536           12.45m ±  4%    801.10m ±  3%  +6334.54% (p=0.002 n=6)    792.95m ±  4%  +6269.08% (p=0.002 n=6)    789.45m ±  4%  +6240.96% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-65536       11.10m ± 23%    258.60m ± 13%  +2229.73% (p=0.002 n=6)    256.45m ± 23%  +2210.36% (p=0.002 n=6)    227.50m ± 20%  +1949.55% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-65536         15.35m ±  7%    408.75m ±  5%  +2562.87% (p=0.002 n=6)    408.45m ±  3%  +2560.91% (p=0.002 n=6)    411.00m ±  3%  +2577.52% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-65536      7.650m ± 44%   521.350m ± 54%  +6715.03% (p=0.002 n=6)   533.700m ± 54%  +6876.47% (p=0.002 n=6)   546.050m ±  8%  +7037.91% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-65536     13.40m ± 40%    783.10m ± 49%  +5744.03% (p=0.002 n=6)    845.50m ± 54%  +6209.70% (p=0.002 n=6)    833.55m ± 53%  +6120.52% (p=0.002 n=6)
EncodeUtf16/gb18030/web-1048576         9.750m ±  8%   634.500m ± 55%  +6407.69% (p=0.002 n=6)   604.800m ± 37%  +6103.08% (p=0.002 n=6)   640.050m ± 38%  +6464.62% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-1048576        12.43 ±  9%      19.42 ± 14%    +56.20% (p=0.002 n=6)      19.62 ±  6%    +57.86% (p=0.002 n=6)      19.65 ± 10%    +58.06% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-1048576       15.60m ±  8%    402.75m ±  3%  +2481.73% (p=0.002 n=6)    401.80m ±  5%  +2475.64% (p=0.002 n=6)    403.85m ±  4%  +2488.78% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-1048576    7.600m ±  3%   568.450m ±  8%  +7379.61% (p=0.002 n=6)   562.100m ± 36%  +7296.05% (p=0.002 n=6)   504.150m ± 25%  +6533.55% (p=0.002 n=6)
DecodeUtf8/Big5/ascii-16               1226.2m ±  6%     862.5m ± 10%    -29.66% (p=0.002 n=6)     845.8m ±  6%    -31.02% (p=0.002 n=6)     868.6m ± 10%    -29.16% (p=0.002 n=6)
DecodeUtf8/Big5/csv-16                 1214.8m ±  9%     858.8m ±  9%    -29.31% (p=0.002 n=6)     863.6m ± 11%    -28.91% (p=0.002 n=6)     872.3m ± 11%    -28.19% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-16              193.5m ± 30%     274.5m ± 41%    +41.82% (p=0.041 n=6)     249.4m ± 38%    +28.83% (p=0.041 n=6)     271.0m ± 37%    +39.99% (p=0.041 n=6)
DecodeUtf8/Big5/mail-16                1218.2m ± 13%     857.9m ±  7%    -29.57% (p=0.002 n=6)     871.9m ±  9%    -28.43% (p=0.002 n=6)     871.7m ±  9%    -28.44% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-16                386.3m ±  8%     410.2m ±  6%     +6.19% (p=0.024 n=6)     361.6m ± 26%     -6.41% (p=0.026 n=6)     332.2m ± 11%    -14.02% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-16             402.0m ± 11%     324.6m ± 19%    -19.25% (p=0.002 n=6)     295.1m ± 18%    -26.60% (p=0.002 n=6)     268.4m ± 28%    -33.23% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-16           1224.0m ± 14%     854.6m ±  9%    -30.18% (p=0.002 n=6)     874.7m ±  6%    -28.54% (p=0.002 n=6)     841.1m ±  6%    -31.29% (p=0.002 n=6)
DecodeUtf8/Big5/web-16                 1230.3m ± 39%     872.6m ± 21%    -29.07% (p=0.041 n=6)     850.7m ±  7%          ~ (p=0.065 n=6)     876.7m ± 18%    -28.74% (p=0.041 n=6)
DecodeUtf8/Big5/ascii-64                 3.206 ±  4%      3.245 ± 13%          ~ (p=0.699 n=6)      3.231 ± 16%          ~ (p=0.818 n=6)      3.186 ± 19%          ~ (p=0.394 n=6)
DecodeUtf8/Big5/csv-64                 1247.0m ±  3%    1176.6m ±  4%     -5.64% (p=0.002 n=6)     979.8m ±  5%    -21.43% (p=0.002 n=6)     945.9m ±  4%    -24.15% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-64              376.4m ± 34%     498.3m ±  7%    +32.39% (p=0.002 n=6)     436.6m ± 19%          ~ (p=0.093 n=6)     440.7m ±  6%    +17.08% (p=0.002 n=6)
DecodeUtf8/Big5/mail-64                  3.176 ± 29%      3.194 ±  8%          ~ (p=0.818 n=6)      3.192 ±  2%          ~ (p=0.485 n=6)      3.206 ± 16%          ~ (p=0.784 n=6)
DecodeUtf8/Big5/mixed-64                392.5m ±  6%     419.8m ±  4%     +6.97% (p=0.026 n=6)     385.4m ± 23%     -1.80% (p=0.041 n=6)     349.0m ±  7%    -11.07% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-64             580.5m ±  6%     402.9m ± 11%    -30.59% (p=0.002 n=6)     342.6m ±  8%    -40.97% (p=0.002 n=6)     331.4m ± 22%    -42.91% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-64           1008.6m ± 18%     754.5m ± 17%    -25.20% (p=0.002 n=6)     678.4m ±  5%    -32.74% (p=0.002 n=6)     627.9m ± 23%    -37.75% (p=0.002 n=6)
DecodeUtf8/Big5/web-64                   3.049 ± 10%      3.173 ±  7%          ~ (p=0.699 n=6)      3.234 ±  5%          ~ (p=0.240 n=6)      3.157 ±  7%          ~ (p=0.589 n=6)
DecodeUtf8/Big5/subtitles-256           768.8m ±  6%     630.4m ± 18%    -18.00% (p=0.002 n=6)     548.5m ±  4%    -28.65% (p=0.002 n=6)     499.9m ±  4%    -34.97% (p=0.002 n=6)
DecodeUtf8/Big5/ascii-256                6.066 ± 25%     10.061 ± 11%    +65.85% (p=0.002 n=6)     10.123 ± 11%    +66.87% (p=0.002 n=6)      9.832 ±  4%    +62.08% (p=0.002 n=6)
DecodeUtf8/Big5/csv-256                 740.5m ±  7%     575.0m ± 18%    -22.34% (p=0.002 n=6)     514.1m ± 16%    -30.56% (p=0.002 n=6)     471.8m ±  8%    -36.28% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-256             274.1m ± 18%     339.5m ±  8%    +23.86% (p=0.002 n=6)     324.9m ± 20%    +18.53% (p=0.041 n=6)     334.4m ±  8%    +22.00% (p=0.002 n=6)
DecodeUtf8/Big5/mail-256               1372.2m ± 21%     999.6m ± 15%    -27.16% (p=0.004 n=6)     955.5m ± 20%    -30.37% (p=0.002 n=6)     853.1m ± 22%    -37.83% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-256               371.1m ± 20%     386.2m ± 12%          ~ (p=0.485 n=6)     364.1m ± 13%          ~ (p=0.589 n=6)     310.7m ± 20%    -16.26% (p=0.041 n=6)
DecodeUtf8/Big5/nonascii-256            593.9m ± 11%     439.6m ± 18%    -25.97% (p=0.002 n=6)     382.5m ± 28%    -35.59% (p=0.002 n=6)     345.8m ±  8%    -41.78% (p=0.002 n=6)
DecodeUtf8/Big5/web-256                1544.6m ±  5%    1129.5m ±  8%    -26.87% (p=0.002 n=6)     948.3m ± 13%    -38.61% (p=0.002 n=6)     937.7m ± 26%    -39.29% (p=0.002 n=6)
DecodeUtf8/Big5/csv-4096                655.8m ± 41%     513.0m ± 17%          ~ (p=0.065 n=6)     448.1m ± 30%    -31.67% (p=0.041 n=6)     417.3m ± 39%    -36.36% (p=0.041 n=6)
DecodeUtf8/Big5/ascii-4096               8.473 ± 40%     18.493 ± 38%   +118.25% (p=0.002 n=6)     19.484 ± 42%   +129.94% (p=0.002 n=6)     18.843 ± 40%   +122.38% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-4096            323.6m ± 42%     391.1m ± 36%    +20.86% (p=0.041 n=6)     375.6m ± 36%    +16.07% (p=0.037 n=6)     356.2m ± 39%          ~ (p=0.180 n=6)
DecodeUtf8/Big5/mail-4096               857.4m ± 41%     556.4m ± 29%          ~ (p=0.065 n=6)     542.4m ± 37%          ~ (p=0.093 n=6)     490.9m ± 26%    -42.74% (p=0.015 n=6)
DecodeUtf8/Big5/mixed-4096              261.4m ± 26%     372.1m ± 24%    +42.30% (p=0.017 n=6)     348.3m ± 27%    +33.24% (p=0.015 n=6)     334.0m ± 28%          ~ (p=0.065 n=6)
DecodeUtf8/Big5/nonascii-4096           507.7m ± 10%     458.2m ± 42%     -9.75% (p=0.041 n=6)     381.2m ± 37%    -24.92% (p=0.002 n=6)     346.7m ± 21%    -31.73% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-4096          707.3m ± 13%     522.6m ± 14%    -26.12% (p=0.002 n=6)     479.0m ± 13%    -32.27% (p=0.002 n=6)     439.6m ± 19%    -37.86% (p=0.002 n=6)
DecodeUtf8/Big5/web-4096                674.2m ±  6%     496.5m ± 14%    -26.36% (p=0.002 n=6)     435.4m ± 20%    -35.41% (p=0.002 n=6)     402.9m ±  6%    -40.24% (p=0.002 n=6)
DecodeUtf8/Big5/csv-65536               472.6m ±  8%     500.6m ± 11%          ~ (p=0.093 n=6)     446.4m ±  6%     -5.53% (p=0.026 n=6)     405.1m ± 33%    -14.28% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-65536         337.1m ± 17%     467.5m ± 25%    +38.66% (p=0.004 n=6)     476.2m ± 18%    +41.24% (p=0.002 n=6)     434.5m ± 20%    +28.89% (p=0.009 n=6)
DecodeUtf8/Big5/web-65536               332.9m ± 13%     481.7m ± 45%          ~ (p=0.065 n=6)     397.3m ± 38%          ~ (p=0.065 n=6)     361.9m ±  9%     +8.71% (p=0.026 n=6)
DecodeUtf8/Big5/ascii-65536              8.243 ± 31%     20.438 ± 37%   +147.95% (p=0.002 n=6)     20.268 ± 22%   +145.88% (p=0.002 n=6)     18.817 ± 37%   +128.28% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-65536           100.8m ± 14%     184.4m ±  6%    +82.98% (p=0.002 n=6)     170.5m ± 11%    +69.28% (p=0.002 n=6)     170.2m ± 13%    +68.93% (p=0.002 n=6)
DecodeUtf8/Big5/mail-65536              402.3m ±  8%     614.9m ± 19%    +52.84% (p=0.002 n=6)     491.2m ± 14%    +22.08% (p=0.002 n=6)     488.2m ± 27%          ~ (p=0.132 n=6)
DecodeUtf8/Big5/mixed-65536             214.6m ± 18%     347.0m ± 22%    +61.76% (p=0.002 n=6)     361.2m ± 19%    +68.38% (p=0.002 n=6)     301.2m ± 15%    +40.36% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-65536          277.4m ±  9%     427.2m ± 31%    +54.02% (p=0.009 n=6)     349.8m ± 15%    +26.10% (p=0.009 n=6)     330.0m ± 31%          ~ (p=0.065 n=6)
DecodeUtf8/Big5/ascii-1048576            7.975 ± 34%     16.674 ± 37%   +109.07% (p=0.002 n=6)     16.957 ± 24%   +112.61% (p=0.002 n=6)     15.566 ± 27%    +95.18% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-1048576           229.2m ± 49%     349.8m ± 47%    +52.67% (p=0.026 n=6)     340.2m ± 51%    +48.46% (p=0.026 n=6)     329.3m ± 52%          ~ (p=0.180 n=6)
DecodeUtf8/Big5/nonascii-1048576        247.5m ± 30%     422.2m ± 40%    +70.53% (p=0.015 n=6)     348.2m ± 35%    +40.68% (p=0.015 n=6)     312.6m ± 23%          ~ (p=0.093 n=6)
DecodeUtf8/Big5/web-1048576             314.6m ± 24%     430.9m ± 19%    +36.96% (p=0.002 n=6)     393.0m ± 40%          ~ (p=0.065 n=6)     346.3m ± 34%          ~ (p=0.589 n=6)
DecodeUtf16/Big5/ascii-16               926.8m ± 30%     787.1m ± 18%          ~ (p=0.589 n=6)     787.9m ± 13%          ~ (p=0.818 n=6)     776.1m ± 17%          ~ (p=0.485 n=6)
DecodeUtf16/Big5/csv-16                1126.3m ±  6%     817.9m ± 18%    -27.38% (p=0.002 n=6)     783.9m ± 20%    -30.40% (p=0.002 n=6)     810.1m ± 23%    -28.07% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-16             181.4m ±  9%     247.4m ± 38%          ~ (p=0.310 n=6)     260.3m ± 15%    +43.50% (p=0.002 n=6)     275.1m ± 34%    +51.68% (p=0.009 n=6)
DecodeUtf16/Big5/mail-16               1143.3m ± 13%     815.7m ±  4%    -28.65% (p=0.002 n=6)     827.4m ±  1%    -27.63% (p=0.002 n=6)     824.9m ±  7%    -27.85% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-16               413.4m ±  8%     423.2m ± 16%          ~ (p=0.818 n=6)     405.5m ±  9%          ~ (p=0.589 n=6)     355.6m ± 13%    -13.99% (p=0.015 n=6)
DecodeUtf16/Big5/nonascii-16            475.0m ± 14%     393.9m ± 14%    -17.07% (p=0.009 n=6)     337.3m ± 16%    -28.98% (p=0.002 n=6)     312.4m ± 14%    -34.24% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-16          1121.2m ± 40%     781.4m ± 13%          ~ (p=0.180 n=6)     811.5m ± 11%          ~ (p=0.240 n=6)     826.5m ± 14%          ~ (p=0.240 n=6)
DecodeUtf16/Big5/web-16                1166.5m ± 25%     807.3m ± 11%    -30.80% (p=0.002 n=6)     825.9m ± 14%    -29.20% (p=0.002 n=6)     806.5m ± 10%    -30.86% (p=0.002 n=6)
DecodeUtf16/Big5/ascii-64                2.726 ± 33%      2.892 ± 25%          ~ (p=0.937 n=6)      2.912 ± 26%          ~ (p=0.180 n=6)      2.989 ± 27%          ~ (p=0.394 n=6)
DecodeUtf16/Big5/csv-64                1118.6m ± 42%    1124.7m ± 35%          ~ (p=0.818 n=6)     920.2m ± 41%          ~ (p=0.065 n=6)     868.4m ± 43%    -22.37% (p=0.041 n=6)
DecodeUtf16/Big5/invalid-64             323.3m ± 22%     470.5m ± 35%          ~ (p=0.065 n=6)     440.7m ± 35%    +36.31% (p=0.041 n=6)     447.0m ± 38%          ~ (p=0.132 n=6)
DecodeUtf16/Big5/mail-64                 2.790 ± 32%      3.006 ± 26%          ~ (p=0.132 n=6)      2.932 ± 24%          ~ (p=0.240 n=6)      2.809 ± 21%          ~ (p=0.589 n=6)
DecodeUtf16/Big5/mixed-64               435.4m ± 43%     437.6m ± 35%          ~ (p=0.589 n=6)     372.6m ± 28%          ~ (p=0.699 n=6)     402.5m ± 41%          ~ (p=0.240 n=6)
DecodeUtf16/Big5/nonascii-64            538.1m ± 30%     451.2m ± 37%          ~ (p=0.240 n=6)     358.5m ± 27%    -33.38% (p=0.041 n=6)     352.9m ± 33%    -34.42% (p=0.004 n=6)
DecodeUtf16/Big5/subtitles-64          1135.1m ± 41%     878.4m ± 40%          ~ (p=0.093 n=6)     752.6m ± 37%    -33.70% (p=0.026 n=6)     710.9m ± 40%    -37.37% (p=0.026 n=6)
DecodeUtf16/Big5/web-64                  2.910 ± 36%      3.112 ± 27%     +6.92% (p=0.041 n=6)      3.097 ± 27%          ~ (p=0.240 n=6)      3.064 ± 27%          ~ (p=0.240 n=6)
DecodeUtf16/Big5/subtitles-256          957.1m ± 43%     707.3m ± 39%    -26.09% (p=0.041 n=6)     643.7m ± 40%    -32.75% (p=0.041 n=6)     593.8m ± 40%    -37.96% (p=0.041 n=6)
DecodeUtf16/Big5/ascii-256               5.340 ± 37%      9.432 ± 39%    +76.62% (p=0.002 n=6)      9.207 ± 36%    +72.42% (p=0.002 n=6)      9.212 ± 35%    +72.51% (p=0.002 n=6)
DecodeUtf16/Big5/csv-256                845.5m ± 51%     578.0m ± 43%          ~ (p=0.093 n=6)     481.4m ± 41%          ~ (p=0.065 n=6)     544.9m ± 53%          ~ (p=0.093 n=6)
DecodeUtf16/Big5/invalid-256            279.1m ± 41%     367.5m ± 48%          ~ (p=0.132 n=6)     323.6m ± 44%          ~ (p=0.180 n=6)     347.2m ± 50%          ~ (p=0.180 n=6)
DecodeUtf16/Big5/mail-256              1482.9m ± 47%     962.8m ± 37%          ~ (p=0.093 n=6)    1134.4m ± 35%          ~ (p=0.240 n=6)    1191.5m ± 47%          ~ (p=0.240 n=6)
DecodeUtf16/Big5/mixed-256              434.4m ± 44%     382.4m ± 23%          ~ (p=0.065 n=6)     354.2m ± 26%          ~ (p=0.065 n=6)     377.7m ± 35%          ~ (p=0.065 n=6)
DecodeUtf16/Big5/nonascii-256           693.9m ± 39%     489.9m ± 39%    -29.39% (p=0.026 n=6)     433.9m ± 37%    -37.46% (p=0.026 n=6)     387.5m ± 39%    -44.16% (p=0.002 n=6)
DecodeUtf16/Big5/web-256                 1.693 ± 39%      1.118 ± 31%    -33.97% (p=0.041 n=6)      1.189 ± 35%    -29.78% (p=0.041 n=6)      1.204 ± 43%    -28.88% (p=0.041 n=6)
DecodeUtf16/Big5/csv-4096               785.0m ± 39%     488.4m ± 29%    -37.78% (p=0.026 n=6)     461.5m ± 28%          ~ (p=0.065 n=6)     460.8m ± 36%    -41.29% (p=0.015 n=6)
DecodeUtf16/Big5/ascii-4096              6.696 ± 27%     17.633 ± 42%   +163.32% (p=0.002 n=6)     17.279 ± 42%   +158.03% (p=0.002 n=6)     17.558 ± 38%   +162.20% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-4096           312.8m ± 45%     398.6m ± 33%    +27.45% (p=0.026 n=6)     388.6m ± 35%    +24.25% (p=0.026 n=6)     376.8m ± 39%    +20.44% (p=0.026 n=6)
DecodeUtf16/Big5/mail-4096             1045.0m ± 41%     714.4m ± 39%    -31.63% (p=0.041 n=6)     662.8m ± 36%    -36.57% (p=0.041 n=6)     656.4m ± 40%    -37.18% (p=0.041 n=6)
DecodeUtf16/Big5/mixed-4096             363.7m ± 42%     410.6m ± 25%    +12.91% (p=0.022 n=6)     407.3m ± 34%    +12.00% (p=0.041 n=6)     391.2m ± 34%          ~ (p=0.065 n=6)
DecodeUtf16/Big5/nonascii-4096          718.1m ± 40%     535.7m ± 42%    -25.40% (p=0.041 n=6)     457.6m ± 38%    -36.27% (p=0.041 n=6)     395.1m ± 36%    -44.98% (p=0.004 n=6)
DecodeUtf16/Big5/subtitles-4096         941.6m ± 43%     628.3m ± 39%    -33.27% (p=0.041 n=6)     569.0m ± 37%    -39.58% (p=0.022 n=6)     556.1m ± 41%    -40.94% (p=0.026 n=6)
DecodeUtf16/Big5/web-4096               833.1m ± 40%     541.1m ± 35%    -35.06% (p=0.041 n=6)     518.9m ± 36%    -37.72% (p=0.026 n=6)     490.9m ± 40%    -41.08% (p=0.002 n=6)
DecodeUtf16/Big5/csv-65536              741.0m ± 44%     547.1m ± 38%    -26.17% (p=0.041 n=6)     507.9m ± 36%    -31.46% (p=0.041 n=6)     488.4m ± 41%    -34.09% (p=0.026 n=6)
DecodeUtf16/Big5/subtitles-65536        454.6m ± 33%     626.8m ± 39%    +37.85% (p=0.041 n=6)     531.7m ± 34%          ~ (p=0.065 n=6)     515.7m ± 36%          ~ (p=0.180 n=6)
DecodeUtf16/Big5/web-65536              426.5m ± 34%     515.0m ± 39%    +20.74% (p=0.041 n=6)     478.5m ± 39%    +12.19% (p=0.041 n=6)     447.8m ± 41%          ~ (p=0.310 n=6)
DecodeUtf16/Big5/ascii-65536             7.484 ± 12%     17.884 ±  4%   +138.97% (p=0.002 n=6)     18.071 ± 34%   +141.47% (p=0.002 n=6)     17.166 ± 29%   +129.37% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-65536          113.0m ± 26%     180.4m ± 18%    +59.69% (p=0.002 n=6)     183.3m ± 25%    +62.21% (p=0.002 n=6)     176.5m ± 28%    +56.19% (p=0.002 n=6)
DecodeUtf16/Big5/mail-65536             427.0m ± 24%     681.5m ± 33%    +59.60% (p=0.009 n=6)     599.8m ± 37%          ~ (p=0.132 n=6)     596.7m ± 44%          ~ (p=0.180 n=6)
DecodeUtf16/Big5/mixed-65536            244.0m ± 17%     409.4m ± 18%    +67.77% (p=0.002 n=6)     396.6m ± 20%    +62.53% (p=0.002 n=6)     380.8m ± 17%    +56.03% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-65536         469.7m ± 22%     499.6m ± 32%          ~ (p=0.589 n=6)     399.4m ± 25%          ~ (p=0.589 n=6)     437.6m ± 33%          ~ (p=0.132 n=6)
DecodeUtf16/Big5/ascii-1048576           6.862 ± 17%      8.811 ± 12%    +28.41% (p=0.002 n=6)      8.904 ±  5%    +29.76% (p=0.002 n=6)      9.098 ±  9%    +32.58% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-1048576          245.6m ±  8%     372.0m ± 24%    +51.47% (p=0.002 n=6)     400.6m ± 11%    +63.11% (p=0.002 n=6)     370.3m ± 14%    +50.77% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-1048576       426.4m ± 24%     560.9m ± 18%    +31.55% (p=0.009 n=6)     486.7m ± 16%          ~ (p=0.065 n=6)     438.4m ± 21%          ~ (p=0.589 n=6)
DecodeUtf16/Big5/web-1048576            422.8m ± 21%     520.9m ± 16%    +23.21% (p=0.004 n=6)     444.6m ± 20%          ~ (p=0.180 n=6)     441.6m ±  3%     +4.45% (p=0.041 n=6)
EncodeUtf8/Big5/ascii-16                 1.193 ± 45%      1.046 ± 12%          ~ (p=0.065 n=6)      1.030 ±  7%          ~ (p=0.065 n=6)      1.046 ±  3%          ~ (p=0.065 n=6)
EncodeUtf8/Big5/csv-16                   1.220 ± 15%      1.031 ±  5%    -15.50% (p=0.009 n=6)      1.015 ± 29%    -16.74% (p=0.009 n=6)      1.046 ± 14%    -14.20% (p=0.026 n=6)
EncodeUtf8/Big5/invalid-16              3.200m ±  3%   294.750m ±  8%  +9110.94% (p=0.002 n=6)   274.100m ± 10%  +8465.62% (p=0.002 n=6)   292.900m ± 52%  +9053.12% (p=0.002 n=6)
EncodeUtf8/Big5/mail-16                1285.0m ±  8%    1042.6m ± 16%    -18.87% (p=0.002 n=6)     985.5m ±  9%    -23.31% (p=0.002 n=6)    1049.1m ± 28%    -18.36% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-16                165.1m ± 52%     417.2m ± 16%   +152.77% (p=0.002 n=6)     440.3m ± 13%   +166.77% (p=0.002 n=6)     379.4m ± 23%   +129.87% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-16             30.65m ± 43%    400.50m ± 49%  +1206.69% (p=0.002 n=6)    407.15m ± 49%  +1228.38% (p=0.002 n=6)    413.60m ± 50%  +1249.43% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-16           1284.3m ± 49%    1040.1m ± 28%          ~ (p=0.240 n=6)     993.9m ± 25%          ~ (p=0.180 n=6)    1059.0m ± 30%          ~ (p=0.240 n=6)
EncodeUtf8/Big5/web-16                   1.262 ± 50%      1.059 ± 29%          ~ (p=0.132 n=6)      1.043 ± 13%          ~ (p=0.132 n=6)      1.065 ±  9%          ~ (p=0.093 n=6)
EncodeUtf8/Big5/ascii-64                 3.149 ±  3%      3.763 ±  8%    +19.49% (p=0.002 n=6)      3.972 ± 11%    +26.10% (p=0.002 n=6)      3.938 ±  4%    +25.03% (p=0.002 n=6)
EncodeUtf8/Big5/csv-64                  88.65m ±  3%   1085.70m ±  4%  +1124.70% (p=0.002 n=6)   1087.05m ±  5%  +1126.23% (p=0.002 n=6)   1110.55m ± 14%  +1152.74% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-64              5.100m ±  2%   339.800m ± 12%  +6562.75% (p=0.002 n=6)   337.800m ±  7%  +6523.53% (p=0.002 n=6)   335.550m ±  6%  +6479.41% (p=0.002 n=6)
EncodeUtf8/Big5/mail-64                  3.135 ± 25%      3.830 ±  9%    +22.17% (p=0.002 n=6)      3.769 ± 25%          ~ (p=0.180 n=6)      3.678 ± 29%    +17.33% (p=0.041 n=6)
EncodeUtf8/Big5/mixed-64                34.65m ± 15%    446.75m ±  7%  +1189.32% (p=0.002 n=6)    458.45m ±  6%  +1223.09% (p=0.002 n=6)    452.45m ± 11%  +1205.77% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-64             19.65m ±  6%    501.75m ±  6%  +2453.44% (p=0.002 n=6)    513.10m ±  5%  +2511.20% (p=0.002 n=6)    513.35m ±  2%  +2512.47% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-64            44.10m ± 11%    764.10m ± 20%  +1632.65% (p=0.002 n=6)    792.40m ±  8%  +1696.83% (p=0.002 n=6)    796.80m ± 20%  +1706.80% (p=0.002 n=6)
EncodeUtf8/Big5/web-64                   3.033 ±  8%      3.635 ± 16%    +19.87% (p=0.015 n=6)      3.680 ± 11%    +21.35% (p=0.002 n=6)      3.793 ± 20%    +25.09% (p=0.015 n=6)
EncodeUtf8/Big5/subtitles-256           26.70m ± 22%    630.00m ± 12%  +2259.55% (p=0.002 n=6)    699.25m ± 14%  +2518.91% (p=0.002 n=6)    690.60m ± 16%  +2486.52% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-256                5.122 ± 11%     10.912 ± 16%   +113.05% (p=0.002 n=6)     10.839 ± 28%   +111.63% (p=0.002 n=6)     10.833 ± 34%   +111.52% (p=0.002 n=6)
EncodeUtf8/Big5/csv-256                 24.00m ± 26%    630.00m ± 36%  +2525.00% (p=0.002 n=6)    669.85m ± 39%  +2691.04% (p=0.002 n=6)    677.30m ± 24%  +2722.08% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-256             3.700m ± 11%   328.300m ± 36%  +8772.97% (p=0.002 n=6)   325.400m ± 32%  +8694.59% (p=0.002 n=6)   331.000m ±  7%  +8845.95% (p=0.002 n=6)
EncodeUtf8/Big5/mail-256                46.20m ± 35%   1136.60m ±  4%  +2360.17% (p=0.002 n=6)   1145.55m ±  3%  +2379.55% (p=0.002 n=6)   1131.75m ±  7%  +2349.68% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-256               27.25m ±  5%    472.75m ±  2%  +1634.86% (p=0.002 n=6)    468.50m ± 32%  +1619.27% (p=0.002 n=6)    469.75m ±  4%  +1623.85% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-256            19.25m ± 21%    521.15m ± 23%  +2607.27% (p=0.002 n=6)    531.10m ±  3%  +2658.96% (p=0.002 n=6)    532.50m ± 29%  +2666.23% (p=0.002 n=6)
EncodeUtf8/Big5/web-256                 49.10m ± 23%   1205.90m ±  7%  +2356.01% (p=0.002 n=6)   1160.65m ±  6%  +2263.85% (p=0.002 n=6)   1113.50m ± 13%  +2167.82% (p=0.002 n=6)
EncodeUtf8/Big5/csv-4096                18.90m ±  1%    604.85m ±  2%  +3100.26% (p=0.002 n=6)    584.50m ±  9%  +2992.59% (p=0.002 n=6)    613.15m ± 18%  +3144.18% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-4096               6.307 ±  5%     19.141 ± 34%   +203.48% (p=0.002 n=6)     18.567 ± 19%   +194.38% (p=0.002 n=6)     20.050 ± 13%   +217.89% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-4096            4.450m ±  6%   356.350m ± 35%  +7907.87% (p=0.002 n=6)   353.450m ±  3%  +7842.70% (p=0.002 n=6)   354.250m ±  6%  +7860.67% (p=0.002 n=6)
EncodeUtf8/Big5/mail-4096               23.30m ± 30%    737.75m ± 20%  +3066.31% (p=0.002 n=6)    749.85m ± 22%  +3118.24% (p=0.002 n=6)    737.35m ± 16%  +3064.59% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-4096              23.15m ± 20%    466.65m ± 26%  +1915.77% (p=0.002 n=6)    469.15m ±  4%  +1926.57% (p=0.002 n=6)    479.15m ± 16%  +1969.76% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-4096           16.65m ± 19%    538.60m ± 18%  +3134.83% (p=0.002 n=6)    558.05m ± 37%  +3251.65% (p=0.002 n=6)    548.80m ± 15%  +3196.10% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-4096          21.30m ± 22%    663.35m ±  2%  +3014.32% (p=0.002 n=6)    656.95m ±  7%  +2984.27% (p=0.002 n=6)    648.75m ±  7%  +2945.77% (p=0.002 n=6)
EncodeUtf8/Big5/web-4096                19.25m ± 14%    588.75m ± 12%  +2958.44% (p=0.002 n=6)    561.90m ± 18%  +2818.96% (p=0.002 n=6)    604.45m ± 10%  +3040.00% (p=0.002 n=6)
EncodeUtf8/Big5/csv-65536               17.55m ±  7%    588.25m ±  4%  +3251.85% (p=0.002 n=6)    558.90m ± 10%  +3084.62% (p=0.002 n=6)    563.80m ± 14%  +3112.54% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-65536         20.20m ±  1%    648.70m ± 14%  +3111.39% (p=0.002 n=6)    641.15m ±  5%  +3074.01% (p=0.002 n=6)    635.00m ± 15%  +3043.56% (p=0.002 n=6)
EncodeUtf8/Big5/web-65536               16.70m ± 21%    500.90m ± 14%  +2899.40% (p=0.002 n=6)    542.90m ±  7%  +3150.90% (p=0.002 n=6)    544.35m ± 25%  +3159.58% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-65536              6.613 ±  5%     19.001 ± 28%   +187.31% (p=0.002 n=6)     21.011 ± 11%   +217.70% (p=0.002 n=6)     21.781 ±  4%   +229.35% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-65536           4.750m ± 26%   197.950m ± 15%  +4067.37% (p=0.002 n=6)   197.150m ±  4%  +4050.53% (p=0.002 n=6)   193.200m ± 15%  +3967.37% (p=0.002 n=6)
EncodeUtf8/Big5/mail-65536              22.30m ±  5%    703.15m ±  4%  +3053.14% (p=0.002 n=6)    706.70m ± 13%  +3069.06% (p=0.002 n=6)    688.85m ± 11%  +2989.01% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-65536             21.85m ±  8%    462.25m ±  2%  +2015.56% (p=0.002 n=6)    461.95m ±  7%  +2014.19% (p=0.002 n=6)    460.10m ± 10%  +2005.72% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-65536          16.00m ±  6%    543.70m ± 20%  +3298.13% (p=0.002 n=6)    521.05m ± 28%  +3156.56% (p=0.002 n=6)    533.10m ± 13%  +3231.87% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-1048576            6.463 ±  8%     17.471 ± 34%   +170.30% (p=0.002 n=6)     17.587 ± 22%   +172.10% (p=0.002 n=6)     18.373 ± 12%   +184.27% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-1048576           21.45m ±  5%    461.85m ±  9%  +2053.15% (p=0.002 n=6)    450.25m ±  5%  +1999.07% (p=0.002 n=6)    459.05m ±  6%  +2040.09% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-1048576        15.60m ± 19%    536.25m ± 15%  +3337.50% (p=0.002 n=6)    526.40m ±  7%  +3274.36% (p=0.002 n=6)    544.50m ±  5%  +3390.38% (p=0.002 n=6)
EncodeUtf8/Big5/web-1048576             17.00m ±  4%    551.95m ± 11%  +3146.76% (p=0.002 n=6)    560.75m ±  4%  +3198.53% (p=0.002 n=6)    551.85m ± 17%  +3146.18% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-16                2.420 ±  8%      2.080 ±  5%    -14.06% (p=0.002 n=6)      2.048 ±  8%    -15.38% (p=0.002 n=6)      2.087 ±  5%    -13.77% (p=0.002 n=6)
EncodeUtf16/Big5/csv-16                  2.447 ±  8%      2.069 ±  4%    -15.47% (p=0.002 n=6)      2.123 ± 10%    -13.24% (p=0.002 n=6)      2.107 ±  4%    -13.91% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-16             3.800m ±  5%   290.700m ±  7%  +7550.00% (p=0.002 n=6)   292.050m ± 22%  +7585.53% (p=0.002 n=6)   290.400m ±  3%  +7542.11% (p=0.002 n=6)
EncodeUtf16/Big5/mail-16                 2.363 ± 33%      2.094 ± 22%          ~ (p=0.310 n=6)      2.060 ± 33%          ~ (p=0.240 n=6)      2.089 ± 24%          ~ (p=0.310 n=6)
EncodeUtf16/Big5/mixed-16               191.1m ±  5%     719.9m ± 32%   +276.59% (p=0.002 n=6)     713.6m ± 38%   +273.32% (p=0.002 n=6)     657.6m ±  8%   +244.02% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-16            20.95m ±  8%    443.45m ± 25%  +2016.71% (p=0.002 n=6)    441.75m ±  5%  +2008.59% (p=0.002 n=6)    440.70m ±  4%  +2003.58% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-16            2.444 ±  3%      2.114 ±  3%    -13.48% (p=0.002 n=6)      2.112 ±  5%    -13.57% (p=0.002 n=6)      2.112 ±  2%    -13.56% (p=0.002 n=6)
EncodeUtf16/Big5/web-16                  2.380 ± 14%      2.123 ± 12%    -10.80% (p=0.041 n=6)      2.124 ±  2%          ~ (p=0.065 n=6)      2.116 ±  4%    -11.08% (p=0.026 n=6)
EncodeUtf16/Big5/ascii-64                6.434 ±  5%      7.645 ±  9%    +18.82% (p=0.002 n=6)      7.718 ± 30%          ~ (p=0.065 n=6)      7.686 ±  4%    +19.45% (p=0.002 n=6)
EncodeUtf16/Big5/csv-64                 132.7m ± 45%    2412.7m ± 47%  +1718.16% (p=0.002 n=6)    2342.8m ± 10%  +1665.45% (p=0.002 n=6)    2385.1m ±  8%  +1697.36% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-64             6.700m ± 22%   531.300m ± 27%  +7829.85% (p=0.002 n=6)   555.850m ±  7%  +8196.27% (p=0.002 n=6)   545.450m ± 11%  +8041.04% (p=0.002 n=6)
EncodeUtf16/Big5/mail-64                 6.194 ± 37%      7.504 ± 27%          ~ (p=0.065 n=6)      7.476 ± 18%    +20.70% (p=0.015 n=6)      7.650 ± 27%    +23.50% (p=0.041 n=6)
EncodeUtf16/Big5/mixed-64               36.65m ±  3%    500.50m ±  8%  +1265.62% (p=0.002 n=6)    502.20m ± 19%  +1270.26% (p=0.002 n=6)    498.25m ± 10%  +1259.48% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-64            13.55m ±  3%    577.90m ± 17%  +4164.94% (p=0.002 n=6)    575.85m ±  4%  +4149.82% (p=0.002 n=6)    583.85m ± 10%  +4208.86% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-64           56.25m ± 15%   1565.45m ± 19%  +2683.02% (p=0.002 n=6)   1525.85m ± 17%  +2612.62% (p=0.002 n=6)   1575.85m ± 15%  +2701.51% (p=0.002 n=6)
EncodeUtf16/Big5/web-64                  6.068 ± 35%      7.423 ±  5%    +22.32% (p=0.002 n=6)      7.741 ±  4%    +27.58% (p=0.002 n=6)      7.619 ±  3%    +25.55% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-256          26.15m ± 27%   1121.40m ±  6%  +4188.34% (p=0.002 n=6)   1083.45m ± 12%  +4043.21% (p=0.002 n=6)   1078.50m ± 23%  +4024.28% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-256               10.16 ± 24%      20.25 ± 18%    +99.37% (p=0.002 n=6)      20.11 ± 35%    +98.04% (p=0.002 n=6)      20.06 ± 44%    +97.51% (p=0.002 n=6)
EncodeUtf16/Big5/csv-256                22.45m ± 45%    973.65m ± 47%  +4236.97% (p=0.002 n=6)   1061.35m ± 23%  +4627.62% (p=0.002 n=6)   1022.45m ± 50%  +4454.34% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-256            4.650m ± 40%   350.700m ± 42%  +7441.94% (p=0.002 n=6)   398.650m ± 50%  +8473.12% (p=0.002 n=6)   407.950m ± 50%  +8673.12% (p=0.002 n=6)
EncodeUtf16/Big5/mail-256               61.15m ± 46%   2503.85m ± 54%  +3994.60% (p=0.002 n=6)   2306.90m ± 13%  +3672.53% (p=0.002 n=6)   2315.20m ± 14%  +3686.10% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-256              25.90m ± 25%    416.85m ± 10%  +1509.46% (p=0.002 n=6)    413.75m ± 10%  +1497.49% (p=0.002 n=6)    420.50m ±  5%  +1523.55% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-256           12.50m ± 44%    602.55m ± 56%  +4720.40% (p=0.002 n=6)    541.20m ± 50%  +4229.60% (p=0.002 n=6)    612.15m ± 57%  +4797.20% (p=0.002 n=6)
EncodeUtf16/Big5/web-256                73.50m ± 44%   2722.90m ± 55%  +3604.63% (p=0.002 n=6)   2690.85m ± 55%  +3561.02% (p=0.002 n=6)   2568.20m ± 53%  +3394.15% (p=0.002 n=6)
EncodeUtf16/Big5/csv-4096               16.05m ± 46%    810.85m ± 53%  +4952.02% (p=0.002 n=6)    813.55m ± 53%  +4968.85% (p=0.002 n=6)    792.85m ± 52%  +4839.88% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-4096              12.44 ± 41%      33.25 ± 43%   +167.36% (p=0.002 n=6)      30.79 ± 37%   +147.62% (p=0.002 n=6)      28.40 ± 40%   +128.35% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-4096           5.100m ± 24%   435.550m ± 14%  +8440.20% (p=0.002 n=6)   410.050m ± 32%  +7940.20% (p=0.002 n=6)   426.900m ±  7%  +8270.59% (p=0.002 n=6)
EncodeUtf16/Big5/mail-4096              23.00m ± 30%   1243.45m ± 18%  +5306.30% (p=0.002 n=6)   1226.20m ±  9%  +5231.30% (p=0.002 n=6)   1151.30m ± 24%  +4905.65% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-4096             22.60m ±  7%    409.05m ±  5%  +1709.96% (p=0.002 n=6)    410.65m ±  3%  +1717.04% (p=0.002 n=6)    407.35m ±  2%  +1702.43% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-4096          10.55m ± 15%    597.75m ± 11%  +5565.88% (p=0.002 n=6)    616.15m ±  8%  +5740.28% (p=0.002 n=6)    566.25m ± 14%  +5267.30% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-4096         19.55m ± 14%    981.70m ± 24%  +4921.48% (p=0.002 n=6)    998.05m ± 26%  +5005.12% (p=0.002 n=6)    990.05m ± 20%  +4964.19% (p=0.002 n=6)
EncodeUtf16/Big5/web-4096               15.65m ± 11%    778.95m ± 40%  +4877.32% (p=0.002 n=6)    773.90m ± 40%  +4845.05% (p=0.002 n=6)    801.40m ± 15%  +5020.77% (p=0.002 n=6)
EncodeUtf16/Big5/csv-65536              15.50m ± 46%    792.10m ± 41%  +5010.32% (p=0.002 n=6)    792.95m ± 41%  +5015.81% (p=0.002 n=6)    770.95m ± 54%  +4873.87% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-65536        17.85m ± 45%    923.20m ± 52%  +5071.99% (p=0.002 n=6)    925.35m ± 52%  +5084.03% (p=0.002 n=6)    910.80m ± 52%  +5002.52% (p=0.002 n=6)
EncodeUtf16/Big5/web-65536              13.35m ±  6%    705.85m ± 15%  +5187.27% (p=0.002 n=6)    729.90m ± 10%  +5367.42% (p=0.002 n=6)    689.80m ± 32%  +5067.04% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-65536             13.87 ± 14%      35.76 ± 15%   +157.86% (p=0.002 n=6)      35.35 ± 14%   +154.87% (p=0.002 n=6)      31.16 ±  6%   +124.65% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-65536          4.900m ± 18%   208.750m ± 12%  +4160.20% (p=0.002 n=6)   212.150m ± 12%  +4229.59% (p=0.002 n=6)   215.350m ±  6%  +4294.90% (p=0.002 n=6)
EncodeUtf16/Big5/mail-65536             21.80m ± 45%   1071.75m ± 53%  +4816.28% (p=0.002 n=6)   1109.10m ± 76%  +4987.61% (p=0.002 n=6)   1146.80m ± 54%  +5160.55% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-65536            20.65m ± 45%    396.90m ± 27%  +1822.03% (p=0.002 n=6)    401.50m ± 27%  +1844.31% (p=0.002 n=6)    401.95m ± 28%  +1846.49% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-65536         10.10m ± 44%    622.65m ± 57%  +6064.85% (p=0.002 n=6)    599.25m ± 54%  +5833.17% (p=0.002 n=6)    544.40m ± 51%  +5290.10% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-1048576           13.55 ± 51%      20.02 ± 20%    +47.71% (p=0.002 n=6)      19.16 ±  4%    +41.38% (p=0.002 n=6)      19.15 ±  7%    +41.27% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-1048576          20.60m ± 29%    407.60m ± 14%  +1878.64% (p=0.002 n=6)    402.10m ± 17%  +1851.94% (p=0.002 n=6)    407.65m ± 20%  +1878.88% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-1048576       10.30m ± 37%    585.05m ± 35%  +5580.10% (p=0.002 n=6)    629.75m ± 15%  +6014.08% (p=0.002 n=6)    608.70m ± 40%  +5809.71% (p=0.002 n=6)
EncodeUtf16/Big5/web-1048576            12.90m ±  9%    664.05m ± 10%  +5047.67% (p=0.002 n=6)    635.55m ± 22%  +4826.74% (p=0.002 n=6)    684.10m ± 11%  +5203.10% (p=0.002 n=6)
geomean                                 228.8m           961.1m         +320.08%                   933.6m         +308.04%                   916.2m         +300.46%
```

The layout study, `benchstat rust.txt zig.txt ranged.txt hash.txt rank.txt paged.txt
scan.txt`, GB/s:

```text
zig: ReleaseFast, native, 63b0159-dirty
rust: encoding_rs 0.8.44; icu 78.3; go: x/text v0.43.0
buffers: input 0 bytes past a page, output 2048; 50 ms a sample, 6 rounds
CPU(s):                                  4
Model name:                              Intel(R) Xeon(R) Processor @ 2.60GHz
                                     │     rust      │                   zig                   │                 ranged                  │                  hash                   │                  rank                   │                  paged                  │                 scan                  │
                                     │     GB/s      │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │     GB/s       vs base                │
DecodeUtf8/gb18030/ascii-16            1232.8m ± 18%     828.2m ±  4%    -32.82% (p=0.002 n=6)     823.2m ± 16%    -33.22% (p=0.002 n=6)     827.6m ±  3%    -32.86% (p=0.002 n=6)     830.2m ± 10%    -32.65% (p=0.002 n=6)     833.1m ± 20%    -32.42% (p=0.002 n=6)    819.8m ± 28%   -33.49% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-16              1203.9m ± 14%     826.0m ± 13%    -31.39% (p=0.002 n=6)     832.4m ±  8%    -30.86% (p=0.002 n=6)     817.9m ±  4%    -32.06% (p=0.002 n=6)     818.8m ±  2%    -31.99% (p=0.002 n=6)     832.2m ±  5%    -30.88% (p=0.002 n=6)    808.9m ± 15%   -32.82% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-16           233.7m ±  5%     443.8m ±  2%    +89.90% (p=0.002 n=6)     145.8m ±  4%    -37.61% (p=0.002 n=6)     445.2m ±  4%    +90.52% (p=0.002 n=6)     443.3m ± 10%    +89.69% (p=0.002 n=6)     350.8m ± 15%    +50.13% (p=0.002 n=6)    453.6m ± 22%   +94.12% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-16             1223.2m ± 43%     827.2m ±  1%          ~ (p=0.065 n=6)     823.8m ±  2%          ~ (p=0.065 n=6)     818.8m ±  3%          ~ (p=0.065 n=6)     832.1m ± 15%          ~ (p=0.065 n=6)     831.7m ± 15%          ~ (p=0.065 n=6)    829.7m ± 22%   -32.17% (p=0.041 n=6)
DecodeUtf8/gb18030/mixed-16             371.8m ±  2%     411.5m ± 31%          ~ (p=0.394 n=6)     159.8m ± 22%    -57.00% (p=0.002 n=6)     410.9m ± 17%          ~ (p=0.132 n=6)     441.2m ± 10%    +18.70% (p=0.002 n=6)     372.7m ±  4%          ~ (p=0.937 n=6)    383.3m ± 12%         ~ (p=0.394 n=6)
DecodeUtf8/gb18030/nonascii-16          407.1m ± 23%     390.8m ± 13%          ~ (p=0.310 n=6)     112.5m ±  4%    -72.36% (p=0.002 n=6)     389.1m ±  2%          ~ (p=0.394 n=6)     390.4m ± 21%          ~ (p=0.394 n=6)     293.7m ± 14%    -27.85% (p=0.002 n=6)    398.1m ± 11%         ~ (p=0.485 n=6)
DecodeUtf8/gb18030/subtitles-16        1175.1m ± 10%     826.1m ± 11%    -29.70% (p=0.002 n=6)     817.8m ±  5%    -30.40% (p=0.002 n=6)     827.6m ± 20%    -29.57% (p=0.002 n=6)     817.1m ± 19%    -30.47% (p=0.002 n=6)     805.1m ± 17%    -31.49% (p=0.002 n=6)    831.8m ±  7%   -29.21% (p=0.002 n=6)
DecodeUtf8/gb18030/web-16              1229.8m ± 15%     836.9m ±  5%    -31.95% (p=0.002 n=6)     832.2m ±  4%    -32.33% (p=0.002 n=6)     819.8m ± 14%    -33.34% (p=0.002 n=6)     828.3m ±  9%    -32.65% (p=0.002 n=6)     834.6m ±  7%    -32.14% (p=0.002 n=6)    834.2m ± 18%   -32.17% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-64              3.435 ±  5%      3.116 ±  3%     -9.28% (p=0.002 n=6)      3.081 ±  2%    -10.32% (p=0.002 n=6)      3.092 ±  4%     -9.99% (p=0.002 n=6)      3.146 ±  9%     -8.42% (p=0.002 n=6)      3.087 ±  1%    -10.12% (p=0.002 n=6)     3.129 ±  3%    -8.90% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-64              1162.8m ±  8%    1221.3m ± 37%          ~ (p=0.310 n=6)     384.6m ± 17%    -66.93% (p=0.002 n=6)    1291.3m ±  9%    +11.06% (p=0.004 n=6)    1255.7m ± 10%     +7.99% (p=0.041 n=6)    1042.9m ± 14%    -10.31% (p=0.002 n=6)   1290.2m ± 32%         ~ (p=0.065 n=6)
DecodeUtf8/gb18030/invalid-64           215.8m ± 10%     372.6m ± 31%    +72.72% (p=0.002 n=6)     181.4m ± 21%    -15.92% (p=0.002 n=6)     406.8m ±  9%    +88.53% (p=0.002 n=6)     391.6m ± 34%    +81.51% (p=0.002 n=6)     351.0m ± 15%    +62.71% (p=0.002 n=6)    388.1m ± 10%   +79.88% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-64               3.486 ± 34%      3.090 ± 26%    -11.37% (p=0.041 n=6)      2.979 ± 10%          ~ (p=0.065 n=6)      3.106 ± 10%          ~ (p=0.065 n=6)      3.089 ±  2%          ~ (p=0.065 n=6)      3.077 ± 10%          ~ (p=0.065 n=6)     3.111 ± 15%         ~ (p=0.065 n=6)
DecodeUtf8/gb18030/mixed-64             388.9m ± 11%     456.0m ± 24%          ~ (p=0.093 n=6)     164.4m ±  6%    -57.71% (p=0.002 n=6)     449.8m ± 12%    +15.65% (p=0.002 n=6)     450.6m ±  9%    +15.85% (p=0.002 n=6)     378.2m ±  7%          ~ (p=0.818 n=6)    452.9m ± 15%   +16.47% (p=0.024 n=6)
DecodeUtf8/gb18030/nonascii-64          528.0m ± 20%     483.4m ±  7%          ~ (p=0.065 n=6)     118.6m ±  4%    -77.54% (p=0.002 n=6)     496.9m ± 15%          ~ (p=0.065 n=6)     485.8m ± 15%     -7.98% (p=0.041 n=6)     374.2m ± 15%    -29.12% (p=0.002 n=6)    511.1m ± 14%         ~ (p=0.065 n=6)
DecodeUtf8/gb18030/subtitles-64         961.0m ± 18%     868.9m ± 28%          ~ (p=0.132 n=6)     234.7m ±  6%    -75.58% (p=0.002 n=6)     918.4m ± 16%          ~ (p=0.240 n=6)     902.2m ± 12%          ~ (p=0.310 n=6)     716.7m ± 11%    -25.43% (p=0.002 n=6)    914.7m ± 26%         ~ (p=0.132 n=6)
DecodeUtf8/gb18030/web-64                3.495 ±  3%      3.099 ± 10%    -11.33% (p=0.002 n=6)      3.092 ±  9%    -11.51% (p=0.002 n=6)      3.118 ±  8%    -10.77% (p=0.002 n=6)      3.137 ± 19%    -10.22% (p=0.002 n=6)      3.086 ±  8%    -11.68% (p=0.002 n=6)     3.102 ±  6%   -11.24% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-256              438.5m ± 15%     660.3m ±  3%    +50.58% (p=0.002 n=6)     173.0m ±  2%    -60.55% (p=0.002 n=6)     677.8m ± 10%    +54.57% (p=0.002 n=6)     653.2m ± 12%    +48.97% (p=0.002 n=6)     540.4m ± 18%    +23.25% (p=0.002 n=6)    675.5m ±  3%   +54.05% (p=0.002 n=6)
DecodeUtf8/gb18030/subtitles-256        519.8m ±  4%     690.8m ±  6%    +32.90% (p=0.002 n=6)     180.2m ±  4%    -65.34% (p=0.002 n=6)     736.5m ±  2%    +41.68% (p=0.002 n=6)     721.9m ±  1%    +38.87% (p=0.002 n=6)     562.8m ± 18%          ~ (p=0.065 n=6)    714.8m ± 28%   +37.51% (p=0.026 n=6)
DecodeUtf8/gb18030/ascii-256             6.280 ±  2%      9.886 ±  1%    +57.42% (p=0.002 n=6)      9.764 ±  1%    +55.47% (p=0.002 n=6)      9.856 ±  1%    +56.93% (p=0.002 n=6)      9.866 ±  4%    +57.10% (p=0.002 n=6)      9.787 ±  3%    +55.83% (p=0.002 n=6)     9.855 ±  2%   +56.91% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-256          276.1m ±  2%     402.9m ±  1%    +45.95% (p=0.002 n=6)     209.5m ±  2%    -24.11% (p=0.002 n=6)     396.4m ±  6%    +43.60% (p=0.002 n=6)     402.5m ±  4%    +45.81% (p=0.002 n=6)     365.8m ±  2%    +32.51% (p=0.002 n=6)    399.8m ±  1%   +44.81% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-256            1062.5m ± 20%    1215.2m ± 20%    +14.38% (p=0.041 n=6)     322.6m ± 21%    -69.63% (p=0.002 n=6)    1216.9m ±  4%    +14.54% (p=0.002 n=6)    1223.9m ± 19%    +15.20% (p=0.041 n=6)     981.7m ± 29%     -7.60% (p=0.041 n=6)   1121.7m ± 26%         ~ (p=0.065 n=6)
DecodeUtf8/gb18030/mixed-256            323.4m ±  3%     412.2m ±  1%    +27.48% (p=0.002 n=6)     172.6m ±  1%    -46.64% (p=0.002 n=6)     414.2m ±  4%    +28.10% (p=0.002 n=6)     414.0m ±  3%    +28.03% (p=0.002 n=6)     379.1m ± 18%          ~ (p=0.061 n=6)    412.2m ±  0%   +27.46% (p=0.002 n=6)
DecodeUtf8/gb18030/nonascii-256         384.9m ±  3%     501.6m ± 11%    +30.35% (p=0.002 n=6)     125.5m ±  9%    -67.38% (p=0.002 n=6)     512.2m ±  7%    +33.09% (p=0.002 n=6)     515.9m ± 12%    +34.07% (p=0.002 n=6)     403.1m ±  4%     +4.73% (p=0.009 n=6)    536.1m ±  5%   +39.30% (p=0.002 n=6)
DecodeUtf8/gb18030/web-256             1368.9m ± 12%    1469.2m ±  3%     +7.33% (p=0.015 n=6)     398.9m ± 13%    -70.86% (p=0.002 n=6)    1470.5m ±  5%     +7.42% (p=0.009 n=6)    1472.3m ±  3%     +7.56% (p=0.004 n=6)    1161.0m ± 10%    -15.18% (p=0.004 n=6)   1389.8m ±  9%         ~ (p=1.000 n=6)
DecodeUtf8/gb18030/csv-4096             436.5m ±  1%     564.5m ±  3%    +29.31% (p=0.002 n=6)     111.0m ± 11%    -74.57% (p=0.002 n=6)     596.6m ± 37%          ~ (p=0.063 n=6)     573.3m ± 36%          ~ (p=0.065 n=6)     462.7m ± 24%          ~ (p=0.394 n=6)    590.9m ±  6%   +35.36% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-4096            8.364 ± 15%     19.709 ± 13%   +135.65% (p=0.002 n=6)     19.207 ±  2%   +129.65% (p=0.002 n=6)     19.702 ±  3%   +135.57% (p=0.002 n=6)     19.868 ±  2%   +137.55% (p=0.002 n=6)     19.725 ± 17%   +135.84% (p=0.002 n=6)    19.629 ± 17%  +134.69% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-4096        235.45m ± 39%    392.50m ±  7%    +66.70% (p=0.002 n=6)     82.25m ±  3%    -65.07% (p=0.002 n=6)    393.65m ±  3%    +67.19% (p=0.002 n=6)    394.45m ± 17%    +67.53% (p=0.002 n=6)    345.30m ± 14%    +46.66% (p=0.002 n=6)   390.80m ±  8%   +65.98% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-4096            481.8m ± 37%     640.5m ± 40%    +32.95% (p=0.041 n=6)     158.2m ± 30%    -67.15% (p=0.002 n=6)     665.4m ± 32%    +38.11% (p=0.041 n=6)     657.0m ± 13%    +36.36% (p=0.002 n=6)     519.7m ±  4%     +7.88% (p=0.002 n=6)    642.8m ± 27%   +33.42% (p=0.041 n=6)
DecodeUtf8/gb18030/mixed-4096           297.5m ± 15%     402.2m ± 11%    +35.19% (p=0.002 n=6)     151.1m ± 24%    -49.22% (p=0.002 n=6)     410.8m ± 10%    +38.08% (p=0.002 n=6)     402.6m ± 24%    +35.30% (p=0.002 n=6)     327.4m ±  9%    +10.02% (p=0.015 n=6)    404.7m ± 19%   +36.01% (p=0.002 n=6)
DecodeUtf8/gb18030/nonascii-4096       373.55m ± 39%    515.45m ± 44%    +37.99% (p=0.041 n=6)     72.90m ± 14%    -80.48% (p=0.002 n=6)    539.65m ± 36%    +44.47% (p=0.041 n=6)    530.85m ± 27%    +42.11% (p=0.002 n=6)    361.15m ± 29%          ~ (p=0.065 n=6)   534.70m ± 29%   +43.14% (p=0.002 n=6)
DecodeUtf8/gb18030/subtitles-4096       499.6m ± 23%     633.5m ±  3%    +26.80% (p=0.002 n=6)     133.6m ± 15%    -73.27% (p=0.002 n=6)     634.6m ± 28%    +27.03% (p=0.041 n=6)     639.6m ±  8%    +28.02% (p=0.002 n=6)     511.0m ±  1%     +2.28% (p=0.004 n=6)    653.1m ±  1%   +30.73% (p=0.002 n=6)
DecodeUtf8/gb18030/web-4096             422.8m ±  2%     554.4m ± 26%          ~ (p=0.065 n=6)     105.1m ±  9%    -75.13% (p=0.002 n=6)     579.5m ±  8%    +37.05% (p=0.002 n=6)     565.7m ± 27%          ~ (p=0.065 n=6)     452.8m ±  5%     +7.07% (p=0.009 n=6)    570.5m ±  3%   +34.92% (p=0.002 n=6)
DecodeUtf8/gb18030/mail-65536          315.50m ±  5%    656.90m ±  7%   +108.21% (p=0.002 n=6)     71.25m ±  4%    -77.42% (p=0.002 n=6)    661.15m ± 10%   +109.56% (p=0.002 n=6)    649.80m ±  9%   +105.96% (p=0.002 n=6)    377.70m ± 16%    +19.71% (p=0.009 n=6)   658.65m ±  4%  +108.76% (p=0.002 n=6)
DecodeUtf8/gb18030/web-65536           245.75m ± 14%    523.10m ± 20%   +112.86% (p=0.002 n=6)     56.45m ±  9%    -77.03% (p=0.002 n=6)    541.60m ±  9%   +120.39% (p=0.002 n=6)    515.05m ± 20%   +109.58% (p=0.002 n=6)    297.35m ±  7%    +21.00% (p=0.002 n=6)   527.05m ± 17%  +114.47% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-65536           8.821 ±  9%     22.180 ±  3%   +151.44% (p=0.002 n=6)     22.052 ± 23%   +149.99% (p=0.002 n=6)     21.742 ± 27%   +146.47% (p=0.002 n=6)     22.140 ±  3%   +150.98% (p=0.002 n=6)     22.076 ± 15%   +150.27% (p=0.002 n=6)    21.985 ± 19%  +149.23% (p=0.002 n=6)
DecodeUtf8/gb18030/csv-65536           439.45m ± 31%    592.45m ±  7%    +34.82% (p=0.002 n=6)     70.45m ±  7%    -83.97% (p=0.002 n=6)    612.75m ±  8%    +39.44% (p=0.002 n=6)    569.25m ±  7%    +29.54% (p=0.002 n=6)    434.45m ± 25%          ~ (p=0.394 n=6)   606.80m ± 23%   +38.08% (p=0.002 n=6)
DecodeUtf8/gb18030/invalid-65536        89.20m ± 11%    222.05m ±  4%   +148.93% (p=0.002 n=6)     48.80m ±  1%    -45.29% (p=0.002 n=6)    214.20m ± 27%   +140.13% (p=0.002 n=6)    219.95m ± 28%   +146.58% (p=0.002 n=6)    165.30m ±  3%    +85.31% (p=0.002 n=6)   219.15m ± 14%  +145.68% (p=0.002 n=6)
DecodeUtf8/gb18030/mixed-65536         230.90m ±  9%    411.20m ±  9%    +78.09% (p=0.002 n=6)     70.40m ±  2%    -69.51% (p=0.002 n=6)    410.05m ± 10%    +77.59% (p=0.002 n=6)    408.20m ± 14%    +76.79% (p=0.002 n=6)    276.30m ±  5%    +19.66% (p=0.002 n=6)   404.90m ±  6%   +75.36% (p=0.002 n=6)
DecodeUtf8/gb18030/nonascii-65536      233.85m ±  7%    483.35m ± 31%   +106.69% (p=0.002 n=6)     48.85m ±  6%    -79.11% (p=0.002 n=6)    540.55m ±  8%   +131.15% (p=0.002 n=6)    509.55m ±  8%   +117.90% (p=0.002 n=6)    273.00m ±  6%    +16.74% (p=0.002 n=6)   527.00m ± 41%  +125.36% (p=0.002 n=6)
DecodeUtf8/gb18030/subtitles-65536     303.00m ± 37%    614.25m ± 36%   +102.72% (p=0.002 n=6)     67.15m ± 11%    -77.84% (p=0.002 n=6)    637.00m ±  1%   +110.23% (p=0.002 n=6)    615.95m ± 21%   +103.28% (p=0.002 n=6)    366.75m ± 12%    +21.04% (p=0.002 n=6)   624.65m ± 17%  +106.16% (p=0.002 n=6)
DecodeUtf8/gb18030/web-1048576         242.95m ±  5%    523.55m ±  3%   +115.50% (p=0.002 n=6)     55.85m ±  4%    -77.01% (p=0.002 n=6)    530.15m ± 24%   +118.21% (p=0.002 n=6)    512.45m ± 28%   +110.93% (p=0.002 n=6)    302.75m ±  7%    +24.61% (p=0.002 n=6)   512.65m ±  5%  +111.01% (p=0.002 n=6)
DecodeUtf8/gb18030/ascii-1048576         8.546 ± 22%     19.669 ± 14%   +130.14% (p=0.002 n=6)     18.302 ± 32%   +114.15% (p=0.002 n=6)     19.293 ± 10%   +125.75% (p=0.002 n=6)     18.664 ± 17%   +118.38% (p=0.002 n=6)     19.211 ± 22%   +124.78% (p=0.002 n=6)    19.573 ± 21%  +129.02% (p=0.002 n=6)
DecodeUtf8/gb18030/mixed-1048576       217.35m ±  1%    398.90m ±  2%    +83.53% (p=0.002 n=6)     68.45m ±  3%    -68.51% (p=0.002 n=6)    396.15m ±  7%    +82.26% (p=0.002 n=6)    403.45m ±  9%    +85.62% (p=0.002 n=6)    275.10m ±  1%    +26.57% (p=0.002 n=6)   404.15m ± 22%   +85.94% (p=0.002 n=6)
DecodeUtf8/gb18030/nonascii-1048576    234.25m ±  5%    510.40m ±  4%   +117.89% (p=0.002 n=6)     49.30m ±  1%    -78.95% (p=0.002 n=6)    538.95m ±  6%   +130.07% (p=0.002 n=6)    505.80m ±  2%   +115.92% (p=0.002 n=6)    269.95m ±  2%    +15.24% (p=0.002 n=6)   547.10m ±  6%  +133.55% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-16             1.140 ± 36%      1.362 ±  7%    +19.44% (p=0.002 n=6)      1.363 ± 19%    +19.51% (p=0.026 n=6)      1.338 ± 18%    +17.34% (p=0.026 n=6)      1.397 ±  9%    +22.56% (p=0.002 n=6)      1.362 ± 21%    +19.46% (p=0.041 n=6)     1.416 ± 46%   +24.18% (p=0.041 n=6)
DecodeUtf16/gb18030/csv-16               1.118 ±  8%      1.363 ±  3%    +21.89% (p=0.002 n=6)      1.384 ±  2%    +23.81% (p=0.002 n=6)      1.342 ±  3%    +20.02% (p=0.002 n=6)      1.410 ± 22%    +26.09% (p=0.026 n=6)      1.395 ± 17%    +24.81% (p=0.004 n=6)     1.381 ±  8%   +23.54% (p=0.002 n=6)
DecodeUtf16/gb18030/invalid-16          265.2m ± 32%     547.9m ± 28%   +106.58% (p=0.002 n=6)     183.1m ±  4%    -30.95% (p=0.041 n=6)     545.5m ±  3%   +105.66% (p=0.002 n=6)     513.2m ±  5%    +93.50% (p=0.002 n=6)     459.9m ± 10%    +73.38% (p=0.002 n=6)    513.1m ± 15%   +93.46% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-16              1.155 ±  4%      1.374 ± 23%          ~ (p=0.065 n=6)      1.393 ± 46%          ~ (p=0.394 n=6)      1.353 ± 29%          ~ (p=0.065 n=6)      1.422 ±  2%    +23.14% (p=0.002 n=6)      1.406 ±  6%    +21.72% (p=0.002 n=6)     1.404 ±  3%   +21.60% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-16            416.6m ± 24%     532.6m ±  7%    +27.83% (p=0.002 n=6)     185.5m ±  2%    -55.48% (p=0.002 n=6)     534.9m ±  7%    +28.37% (p=0.002 n=6)     451.1m ± 42%          ~ (p=0.180 n=6)     472.4m ± 32%    +13.38% (p=0.037 n=6)    491.3m ± 34%   +17.92% (p=0.041 n=6)
DecodeUtf16/gb18030/nonascii-16         542.4m ±  6%     483.2m ±  4%    -10.91% (p=0.002 n=6)     142.8m ± 26%    -73.66% (p=0.002 n=6)     479.5m ± 24%    -11.59% (p=0.002 n=6)     408.8m ± 17%    -24.63% (p=0.002 n=6)     407.8m ±  7%    -24.80% (p=0.002 n=6)    454.6m ± 13%   -16.19% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-16         1.128 ± 32%      1.371 ± 36%    +21.53% (p=0.041 n=6)      1.392 ± 17%    +23.42% (p=0.015 n=6)      1.349 ± 13%    +19.65% (p=0.002 n=6)      1.397 ± 11%    +23.91% (p=0.002 n=6)      1.415 ±  5%    +25.43% (p=0.002 n=6)     1.427 ± 24%   +26.53% (p=0.041 n=6)
DecodeUtf16/gb18030/web-16               1.142 ± 11%      1.399 ±  7%    +22.54% (p=0.002 n=6)      1.351 ±  5%    +18.29% (p=0.002 n=6)      1.367 ±  4%    +19.74% (p=0.002 n=6)      1.428 ±  5%    +25.03% (p=0.002 n=6)      1.403 ±  4%    +22.88% (p=0.002 n=6)     1.415 ±  4%   +23.90% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-64             2.912 ±  3%      4.454 ± 13%    +52.98% (p=0.002 n=6)      4.558 ±  4%    +56.54% (p=0.002 n=6)      4.143 ± 23%    +42.27% (p=0.002 n=6)      4.912 ±  8%    +68.68% (p=0.002 n=6)      4.438 ±  4%    +52.42% (p=0.002 n=6)     4.401 ±  5%   +51.14% (p=0.002 n=6)
DecodeUtf16/gb18030/csv-64             1489.5m ± 46%    1556.3m ±  9%     +4.48% (p=0.041 n=6)     472.0m ± 11%    -68.31% (p=0.002 n=6)    1540.4m ±  6%          ~ (p=0.132 n=6)    1476.8m ±  5%          ~ (p=0.818 n=6)    1319.0m ±  5%          ~ (p=0.065 n=6)   1436.8m ±  4%         ~ (p=0.288 n=6)
DecodeUtf16/gb18030/invalid-64          231.5m ± 17%     435.9m ± 37%    +88.32% (p=0.002 n=6)     223.2m ± 29%          ~ (p=0.667 n=6)     442.7m ±  3%    +91.23% (p=0.002 n=6)     436.6m ±  7%    +88.60% (p=0.002 n=6)     406.4m ± 17%    +75.55% (p=0.002 n=6)    434.9m ± 28%   +87.86% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-64              2.860 ± 37%      4.400 ±  7%    +53.87% (p=0.002 n=6)      4.646 ± 35%    +62.45% (p=0.002 n=6)      4.074 ± 13%    +42.45% (p=0.002 n=6)      4.740 ± 14%    +65.75% (p=0.002 n=6)      4.283 ± 39%    +49.78% (p=0.026 n=6)     4.174 ± 33%   +45.98% (p=0.026 n=6)
DecodeUtf16/gb18030/mixed-64            443.2m ±  4%     501.1m ±  4%    +13.05% (p=0.002 n=6)     197.2m ± 35%    -55.49% (p=0.002 n=6)     489.5m ± 42%          ~ (p=0.065 n=6)     464.8m ± 39%          ~ (p=0.699 n=6)     440.4m ± 17%          ~ (p=0.699 n=6)    496.2m ± 14%         ~ (p=0.065 n=6)
DecodeUtf16/gb18030/nonascii-64         688.3m ± 20%     587.4m ± 15%    -14.66% (p=0.015 n=6)     149.8m ±  7%    -78.23% (p=0.002 n=6)     635.1m ± 14%     -7.73% (p=0.041 n=6)     566.3m ± 11%    -17.72% (p=0.041 n=6)     500.4m ± 47%    -27.29% (p=0.002 n=6)    595.3m ±  6%         ~ (p=0.065 n=6)
DecodeUtf16/gb18030/subtitles-64       1317.6m ± 38%    1112.0m ± 27%    -15.60% (p=0.041 n=6)     313.6m ± 18%    -76.20% (p=0.002 n=6)    1133.8m ± 18%          ~ (p=0.065 n=6)     887.8m ± 27%    -32.62% (p=0.041 n=6)     908.9m ± 26%    -31.02% (p=0.041 n=6)   1056.4m ± 17%         ~ (p=0.065 n=6)
DecodeUtf16/gb18030/web-64               2.857 ±  6%      4.417 ± 18%    +54.63% (p=0.002 n=6)      4.588 ± 10%    +60.59% (p=0.002 n=6)      4.170 ±  3%    +45.96% (p=0.002 n=6)      4.883 ± 14%    +70.93% (p=0.002 n=6)      4.435 ± 12%    +55.23% (p=0.002 n=6)     4.273 ±  3%   +49.57% (p=0.002 n=6)
DecodeUtf16/gb18030/csv-256             530.1m ± 28%     829.8m ±  5%    +56.53% (p=0.002 n=6)     214.5m ±  5%    -59.54% (p=0.002 n=6)     820.4m ± 19%    +54.75% (p=0.002 n=6)     753.0m ±  6%    +42.04% (p=0.002 n=6)     716.0m ±  8%    +35.07% (p=0.002 n=6)    789.8m ± 18%   +48.98% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-256       635.0m ± 37%     918.6m ± 49%    +44.67% (p=0.041 n=6)     216.2m ±  3%    -65.94% (p=0.002 n=6)     907.9m ±  4%    +42.98% (p=0.002 n=6)     833.9m ± 22%    +31.32% (p=0.015 n=6)     730.1m ±  3%    +14.98% (p=0.002 n=6)    854.5m ± 20%   +34.56% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-256            5.167 ± 10%     11.312 ±  3%   +118.91% (p=0.002 n=6)     12.036 ± 10%   +132.93% (p=0.002 n=6)     11.162 ±  8%   +116.02% (p=0.002 n=6)     12.200 ± 18%   +136.10% (p=0.002 n=6)     11.057 ±  3%   +113.98% (p=0.002 n=6)    11.201 ±  3%  +116.77% (p=0.002 n=6)
DecodeUtf16/gb18030/invalid-256         300.5m ± 19%     428.1m ± 22%    +42.46% (p=0.002 n=6)     238.2m ± 20%    -20.75% (p=0.002 n=6)     435.4m ± 30%    +44.91% (p=0.004 n=6)     432.9m ±  3%    +44.08% (p=0.002 n=6)     399.5m ±  5%    +32.95% (p=0.002 n=6)    429.9m ± 10%   +43.08% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-256           1302.7m ± 39%    1447.0m ±  6%    +11.08% (p=0.002 n=6)     397.0m ±  9%    -69.52% (p=0.002 n=6)    1465.9m ±  4%    +12.53% (p=0.002 n=6)    1355.8m ±  6%          ~ (p=0.132 n=6)    1243.3m ± 13%          ~ (p=0.065 n=6)   1344.5m ± 20%         ~ (p=0.394 n=6)
DecodeUtf16/gb18030/mixed-256           375.7m ± 10%     444.6m ±  7%    +18.35% (p=0.002 n=6)     196.1m ±  3%    -47.82% (p=0.002 n=6)     445.1m ±  4%    +18.49% (p=0.002 n=6)     442.8m ±  1%    +17.86% (p=0.002 n=6)     428.6m ±  2%    +14.09% (p=0.002 n=6)    446.1m ±  2%   +18.74% (p=0.002 n=6)
DecodeUtf16/gb18030/nonascii-256        487.4m ± 18%     656.5m ± 17%    +34.72% (p=0.002 n=6)     150.2m ±  8%    -69.18% (p=0.002 n=6)     654.0m ±  4%    +34.18% (p=0.002 n=6)     563.8m ±  8%    +15.69% (p=0.002 n=6)     529.8m ±  5%     +8.71% (p=0.002 n=6)    606.1m ±  3%   +24.38% (p=0.002 n=6)
DecodeUtf16/gb18030/web-256            1764.8m ±  1%    1800.8m ±  3%     +2.03% (p=0.043 n=6)     492.7m ± 12%    -72.09% (p=0.002 n=6)    1765.2m ±  6%          ~ (p=0.937 n=6)    1652.2m ±  5%     -6.38% (p=0.002 n=6)    1492.9m ±  3%    -15.41% (p=0.002 n=6)   1742.0m ±  2%         ~ (p=0.180 n=6)
DecodeUtf16/gb18030/csv-4096            559.8m ± 14%     732.9m ± 16%    +30.92% (p=0.002 n=6)     118.7m ±  5%    -78.79% (p=0.002 n=6)     757.6m ±  7%    +35.36% (p=0.002 n=6)     657.9m ± 26%    +17.53% (p=0.041 n=6)     616.5m ± 11%    +10.15% (p=0.041 n=6)    688.2m ± 13%   +22.95% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-4096           6.908 ±  9%     19.372 ±  2%   +180.44% (p=0.002 n=6)     19.465 ±  4%   +181.78% (p=0.002 n=6)     19.324 ±  4%   +179.74% (p=0.002 n=6)     19.484 ±  4%   +182.07% (p=0.002 n=6)     18.789 ±  6%   +172.00% (p=0.002 n=6)    18.954 ± 29%  +174.39% (p=0.002 n=6)
DecodeUtf16/gb18030/invalid-4096       262.60m ±  5%    407.70m ± 14%    +55.26% (p=0.002 n=6)     86.90m ± 16%    -66.91% (p=0.002 n=6)    439.35m ±  6%    +67.31% (p=0.002 n=6)    436.80m ± 22%    +66.34% (p=0.002 n=6)    394.70m ±  4%    +50.30% (p=0.002 n=6)   429.75m ±  7%   +63.65% (p=0.002 n=6)
DecodeUtf16/gb18030/mail-4096           616.4m ± 18%     844.3m ±  3%    +36.98% (p=0.002 n=6)     165.8m ± 19%    -73.09% (p=0.002 n=6)     862.3m ±  6%    +39.90% (p=0.002 n=6)     761.6m ± 34%          ~ (p=0.240 n=6)     700.3m ±  2%    +13.61% (p=0.002 n=6)    789.1m ±  1%   +28.02% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-4096          345.3m ± 28%     437.4m ± 14%    +26.67% (p=0.002 n=6)     173.7m ±  6%    -49.70% (p=0.002 n=6)     438.2m ± 11%    +26.90% (p=0.002 n=6)     442.6m ± 20%    +28.18% (p=0.004 n=6)     337.1m ±  2%          ~ (p=0.485 n=6)    440.7m ± 24%   +27.63% (p=0.026 n=6)
DecodeUtf16/gb18030/nonascii-4096      468.75m ± 10%    686.20m ± 18%    +46.39% (p=0.002 n=6)     77.10m ±  8%    -83.55% (p=0.002 n=6)    687.30m ± 22%    +46.62% (p=0.002 n=6)    618.15m ±  5%    +31.87% (p=0.002 n=6)    504.85m ±  3%     +7.70% (p=0.004 n=6)   641.85m ±  3%   +36.93% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-4096      650.6m ± 26%     719.0m ± 23%          ~ (p=0.180 n=6)     144.4m ± 35%    -77.80% (p=0.002 n=6)     869.6m ± 31%    +33.66% (p=0.026 n=6)     787.2m ± 20%    +20.99% (p=0.026 n=6)     691.6m ±  3%     +6.30% (p=0.002 n=6)    789.8m ±  4%   +21.39% (p=0.002 n=6)
DecodeUtf16/gb18030/web-4096            544.4m ±  4%     735.0m ±  3%    +35.02% (p=0.002 n=6)     112.9m ±  3%    -79.25% (p=0.002 n=6)     745.5m ±  3%    +36.96% (p=0.002 n=6)     667.6m ± 30%          ~ (p=0.056 n=6)     573.8m ± 13%          ~ (p=0.262 n=6)    681.1m ± 27%         ~ (p=0.056 n=6)
DecodeUtf16/gb18030/mail-65536         367.30m ±  7%    841.85m ± 50%   +129.20% (p=0.002 n=6)     72.55m ± 11%    -80.25% (p=0.002 n=6)    846.55m ± 25%   +130.48% (p=0.002 n=6)    754.25m ± 37%   +105.35% (p=0.002 n=6)    455.35m ±  1%    +23.97% (p=0.002 n=6)   801.10m ± 19%  +118.11% (p=0.002 n=6)
DecodeUtf16/gb18030/web-65536          279.15m ±  6%    676.60m ±  3%   +142.38% (p=0.002 n=6)     58.35m ±  1%    -79.10% (p=0.002 n=6)    680.65m ±  5%   +143.83% (p=0.002 n=6)    638.95m ±  7%   +128.89% (p=0.002 n=6)    360.20m ±  3%    +29.03% (p=0.002 n=6)   646.00m ±  2%  +131.42% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-65536          7.097 ± 10%     19.088 ±  2%   +168.96% (p=0.002 n=6)     19.057 ±  4%   +168.51% (p=0.002 n=6)     18.950 ± 12%   +167.01% (p=0.002 n=6)     19.027 ± 15%   +168.09% (p=0.002 n=6)     17.964 ±  7%   +153.11% (p=0.002 n=6)    18.743 ±  8%  +164.09% (p=0.002 n=6)
DecodeUtf16/gb18030/csv-65536          560.05m ± 29%    790.80m ±  8%    +41.20% (p=0.002 n=6)     73.85m ±  2%    -86.81% (p=0.002 n=6)    803.90m ±  4%    +43.54% (p=0.002 n=6)    689.85m ±  2%    +23.18% (p=0.002 n=6)    596.35m ±  3%     +6.48% (p=0.002 n=6)   740.30m ± 30%   +32.18% (p=0.041 n=6)
DecodeUtf16/gb18030/invalid-65536       93.10m ±  3%    219.40m ±  1%   +135.66% (p=0.002 n=6)     50.70m ±  4%    -45.54% (p=0.002 n=6)    220.10m ±  1%   +136.41% (p=0.002 n=6)    223.95m ±  1%   +140.55% (p=0.002 n=6)    166.50m ±  3%    +78.84% (p=0.002 n=6)   241.65m ±  3%  +159.56% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-65536        261.65m ± 23%    444.10m ± 12%    +69.73% (p=0.002 n=6)     72.05m ±  8%    -72.46% (p=0.002 n=6)    442.70m ±  4%    +69.20% (p=0.002 n=6)    442.20m ±  5%    +69.00% (p=0.002 n=6)    299.70m ±  1%    +14.54% (p=0.002 n=6)   440.85m ±  4%   +68.49% (p=0.002 n=6)
DecodeUtf16/gb18030/nonascii-65536     262.10m ±  7%    704.45m ± 17%   +168.77% (p=0.002 n=6)     51.25m ±  1%    -80.45% (p=0.002 n=6)    702.20m ±  4%   +167.91% (p=0.002 n=6)    663.90m ±  5%   +153.30% (p=0.002 n=6)    328.10m ±  4%    +25.18% (p=0.002 n=6)   668.85m ±  8%  +155.19% (p=0.002 n=6)
DecodeUtf16/gb18030/subtitles-65536    327.95m ±  7%    780.15m ±  7%   +137.89% (p=0.002 n=6)     70.90m ±  2%    -78.38% (p=0.002 n=6)    802.80m ±  6%   +144.79% (p=0.002 n=6)    685.65m ±  6%   +109.07% (p=0.002 n=6)    429.95m ±  6%    +31.10% (p=0.002 n=6)   754.80m ±  6%  +130.16% (p=0.002 n=6)
DecodeUtf16/gb18030/web-1048576        262.80m ± 34%    682.40m ±  4%   +159.67% (p=0.002 n=6)     57.00m ±  4%    -78.31% (p=0.002 n=6)    683.75m ±  8%   +160.18% (p=0.002 n=6)    594.95m ±  4%   +126.39% (p=0.002 n=6)    351.60m ±  7%    +33.79% (p=0.002 n=6)   623.85m ±  4%  +137.39% (p=0.002 n=6)
DecodeUtf16/gb18030/ascii-1048576        7.057 ± 15%      9.211 ± 10%    +30.53% (p=0.002 n=6)      9.241 ±  5%    +30.95% (p=0.002 n=6)      9.394 ±  5%    +33.13% (p=0.002 n=6)      9.393 ±  5%    +33.10% (p=0.002 n=6)      9.156 ±  6%    +29.75% (p=0.002 n=6)     9.161 ± 12%   +29.81% (p=0.002 n=6)
DecodeUtf16/gb18030/mixed-1048576      233.65m ±  8%    437.55m ±  1%    +87.27% (p=0.002 n=6)     70.80m ±  1%    -69.70% (p=0.002 n=6)    437.50m ± 15%    +87.25% (p=0.002 n=6)    434.55m ± 30%    +85.98% (p=0.002 n=6)    293.50m ±  8%    +25.62% (p=0.002 n=6)   438.10m ±  6%   +87.50% (p=0.002 n=6)
DecodeUtf16/gb18030/nonascii-1048576   253.20m ± 24%    700.30m ± 20%   +176.58% (p=0.002 n=6)     50.90m ±  3%    -79.90% (p=0.002 n=6)    692.35m ± 11%   +173.44% (p=0.002 n=6)    660.65m ±  7%   +160.92% (p=0.002 n=6)    315.65m ± 13%    +24.66% (p=0.002 n=6)   679.25m ±  5%  +168.27% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-16              1.328 ±  9%      1.489 ± 32%          ~ (p=0.240 n=6)      1.460 ±  5%     +9.90% (p=0.002 n=6)      1.574 ± 12%    +18.53% (p=0.002 n=6)      1.529 ± 22%          ~ (p=0.065 n=6)      1.599 ± 16%    +20.40% (p=0.009 n=6)     1.584 ±  2%   +19.22% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-16                1.348 ±  2%      1.495 ±  4%    +10.92% (p=0.002 n=6)      1.494 ±  4%    +10.88% (p=0.002 n=6)      1.588 ± 39%          ~ (p=0.394 n=6)      1.516 ± 17%          ~ (p=0.394 n=6)      1.531 ± 33%          ~ (p=0.394 n=6)     1.532 ± 13%   +13.67% (p=0.026 n=6)
EncodeUtf8/gb18030/invalid-16           10.80m ± 31%    220.75m ± 22%  +1943.98% (p=0.002 n=6)    228.80m ± 22%  +2018.52% (p=0.002 n=6)    230.90m ±  2%  +2037.96% (p=0.002 n=6)    487.45m ±  3%  +4413.43% (p=0.002 n=6)    487.60m ±  2%  +4414.81% (p=0.002 n=6)    16.20m ± 15%   +50.00% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-16               1.309 ± 15%      1.437 ±  5%     +9.72% (p=0.002 n=6)      1.507 ±  7%    +15.06% (p=0.002 n=6)      1.533 ± 16%    +17.10% (p=0.026 n=6)      1.516 ± 34%          ~ (p=0.065 n=6)      1.506 ± 20%    +15.01% (p=0.041 n=6)     1.565 ± 11%   +19.49% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-16             21.60m ± 19%    231.00m ±  7%   +969.44% (p=0.002 n=6)    252.05m ±  6%  +1066.90% (p=0.002 n=6)    253.80m ±  2%  +1075.00% (p=0.002 n=6)    467.05m ±  7%  +2062.27% (p=0.002 n=6)    459.75m ± 17%  +2028.47% (p=0.002 n=6)    13.85m ±  2%   -35.88% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-16          17.85m ±  6%    171.00m ±  3%   +857.98% (p=0.002 n=6)    194.70m ±  4%   +990.76% (p=0.002 n=6)    198.05m ±  4%  +1009.52% (p=0.002 n=6)    463.40m ± 13%  +2496.08% (p=0.002 n=6)    467.15m ±  2%  +2517.09% (p=0.002 n=6)    10.80m ±  2%   -39.50% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-16          1.328 ± 27%      1.491 ± 22%          ~ (p=0.223 n=6)      1.502 ±  2%    +13.14% (p=0.002 n=6)      1.596 ±  1%    +20.18% (p=0.002 n=6)      1.599 ±  3%    +20.45% (p=0.002 n=6)      1.566 ±  4%    +17.98% (p=0.002 n=6)     1.570 ± 23%         ~ (p=0.240 n=6)
EncodeUtf8/gb18030/web-16                1.355 ±  7%      1.489 ± 35%          ~ (p=0.065 n=6)      1.517 ± 26%          ~ (p=0.065 n=6)      1.593 ±  3%    +17.57% (p=0.002 n=6)      1.582 ±  9%    +16.80% (p=0.002 n=6)      1.593 ±  5%    +17.56% (p=0.002 n=6)     1.587 ±  4%   +17.11% (p=0.002 n=6)
EncodeUtf8/gb18030/ascii-64              3.052 ±  9%      4.577 ±  6%    +49.99% (p=0.002 n=6)      4.640 ±  3%    +52.04% (p=0.002 n=6)      5.285 ±  1%    +73.19% (p=0.002 n=6)      5.303 ± 15%    +73.77% (p=0.002 n=6)      5.186 ±  9%    +69.93% (p=0.002 n=6)     5.256 ±  3%   +72.22% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-64               44.45m ±  8%    453.45m ±  7%   +920.13% (p=0.002 n=6)    505.90m ± 24%  +1038.13% (p=0.002 n=6)    512.40m ± 17%  +1052.76% (p=0.002 n=6)   1055.30m ± 17%  +2274.13% (p=0.002 n=6)   1093.00m ± 19%  +2358.94% (p=0.002 n=6)    28.25m ± 21%   -36.45% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-64          13.050m ±  5%   159.400m ± 16%  +1121.46% (p=0.002 n=6)   167.700m ± 11%  +1185.06% (p=0.002 n=6)   213.900m ±  6%  +1539.08% (p=0.002 n=6)   311.250m ± 32%  +2285.06% (p=0.002 n=6)   320.500m ± 20%  +2355.94% (p=0.002 n=6)    8.450m ± 12%   -35.25% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-64               3.056 ±  4%      4.474 ±  6%    +46.41% (p=0.002 n=6)      4.612 ±  8%    +50.93% (p=0.002 n=6)      5.274 ±  2%    +72.61% (p=0.002 n=6)      5.291 ± 19%    +73.14% (p=0.002 n=6)      5.213 ±  4%    +70.60% (p=0.002 n=6)     5.358 ± 16%   +75.35% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-64             22.00m ±  6%    234.50m ±  8%   +965.91% (p=0.002 n=6)    243.20m ±  8%  +1005.45% (p=0.002 n=6)    257.00m ±  9%  +1068.18% (p=0.002 n=6)    462.00m ±  8%  +2000.00% (p=0.002 n=6)    462.55m ± 10%  +2002.50% (p=0.002 n=6)    14.05m ±  5%   -36.14% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-64          17.25m ±  1%    187.10m ± 10%   +984.64% (p=0.002 n=6)    197.60m ±  9%  +1045.51% (p=0.002 n=6)    202.30m ±  4%  +1072.75% (p=0.002 n=6)    487.45m ±  8%  +2725.80% (p=0.002 n=6)    506.30m ±  7%  +2835.07% (p=0.002 n=6)    10.80m ±  8%   -37.39% (p=0.002 n=6)
EncodeUtf8/gb18030/subtitles-64         27.95m ±  2%    315.80m ±  5%  +1029.87% (p=0.002 n=6)    341.35m ±  9%  +1121.29% (p=0.002 n=6)    350.70m ± 10%  +1154.74% (p=0.002 n=6)    798.00m ± 15%  +2755.10% (p=0.002 n=6)    800.65m ± 17%  +2764.58% (p=0.002 n=6)    18.15m ± 28%   -35.06% (p=0.002 n=6)
EncodeUtf8/gb18030/web-64                3.006 ± 10%      4.576 ± 18%    +52.22% (p=0.002 n=6)      4.632 ±  7%    +54.10% (p=0.002 n=6)      5.223 ±  6%    +73.75% (p=0.002 n=6)      5.267 ± 26%    +75.22% (p=0.002 n=6)      5.106 ± 17%    +69.87% (p=0.002 n=6)     5.341 ± 39%   +77.66% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-256              13.00m ± 34%    226.90m ± 28%  +1645.38% (p=0.002 n=6)    250.85m ± 10%  +1829.62% (p=0.002 n=6)    263.10m ±  2%  +1923.85% (p=0.002 n=6)    605.25m ± 19%  +4555.77% (p=0.002 n=6)    630.65m ± 15%  +4751.15% (p=0.002 n=6)    15.05m ± 24%   +15.77% (p=0.041 n=6)
EncodeUtf8/gb18030/subtitles-256        16.00m ± 28%    253.40m ± 13%  +1483.75% (p=0.002 n=6)    264.20m ±  8%  +1551.25% (p=0.002 n=6)    269.85m ±  7%  +1586.56% (p=0.002 n=6)    647.50m ± 11%  +3946.88% (p=0.002 n=6)    632.70m ± 12%  +3854.38% (p=0.002 n=6)    15.30m ± 19%         ~ (p=0.463 n=6)
EncodeUtf8/gb18030/ascii-256             5.138 ± 12%     11.368 ± 16%   +121.24% (p=0.002 n=6)     11.558 ± 11%   +124.93% (p=0.002 n=6)     12.637 ± 23%   +145.93% (p=0.002 n=6)     12.980 ±  4%   +152.61% (p=0.002 n=6)     12.996 ±  6%   +152.92% (p=0.002 n=6)    13.028 ± 15%  +153.54% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-256         14.000m ± 39%   164.650m ±  5%  +1076.07% (p=0.002 n=6)   180.700m ±  2%  +1190.71% (p=0.002 n=6)   232.750m ±  3%  +1562.50% (p=0.002 n=6)   333.450m ± 19%  +2281.79% (p=0.002 n=6)   341.200m ± 28%  +2337.14% (p=0.002 n=6)    7.700m ± 27%   -45.00% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-256             29.90m ±  5%    405.95m ±  6%  +1257.69% (p=0.002 n=6)    413.25m ± 10%  +1282.11% (p=0.002 n=6)    429.35m ±  6%  +1335.95% (p=0.002 n=6)    992.55m ±  7%  +3219.57% (p=0.002 n=6)    993.35m ± 30%  +3222.24% (p=0.002 n=6)    24.70m ±  8%   -17.39% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-256            16.40m ±  1%    239.00m ± 20%  +1357.32% (p=0.002 n=6)    246.15m ± 12%  +1400.91% (p=0.002 n=6)    259.20m ±  1%  +1480.49% (p=0.002 n=6)    463.25m ±  5%  +2724.70% (p=0.002 n=6)    461.65m ±  7%  +2714.94% (p=0.002 n=6)    15.80m ±  4%    -3.66% (p=0.002 n=6)
EncodeUtf8/gb18030/nonascii-256         12.00m ±  5%    194.00m ± 29%  +1516.67% (p=0.002 n=6)    200.15m ±  9%  +1567.92% (p=0.002 n=6)    203.75m ±  3%  +1597.92% (p=0.002 n=6)    513.65m ±  5%  +4180.42% (p=0.002 n=6)    511.15m ±  3%  +4159.58% (p=0.002 n=6)    11.95m ±  3%         ~ (p=0.429 n=6)
EncodeUtf8/gb18030/web-256              42.55m ± 20%    487.25m ± 23%  +1045.12% (p=0.002 n=6)    510.10m ± 40%  +1098.82% (p=0.002 n=6)    516.50m ±  9%  +1113.87% (p=0.002 n=6)   1181.60m ±  7%  +2676.97% (p=0.002 n=6)   1175.90m ± 32%  +2663.57% (p=0.002 n=6)    26.60m ± 14%   -37.49% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-4096             13.50m ± 17%     79.20m ± 11%   +486.67% (p=0.002 n=6)     67.35m ± 20%   +398.89% (p=0.002 n=6)    239.95m ±  4%  +1677.41% (p=0.002 n=6)    565.40m ± 32%  +4088.15% (p=0.002 n=6)    556.65m ± 41%  +4023.33% (p=0.002 n=6)    13.55m ± 25%         ~ (p=0.736 n=6)
EncodeUtf8/gb18030/ascii-4096            6.139 ±  9%     19.729 ± 26%   +221.38% (p=0.002 n=6)     19.839 ± 33%   +223.17% (p=0.002 n=6)     19.842 ± 41%   +223.22% (p=0.002 n=6)     19.204 ± 16%   +212.83% (p=0.002 n=6)     19.994 ±  9%   +225.69% (p=0.002 n=6)    19.898 ±  2%  +224.14% (p=0.002 n=6)
EncodeUtf8/gb18030/invalid-4096        11.000m ±  1%    59.250m ±  4%   +438.64% (p=0.002 n=6)    66.750m ± 33%   +506.82% (p=0.002 n=6)   211.900m ± 27%  +1826.36% (p=0.002 n=6)   337.450m ±  2%  +2967.73% (p=0.002 n=6)   347.600m ±  1%  +3060.00% (p=0.002 n=6)    8.250m ±  2%   -25.00% (p=0.002 n=6)
EncodeUtf8/gb18030/mail-4096            14.60m ±  1%     98.00m ±  4%   +571.23% (p=0.002 n=6)     79.90m ±  2%   +447.26% (p=0.002 n=6)    259.20m ±  1%  +1675.34% (p=0.002 n=6)    610.20m ±  3%  +4079.45% (p=0.002 n=6)    608.90m ± 31%  +4070.55% (p=0.002 n=6)    15.15m ±  1%    +3.77% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-4096           14.85m ± 15%     97.75m ±  6%   +558.25% (p=0.002 n=6)     82.30m ±  5%   +454.21% (p=0.002 n=6)    257.00m ±  1%  +1630.64% (p=0.002 n=6)    456.20m ±  2%  +2972.05% (p=0.002 n=6)    448.90m ±  9%  +2922.90% (p=0.002 n=6)    14.05m ± 19%         ~ (p=0.513 n=6)
EncodeUtf8/gb18030/nonascii-4096        11.60m ±  4%     68.75m ± 12%   +492.67% (p=0.002 n=6)     55.90m ±  8%   +381.90% (p=0.002 n=6)    205.75m ± 12%  +1673.71% (p=0.002 n=6)    499.75m ± 31%  +4208.19% (p=0.002 n=6)    504.50m ± 29%  +4249.14% (p=0.002 n=6)    11.85m ± 11%         ~ (p=0.374 n=6)
EncodeUtf8/gb18030/subtitles-4096       15.25m ± 17%     87.75m ±  9%   +475.41% (p=0.002 n=6)     71.65m ±  1%   +369.84% (p=0.002 n=6)    255.05m ±  7%  +1572.46% (p=0.002 n=6)    601.90m ±  8%  +3846.89% (p=0.002 n=6)    607.85m ± 17%  +3885.90% (p=0.002 n=6)    14.10m ±  8%         ~ (p=0.065 n=6)
EncodeUtf8/gb18030/web-4096             13.10m ± 24%     83.10m ± 18%   +534.35% (p=0.002 n=6)     68.40m ±  3%   +422.14% (p=0.002 n=6)    231.50m ±  5%  +1667.18% (p=0.002 n=6)    542.30m ±  8%  +4039.69% (p=0.002 n=6)    552.10m ± 11%  +4114.50% (p=0.002 n=6)    13.15m ± 13%         ~ (p=0.907 n=6)
EncodeUtf8/gb18030/mail-65536           15.60m ± 19%     63.80m ± 22%   +308.97% (p=0.002 n=6)     57.90m ± 20%   +271.15% (p=0.002 n=6)    268.65m ±  6%  +1622.12% (p=0.002 n=6)    613.15m ± 10%  +3830.45% (p=0.002 n=6)    613.40m ±  8%  +3832.05% (p=0.002 n=6)    15.35m ±  7%         ~ (p=0.452 n=6)
EncodeUtf8/gb18030/web-65536            12.95m ± 25%     54.95m ± 16%   +324.32% (p=0.002 n=6)     49.45m ± 10%   +281.85% (p=0.002 n=6)    224.30m ±  2%  +1632.05% (p=0.002 n=6)    524.90m ± 34%  +3953.28% (p=0.002 n=6)    524.10m ± 34%  +3947.10% (p=0.002 n=6)    12.75m ± 20%         ~ (p=0.097 n=6)
EncodeUtf8/gb18030/ascii-65536           6.775 ± 13%     21.264 ± 36%   +213.88% (p=0.002 n=6)     20.742 ± 23%   +206.17% (p=0.002 n=6)     22.214 ±  8%   +227.90% (p=0.002 n=6)     22.224 ±  0%   +228.04% (p=0.002 n=6)     22.130 ±  3%   +226.66% (p=0.002 n=6)    22.078 ±  6%  +225.89% (p=0.002 n=6)
EncodeUtf8/gb18030/csv-65536            13.40m ± 13%     65.05m ± 13%   +385.45% (p=0.002 n=6)     57.90m ±  9%   +332.09% (p=0.002 n=6)    246.45m ±  3%  +1739.18% (p=0.002 n=6)    572.00m ± 25%  +4168.66% (p=0.002 n=6)    573.35m ±  5%  +4178.73% (p=0.002 n=6)    13.80m ± 20%         ~ (p=0.732 n=6)
EncodeUtf8/gb18030/invalid-65536       10.800m ±  6%    49.050m ± 22%   +354.17% (p=0.002 n=6)    54.100m ±  6%   +400.93% (p=0.002 n=6)   167.850m ± 23%  +1454.17% (p=0.002 n=6)   228.550m ± 34%  +2016.20% (p=0.002 n=6)   228.500m ± 17%  +2015.74% (p=0.002 n=6)    8.200m ± 32%   -24.07% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-65536          16.30m ±  7%     65.35m ±  1%   +300.92% (p=0.002 n=6)     59.85m ±  1%   +267.18% (p=0.002 n=6)    253.10m ±  4%  +1452.76% (p=0.002 n=6)    440.30m ± 18%  +2601.23% (p=0.002 n=6)    441.45m ± 20%  +2608.28% (p=0.002 n=6)    15.10m ± 30%    -7.36% (p=0.013 n=6)
EncodeUtf8/gb18030/nonascii-65536       11.85m ±  8%     48.75m ±  4%   +311.39% (p=0.002 n=6)     44.70m ±  5%   +277.22% (p=0.002 n=6)    205.65m ±  4%  +1635.44% (p=0.002 n=6)    503.30m ± 12%  +4147.26% (p=0.002 n=6)    497.70m ±  3%  +4100.00% (p=0.002 n=6)    11.40m ± 10%         ~ (p=0.054 n=6)
EncodeUtf8/gb18030/subtitles-65536      15.40m ±  5%     62.15m ±  3%   +303.57% (p=0.002 n=6)     55.80m ±  1%   +262.34% (p=0.002 n=6)    260.30m ±  5%  +1590.26% (p=0.002 n=6)    577.20m ± 28%  +3648.05% (p=0.002 n=6)    586.95m ±  2%  +3711.36% (p=0.002 n=6)    14.75m ±  7%    -4.22% (p=0.013 n=6)
EncodeUtf8/gb18030/web-1048576          12.70m ± 13%     53.50m ±  6%   +321.26% (p=0.002 n=6)     48.15m ± 12%   +279.13% (p=0.002 n=6)    220.85m ± 21%  +1638.98% (p=0.002 n=6)    505.90m ± 17%  +3883.46% (p=0.002 n=6)    509.70m ±  8%  +3913.39% (p=0.002 n=6)    12.65m ± 27%         ~ (p=1.000 n=6)
EncodeUtf8/gb18030/ascii-1048576         6.828 ± 19%     18.978 ± 18%   +177.95% (p=0.002 n=6)     18.035 ± 15%   +164.15% (p=0.002 n=6)     19.236 ±  9%   +181.74% (p=0.002 n=6)     19.895 ±  4%   +191.39% (p=0.002 n=6)     19.535 ± 26%   +186.11% (p=0.002 n=6)    18.544 ± 23%  +171.59% (p=0.002 n=6)
EncodeUtf8/gb18030/mixed-1048576        15.85m ± 11%     62.90m ±  2%   +296.85% (p=0.002 n=6)     57.55m ±  7%   +263.09% (p=0.002 n=6)    250.35m ± 13%  +1479.50% (p=0.002 n=6)    422.30m ± 12%  +2564.35% (p=0.002 n=6)    435.85m ±  7%  +2649.84% (p=0.002 n=6)    14.55m ±  9%    -8.20% (p=0.030 n=6)
EncodeUtf8/gb18030/nonascii-1048576     11.40m ± 28%     48.50m ±  4%   +325.44% (p=0.002 n=6)     44.60m ±  4%   +291.23% (p=0.002 n=6)    204.45m ±  6%  +1693.42% (p=0.002 n=6)    496.05m ±  4%  +4251.32% (p=0.002 n=6)    486.55m ± 10%  +4167.98% (p=0.002 n=6)    11.55m ± 14%         ~ (p=0.848 n=6)
EncodeUtf16/gb18030/ascii-16             2.456 ± 14%      2.882 ±  8%    +17.34% (p=0.002 n=6)      2.828 ±  5%    +15.15% (p=0.002 n=6)      2.766 ± 20%          ~ (p=0.132 n=6)      2.877 ± 19%    +17.14% (p=0.041 n=6)      2.926 ±  2%    +19.16% (p=0.002 n=6)     2.727 ± 15%         ~ (p=0.180 n=6)
EncodeUtf16/gb18030/csv-16               2.236 ± 12%      2.798 ± 18%    +25.14% (p=0.015 n=6)      2.810 ± 11%    +25.67% (p=0.002 n=6)      2.878 ± 13%    +28.74% (p=0.004 n=6)      2.892 ± 11%    +29.34% (p=0.002 n=6)      2.763 ± 29%          ~ (p=0.180 n=6)     2.557 ± 45%         ~ (p=0.310 n=6)
EncodeUtf16/gb18030/invalid-16          9.100m ±  9%   168.400m ± 17%  +1750.55% (p=0.002 n=6)   206.650m ± 26%  +2170.88% (p=0.002 n=6)   231.850m ±  1%  +2447.80% (p=0.002 n=6)   650.150m ±  1%  +7044.51% (p=0.002 n=6)   623.100m ± 25%  +6747.25% (p=0.002 n=6)   14.300m ± 29%   +57.14% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-16              2.478 ± 12%      2.921 ±  2%    +17.88% (p=0.002 n=6)      2.874 ±  4%    +15.97% (p=0.002 n=6)      2.808 ± 12%    +13.31% (p=0.015 n=6)      2.933 ±  5%    +18.36% (p=0.002 n=6)      2.968 ± 29%          ~ (p=0.065 n=6)     2.853 ± 51%         ~ (p=0.065 n=6)
EncodeUtf16/gb18030/mixed-16            26.35m ± 15%    205.50m ±  9%   +679.89% (p=0.002 n=6)    240.55m ± 16%   +812.90% (p=0.002 n=6)    290.85m ± 12%  +1003.80% (p=0.002 n=6)    763.80m ± 20%  +2798.67% (p=0.002 n=6)    700.55m ± 14%  +2558.63% (p=0.002 n=6)    14.55m ± 13%   -44.78% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-16        12.300m ± 21%   102.050m ±  5%   +729.67% (p=0.002 n=6)   135.850m ±  5%  +1004.47% (p=0.002 n=6)   143.650m ±  6%  +1067.89% (p=0.002 n=6)   471.800m ±  3%  +3735.77% (p=0.002 n=6)   469.200m ±  2%  +3714.63% (p=0.002 n=6)    7.000m ±  3%   -43.09% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-16         2.473 ± 11%      2.652 ± 12%          ~ (p=0.132 n=6)      2.609 ± 13%          ~ (p=0.394 n=6)      2.860 ± 29%          ~ (p=0.065 n=6)      2.913 ± 29%          ~ (p=0.065 n=6)      2.946 ± 37%          ~ (p=0.065 n=6)     2.790 ±  4%   +12.84% (p=0.002 n=6)
EncodeUtf16/gb18030/web-16               2.318 ± 20%      2.808 ±  9%    +21.15% (p=0.002 n=6)      2.760 ± 11%    +19.08% (p=0.004 n=6)      2.862 ± 17%    +23.47% (p=0.004 n=6)      2.856 ± 16%    +23.22% (p=0.004 n=6)      2.953 ±  7%    +27.39% (p=0.002 n=6)     2.796 ± 10%   +20.62% (p=0.002 n=6)
EncodeUtf16/gb18030/ascii-64             5.994 ± 19%      9.580 ± 28%    +59.82% (p=0.002 n=6)      9.250 ± 14%    +54.32% (p=0.002 n=6)      9.269 ± 10%    +54.64% (p=0.002 n=6)      9.466 ±  9%    +57.93% (p=0.002 n=6)      8.961 ± 14%    +49.51% (p=0.002 n=6)     8.768 ± 40%   +46.28% (p=0.041 n=6)
EncodeUtf16/gb18030/csv-64              69.75m ±  7%    618.85m ±  2%   +787.24% (p=0.002 n=6)    794.25m ±  7%  +1038.71% (p=0.002 n=6)    833.65m ±  4%  +1095.20% (p=0.002 n=6)   2280.95m ± 14%  +3170.18% (p=0.002 n=6)   2341.10m ± 11%  +3256.42% (p=0.002 n=6)    42.15m ± 16%   -39.57% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-64         13.350m ± 10%   169.750m ± 13%  +1171.54% (p=0.002 n=6)   176.250m ± 13%  +1220.22% (p=0.002 n=6)   256.800m ±  9%  +1823.60% (p=0.002 n=6)   388.550m ± 14%  +2810.49% (p=0.002 n=6)   390.800m ±  7%  +2827.34% (p=0.002 n=6)    8.400m ±  7%   -37.08% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-64              5.639 ± 19%      9.172 ± 17%    +62.66% (p=0.002 n=6)      9.519 ±  5%    +68.80% (p=0.002 n=6)      9.414 ± 26%    +66.95% (p=0.002 n=6)      9.605 ± 44%    +70.34% (p=0.041 n=6)      9.307 ± 11%    +65.05% (p=0.002 n=6)     8.533 ± 24%   +51.33% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-64            21.80m ± 34%    209.20m ± 35%   +859.63% (p=0.002 n=6)    251.80m ± 41%  +1055.05% (p=0.002 n=6)    283.15m ±  9%  +1198.85% (p=0.002 n=6)    509.80m ± 14%  +2238.53% (p=0.002 n=6)    504.00m ±  9%  +2211.93% (p=0.002 n=6)    13.55m ± 14%   -37.84% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-64        10.850m ± 14%   100.600m ± 25%   +827.19% (p=0.002 n=6)   130.950m ± 27%  +1106.91% (p=0.002 n=6)   150.700m ± 15%  +1288.94% (p=0.002 n=6)   532.800m ±  8%  +4810.60% (p=0.002 n=6)   532.900m ± 10%  +4811.52% (p=0.002 n=6)    6.650m ± 11%   -38.71% (p=0.002 n=6)
EncodeUtf16/gb18030/subtitles-64        35.85m ± 28%    338.75m ± 24%   +844.91% (p=0.002 n=6)    456.35m ± 15%  +1172.94% (p=0.002 n=6)    480.10m ± 12%  +1239.19% (p=0.002 n=6)   1425.55m ± 26%  +3876.43% (p=0.002 n=6)   1455.20m ± 27%  +3959.14% (p=0.002 n=6)    21.80m ± 41%   -39.19% (p=0.002 n=6)
EncodeUtf16/gb18030/web-64               5.991 ± 17%      9.412 ± 23%    +57.10% (p=0.002 n=6)      9.566 ±  5%    +59.66% (p=0.002 n=6)      9.521 ± 48%          ~ (p=0.065 n=6)      9.508 ± 40%    +58.70% (p=0.026 n=6)      9.442 ± 23%    +57.60% (p=0.002 n=6)     8.959 ± 31%   +49.53% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-256             11.50m ± 33%    196.05m ± 20%  +1604.78% (p=0.002 n=6)    263.20m ±  7%  +2188.70% (p=0.002 n=6)    285.55m ±  2%  +2383.04% (p=0.002 n=6)    906.80m ±  6%  +7785.22% (p=0.002 n=6)    904.10m ± 38%  +7761.74% (p=0.002 n=6)    13.55m ± 25%   +17.83% (p=0.039 n=6)
EncodeUtf16/gb18030/subtitles-256       15.45m ±  8%    214.50m ±  6%  +1288.35% (p=0.002 n=6)    274.00m ± 12%  +1673.46% (p=0.002 n=6)    297.55m ±  4%  +1825.89% (p=0.002 n=6)    977.30m ±  8%  +6225.57% (p=0.002 n=6)    959.15m ± 13%  +6108.09% (p=0.002 n=6)    14.75m ± 37%         ~ (p=0.106 n=6)
EncodeUtf16/gb18030/ascii-256            10.23 ±  6%      21.60 ±  3%   +111.25% (p=0.002 n=6)      21.90 ± 12%   +114.12% (p=0.002 n=6)      21.33 ± 19%   +108.60% (p=0.002 n=6)      20.43 ± 29%    +99.82% (p=0.002 n=6)      21.22 ± 22%   +107.47% (p=0.002 n=6)     21.61 ± 13%  +111.29% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-256        15.200m ± 10%   179.950m ±  8%  +1083.88% (p=0.002 n=6)   210.400m ±  4%  +1284.21% (p=0.002 n=6)   283.850m ±  5%  +1767.43% (p=0.002 n=6)   432.800m ± 22%  +2747.37% (p=0.002 n=6)   458.150m ±  8%  +2914.14% (p=0.002 n=6)    8.800m ±  2%   -42.11% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-256            41.45m ± 25%    479.65m ± 13%  +1057.18% (p=0.002 n=6)    602.95m ±  7%  +1354.64% (p=0.002 n=6)    666.65m ±  4%  +1508.32% (p=0.002 n=6)   2072.95m ± 11%  +4901.09% (p=0.002 n=6)   2087.00m ± 13%  +4934.98% (p=0.002 n=6)    31.75m ± 12%   -23.40% (p=0.026 n=6)
EncodeUtf16/gb18030/mixed-256           16.05m ±  5%    204.35m ±  1%  +1173.21% (p=0.002 n=6)    253.95m ± 28%  +1482.24% (p=0.002 n=6)    267.05m ± 13%  +1563.86% (p=0.002 n=6)    426.05m ±  2%  +2554.52% (p=0.002 n=6)    428.70m ±  3%  +2571.03% (p=0.002 n=6)    15.25m ±  4%    -4.98% (p=0.019 n=6)
EncodeUtf16/gb18030/nonascii-256        7.700m ± 14%   112.300m ±  2%  +1358.44% (p=0.002 n=6)   142.000m ±  1%  +1744.16% (p=0.002 n=6)   155.550m ±  2%  +1920.13% (p=0.002 n=6)   562.250m ±  4%  +7201.95% (p=0.002 n=6)   556.050m ± 23%  +7121.43% (p=0.002 n=6)    7.750m ± 20%         ~ (p=0.532 n=6)
EncodeUtf16/gb18030/web-256             62.25m ± 11%    636.60m ±  5%   +922.65% (p=0.002 n=6)    767.50m ±  4%  +1132.93% (p=0.002 n=6)    877.30m ±  2%  +1309.32% (p=0.002 n=6)   2574.20m ±  5%  +4035.26% (p=0.002 n=6)   2658.40m ± 22%  +4170.52% (p=0.002 n=6)    43.05m ± 22%   -30.84% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-4096            11.15m ±  3%     79.85m ±  7%   +616.14% (p=0.002 n=6)     60.65m ±  2%   +443.95% (p=0.002 n=6)    228.70m ±  9%  +1951.12% (p=0.002 n=6)    741.65m ±  8%  +6551.57% (p=0.002 n=6)    744.10m ± 12%  +6573.54% (p=0.002 n=6)    11.30m ± 11%         ~ (p=0.470 n=6)
EncodeUtf16/gb18030/ascii-4096           12.27 ±  1%      35.80 ± 11%   +191.72% (p=0.002 n=6)      37.23 ± 13%   +203.41% (p=0.002 n=6)      36.93 ± 16%   +200.97% (p=0.002 n=6)      33.54 ±  7%   +173.32% (p=0.002 n=6)      34.03 ±  6%   +177.27% (p=0.002 n=6)     36.96 ± 33%  +201.21% (p=0.002 n=6)
EncodeUtf16/gb18030/invalid-4096       11.100m ±  5%    67.900m ±  8%   +511.71% (p=0.002 n=6)    74.850m ±  3%   +574.32% (p=0.002 n=6)   256.700m ±  4%  +2212.61% (p=0.002 n=6)   432.600m ±  6%  +3797.30% (p=0.002 n=6)   426.400m ± 11%  +3741.44% (p=0.002 n=6)    8.400m ± 15%   -24.32% (p=0.002 n=6)
EncodeUtf16/gb18030/mail-4096           13.45m ±  8%    103.75m ±  4%   +671.38% (p=0.002 n=6)     78.50m ± 21%   +483.64% (p=0.002 n=6)    274.45m ±  4%  +1940.52% (p=0.002 n=6)    913.10m ±  3%  +6688.85% (p=0.002 n=6)    870.10m ±  5%  +6369.14% (p=0.002 n=6)    13.35m ± 14%         ~ (p=1.000 n=6)
EncodeUtf16/gb18030/mixed-4096          16.55m ±  6%    104.75m ± 30%   +532.93% (p=0.002 n=6)     79.10m ±  5%   +377.95% (p=0.002 n=6)    275.50m ±  2%  +1564.65% (p=0.002 n=6)    395.15m ± 10%  +2287.61% (p=0.002 n=6)    409.35m ±  9%  +2373.41% (p=0.002 n=6)    14.30m ± 17%   -13.60% (p=0.002 n=6)
EncodeUtf16/gb18030/nonascii-4096       7.550m ± 32%    49.050m ± 32%   +549.67% (p=0.002 n=6)    40.100m ± 10%   +431.13% (p=0.002 n=6)   153.050m ± 13%  +1927.15% (p=0.002 n=6)   578.150m ± 12%  +7557.62% (p=0.002 n=6)   568.100m ±  3%  +7424.50% (p=0.002 n=6)    7.800m ±  4%    +3.31% (p=0.039 n=6)
EncodeUtf16/gb18030/subtitles-4096      13.45m ±  5%     90.05m ± 13%   +569.52% (p=0.002 n=6)     70.30m ± 12%   +422.68% (p=0.002 n=6)    260.65m ± 15%  +1837.92% (p=0.002 n=6)    890.30m ±  4%  +6519.33% (p=0.002 n=6)    865.55m ±  6%  +6335.32% (p=0.002 n=6)    12.60m ± 10%         ~ (p=0.145 n=6)
EncodeUtf16/gb18030/web-4096            10.15m ±  9%     71.25m ± 11%   +601.97% (p=0.002 n=6)     58.55m ± 16%   +476.85% (p=0.002 n=6)    200.25m ±  7%  +1872.91% (p=0.002 n=6)    712.05m ±  7%  +6915.27% (p=0.002 n=6)    703.90m ± 38%  +6834.98% (p=0.002 n=6)    10.00m ± 20%         ~ (p=0.699 n=6)
EncodeUtf16/gb18030/mail-65536          14.85m ± 15%     64.30m ±  8%   +333.00% (p=0.002 n=6)     58.60m ±  6%   +294.61% (p=0.002 n=6)    286.85m ±  5%  +1831.65% (p=0.002 n=6)    935.60m ± 25%  +6200.34% (p=0.002 n=6)    861.60m ± 12%  +5702.02% (p=0.002 n=6)    13.90m ± 19%         ~ (p=0.569 n=6)
EncodeUtf16/gb18030/web-65536           9.850m ± 38%    44.400m ±  6%   +350.76% (p=0.002 n=6)    39.900m ±  3%   +305.08% (p=0.002 n=6)   195.050m ± 10%  +1880.20% (p=0.002 n=6)   648.350m ±  4%  +6482.23% (p=0.002 n=6)   643.800m ± 10%  +6436.04% (p=0.002 n=6)    9.800m ± 22%         ~ (p=0.777 n=6)
EncodeUtf16/gb18030/ascii-65536          12.53 ±  5%      34.61 ±  9%   +176.29% (p=0.002 n=6)      37.37 ± 18%   +198.29% (p=0.002 n=6)      38.08 ± 28%   +204.02% (p=0.002 n=6)      35.38 ± 22%   +182.42% (p=0.002 n=6)      35.79 ±  5%   +185.67% (p=0.002 n=6)     37.43 ±  5%  +198.79% (p=0.002 n=6)
EncodeUtf16/gb18030/csv-65536           12.45m ±  7%     61.30m ±  1%   +392.37% (p=0.002 n=6)     54.50m ±  2%   +337.75% (p=0.002 n=6)    248.05m ±  1%  +1892.37% (p=0.002 n=6)    785.00m ±  4%  +6205.22% (p=0.002 n=6)    800.10m ±  4%  +6326.51% (p=0.002 n=6)    12.35m ±  7%         ~ (p=0.905 n=6)
EncodeUtf16/gb18030/invalid-65536      11.250m ±  8%    52.000m ±  4%   +362.22% (p=0.002 n=6)    58.150m ± 19%   +416.89% (p=0.002 n=6)   204.200m ±  7%  +1715.11% (p=0.002 n=6)   263.450m ±  4%  +2241.78% (p=0.002 n=6)   266.800m ±  4%  +2271.56% (p=0.002 n=6)    8.850m ±  5%   -21.33% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-65536         16.10m ±  7%     64.85m ±  2%   +302.80% (p=0.002 n=6)     59.15m ±  3%   +267.39% (p=0.002 n=6)    271.70m ±  2%  +1587.58% (p=0.002 n=6)    413.50m ±  3%  +2468.32% (p=0.002 n=6)    414.70m ±  2%  +2475.78% (p=0.002 n=6)    14.55m ±  4%    -9.63% (p=0.004 n=6)
EncodeUtf16/gb18030/nonascii-65536      7.650m ± 16%    34.200m ±  3%   +347.06% (p=0.002 n=6)    30.750m ±  2%   +301.96% (p=0.002 n=6)   153.550m ±  2%  +1907.19% (p=0.002 n=6)   570.950m ± 43%  +7363.40% (p=0.002 n=6)   577.200m ± 45%  +7445.10% (p=0.002 n=6)    7.750m ± 19%         ~ (p=0.630 n=6)
EncodeUtf16/gb18030/subtitles-65536     14.50m ±  1%     62.25m ±  2%   +329.31% (p=0.002 n=6)     55.80m ±  1%   +284.83% (p=0.002 n=6)    276.20m ±  2%  +1804.83% (p=0.002 n=6)    861.60m ±  4%  +5842.07% (p=0.002 n=6)    859.70m ±  7%  +5828.97% (p=0.002 n=6)    14.20m ±  3%    -2.07% (p=0.006 n=6)
EncodeUtf16/gb18030/web-1048576         9.850m ±  2%    43.750m ±  1%   +344.16% (p=0.002 n=6)    39.700m ±  1%   +303.05% (p=0.002 n=6)   195.250m ±  3%  +1882.23% (p=0.002 n=6)   638.350m ±  7%  +6380.71% (p=0.002 n=6)   633.450m ±  3%  +6330.96% (p=0.002 n=6)    9.800m ±  7%         ~ (p=1.000 n=6)
EncodeUtf16/gb18030/ascii-1048576        12.78 ± 13%      19.35 ±  7%    +51.37% (p=0.002 n=6)      19.83 ±  7%    +55.16% (p=0.002 n=6)      19.59 ±  3%    +53.27% (p=0.002 n=6)      19.90 ±  5%    +55.69% (p=0.002 n=6)      19.31 ± 12%    +51.05% (p=0.002 n=6)     19.49 ±  2%   +52.50% (p=0.002 n=6)
EncodeUtf16/gb18030/mixed-1048576       15.75m ±  6%     62.95m ±  2%   +299.68% (p=0.002 n=6)     58.90m ±  6%   +273.97% (p=0.002 n=6)    271.05m ±  7%  +1620.95% (p=0.002 n=6)    405.70m ±  2%  +2475.87% (p=0.002 n=6)    411.35m ±  2%  +2511.75% (p=0.002 n=6)    14.60m ± 10%    -7.30% (p=0.006 n=6)
EncodeUtf16/gb18030/nonascii-1048576    7.700m ±  4%    33.700m ±  2%   +337.66% (p=0.002 n=6)    30.750m ±  5%   +299.35% (p=0.002 n=6)   152.750m ±  5%  +1883.77% (p=0.002 n=6)   569.050m ± 10%  +7290.26% (p=0.002 n=6)   566.800m ± 14%  +7261.04% (p=0.002 n=6)    7.600m ±  8%         ~ (p=0.866 n=6)
DecodeUtf8/Big5/ascii-16               1275.9m ± 34%     817.8m ±  2%    -35.90% (p=0.002 n=6)     830.7m ±  5%    -34.89% (p=0.002 n=6)     828.5m ±  2%    -35.06% (p=0.002 n=6)     818.6m ±  2%    -35.83% (p=0.002 n=6)     810.7m ± 20%    -36.46% (p=0.002 n=6)    817.2m ±  3%   -35.95% (p=0.004 n=6)
DecodeUtf8/Big5/csv-16                 1275.1m ± 16%     818.3m ±  4%    -35.82% (p=0.002 n=6)     831.8m ±  4%    -34.77% (p=0.002 n=6)     832.0m ±  2%    -34.75% (p=0.002 n=6)     829.4m ±  8%    -34.96% (p=0.002 n=6)     833.5m ±  2%    -34.64% (p=0.002 n=6)    825.2m ±  2%   -35.28% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-16              196.7m ± 11%     267.6m ± 10%    +36.02% (p=0.002 n=6)     199.2m ± 17%          ~ (p=0.093 n=6)     274.1m ± 19%    +39.32% (p=0.002 n=6)     261.5m ± 27%    +32.94% (p=0.026 n=6)     236.4m ± 20%    +20.18% (p=0.026 n=6)    258.1m ± 13%   +31.22% (p=0.002 n=6)
DecodeUtf8/Big5/mail-16                1263.9m ± 23%     822.6m ±  5%    -34.91% (p=0.002 n=6)     824.5m ± 27%    -34.76% (p=0.002 n=6)     817.8m ± 26%    -35.30% (p=0.002 n=6)     813.8m ± 21%    -35.61% (p=0.002 n=6)     827.4m ± 26%    -34.54% (p=0.002 n=6)    813.8m ± 18%   -35.61% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-16                394.6m ±  3%     402.9m ± 15%          ~ (p=0.699 n=6)     256.2m ±  2%    -35.07% (p=0.002 n=6)     417.5m ±  3%     +5.80% (p=0.004 n=6)     379.3m ±  4%     -3.88% (p=0.009 n=6)     342.6m ± 12%    -13.18% (p=0.002 n=6)    385.1m ±  7%    -2.39% (p=0.041 n=6)
DecodeUtf8/Big5/nonascii-16             423.6m ±  6%     325.3m ±  4%    -23.22% (p=0.002 n=6)     180.5m ±  3%    -57.38% (p=0.002 n=6)     344.8m ± 15%    -18.61% (p=0.002 n=6)     346.8m ± 20%    -18.14% (p=0.002 n=6)     269.9m ± 24%    -36.28% (p=0.002 n=6)    340.5m ± 10%   -19.63% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-16           1266.0m ± 36%     826.8m ± 16%    -34.69% (p=0.041 n=6)     829.2m ± 16%    -34.50% (p=0.041 n=6)     827.1m ±  2%    -34.67% (p=0.041 n=6)     820.6m ±  2%    -35.18% (p=0.041 n=6)     824.8m ±  5%    -34.85% (p=0.026 n=6)    817.9m ± 21%   -35.39% (p=0.015 n=6)
DecodeUtf8/Big5/web-16                 1223.0m ± 36%     818.4m ± 18%    -33.09% (p=0.041 n=6)     821.1m ±  2%          ~ (p=0.065 n=6)     833.8m ±  4%          ~ (p=0.065 n=6)     816.5m ± 14%    -33.24% (p=0.026 n=6)     826.5m ± 16%    -32.42% (p=0.041 n=6)    827.7m ± 18%   -32.32% (p=0.041 n=6)
DecodeUtf8/Big5/ascii-64                 3.268 ±  2%      3.177 ±  7%     -2.78% (p=0.026 n=6)      3.144 ± 11%     -3.80% (p=0.009 n=6)      3.147 ±  4%     -3.71% (p=0.002 n=6)      3.135 ± 25%     -4.09% (p=0.002 n=6)      3.177 ±  1%     -2.78% (p=0.009 n=6)     3.206 ±  5%         ~ (p=0.065 n=6)
DecodeUtf8/Big5/csv-64                 1215.1m ±  4%    1118.7m ±  4%     -7.93% (p=0.002 n=6)     600.9m ±  2%    -50.55% (p=0.002 n=6)    1171.4m ±  2%     -3.60% (p=0.026 n=6)    1156.8m ±  3%     -4.80% (p=0.015 n=6)     918.8m ±  1%    -24.38% (p=0.002 n=6)   1035.3m ± 13%   -14.79% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-64              392.8m ±  3%     487.1m ±  6%    +24.01% (p=0.002 n=6)     358.4m ±  2%     -8.76% (p=0.002 n=6)     501.4m ±  3%    +27.66% (p=0.002 n=6)     504.1m ±  5%    +28.34% (p=0.002 n=6)     440.9m ±  2%    +12.23% (p=0.002 n=6)    488.0m ±  4%   +24.24% (p=0.002 n=6)
DecodeUtf8/Big5/mail-64                  3.278 ±  3%      3.161 ±  9%     -3.57% (p=0.004 n=6)      3.184 ±  4%     -2.86% (p=0.015 n=6)      3.173 ±  2%     -3.20% (p=0.004 n=6)      3.179 ±  9%     -3.01% (p=0.015 n=6)      3.190 ±  2%     -2.68% (p=0.009 n=6)     3.209 ±  8%    -2.10% (p=0.026 n=6)
DecodeUtf8/Big5/mixed-64                413.9m ± 18%     406.4m ±  2%          ~ (p=0.485 n=6)     266.3m ±  4%    -35.65% (p=0.002 n=6)     427.2m ±  3%          ~ (p=0.065 n=6)     428.3m ±  5%     +3.48% (p=0.026 n=6)     351.1m ± 15%    -15.17% (p=0.041 n=6)    424.1m ± 14%         ~ (p=0.132 n=6)
DecodeUtf8/Big5/nonascii-64             594.6m ±  6%     420.9m ± 18%    -29.20% (p=0.002 n=6)     189.3m ±  8%    -68.16% (p=0.002 n=6)     406.8m ±  7%    -31.58% (p=0.002 n=6)     406.6m ±  6%    -31.61% (p=0.002 n=6)     320.1m ± 11%    -46.17% (p=0.002 n=6)    381.7m ±  4%   -35.81% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-64           1009.0m ± 23%     774.5m ± 35%    -23.24% (p=0.015 n=6)     393.9m ±  3%    -60.96% (p=0.002 n=6)     805.6m ±  4%    -20.16% (p=0.041 n=6)     803.8m ±  4%    -20.34% (p=0.041 n=6)     628.3m ± 24%    -37.73% (p=0.002 n=6)    773.6m ± 22%   -23.33% (p=0.009 n=6)
DecodeUtf8/Big5/web-64                   3.189 ± 31%      3.171 ± 17%          ~ (p=0.699 n=6)      3.153 ±  7%          ~ (p=0.699 n=6)      3.202 ± 15%          ~ (p=0.818 n=6)      3.202 ± 18%          ~ (p=0.699 n=6)      3.176 ± 21%          ~ (p=0.699 n=6)     3.164 ± 19%         ~ (p=0.699 n=6)
DecodeUtf8/Big5/subtitles-256           804.9m ±  6%     627.2m ±  4%    -22.08% (p=0.002 n=6)     293.1m ±  7%    -63.59% (p=0.002 n=6)     632.0m ±  6%    -21.47% (p=0.002 n=6)     626.4m ± 38%    -22.17% (p=0.002 n=6)     484.9m ± 30%    -39.76% (p=0.002 n=6)    582.0m ±  2%   -27.69% (p=0.002 n=6)
DecodeUtf8/Big5/ascii-256                6.209 ±  3%     10.006 ±  1%    +61.15% (p=0.002 n=6)     10.040 ±  1%    +61.68% (p=0.002 n=6)      9.935 ±  4%    +60.01% (p=0.002 n=6)     10.020 ±  7%    +61.37% (p=0.002 n=6)     10.055 ± 18%    +61.93% (p=0.002 n=6)    10.088 ±  1%   +62.46% (p=0.002 n=6)
DecodeUtf8/Big5/csv-256                 761.9m ± 12%     621.0m ± 26%    -18.51% (p=0.002 n=6)     275.4m ± 20%    -63.85% (p=0.002 n=6)     596.6m ±  6%    -21.71% (p=0.002 n=6)     601.6m ±  4%    -21.05% (p=0.002 n=6)     431.4m ± 14%    -43.39% (p=0.002 n=6)    524.1m ± 27%   -31.21% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-256             286.6m ± 15%     360.9m ± 13%    +25.92% (p=0.002 n=6)     298.2m ± 20%          ~ (p=0.162 n=6)     368.8m ±  5%    +28.68% (p=0.002 n=6)     355.9m ±  9%    +24.20% (p=0.002 n=6)     341.5m ± 23%    +19.16% (p=0.035 n=6)    361.5m ± 18%   +26.15% (p=0.002 n=6)
DecodeUtf8/Big5/mail-256               1402.6m ± 13%    1137.9m ±  2%    -18.87% (p=0.002 n=6)     543.4m ±  5%    -61.26% (p=0.002 n=6)    1144.8m ±  4%    -18.39% (p=0.002 n=6)    1164.5m ±  2%    -16.98% (p=0.002 n=6)     911.3m ±  6%    -35.03% (p=0.002 n=6)    973.6m ± 14%   -30.59% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-256               390.7m ±  5%     379.1m ± 11%          ~ (p=0.065 n=6)     270.9m ±  4%    -30.67% (p=0.002 n=6)     389.9m ±  5%          ~ (p=0.818 n=6)     389.4m ±  3%          ~ (p=0.937 n=6)     324.9m ±  5%    -16.82% (p=0.002 n=6)    386.1m ±  3%         ~ (p=0.937 n=6)
DecodeUtf8/Big5/nonascii-256            608.2m ± 18%     453.4m ±  7%    -25.46% (p=0.002 n=6)     188.4m ±  4%    -69.02% (p=0.002 n=6)     461.6m ± 14%    -24.11% (p=0.002 n=6)     466.6m ± 15%    -23.27% (p=0.002 n=6)     318.9m ±  5%    -47.56% (p=0.002 n=6)    386.6m ± 10%   -36.44% (p=0.002 n=6)
DecodeUtf8/Big5/web-256                1605.6m ±  4%    1170.0m ±  7%    -27.13% (p=0.002 n=6)     571.7m ±  3%    -64.39% (p=0.002 n=6)    1220.8m ±  5%    -23.97% (p=0.002 n=6)    1172.6m ±  7%    -26.97% (p=0.002 n=6)     991.1m ±  5%    -38.27% (p=0.002 n=6)   1048.4m ±  4%   -34.71% (p=0.002 n=6)
DecodeUtf8/Big5/csv-4096                656.1m ± 42%     523.8m ± 46%          ~ (p=0.180 n=6)     226.3m ± 23%    -65.50% (p=0.002 n=6)     525.6m ± 42%          ~ (p=0.240 n=6)     532.6m ± 24%          ~ (p=0.310 n=6)     398.1m ±  3%          ~ (p=0.065 n=6)    466.1m ± 14%         ~ (p=0.065 n=6)
DecodeUtf8/Big5/ascii-4096               8.543 ± 14%     19.481 ± 36%   +128.03% (p=0.002 n=6)     19.530 ± 31%   +128.61% (p=0.002 n=6)     19.930 ± 17%   +133.29% (p=0.002 n=6)     20.013 ±  7%   +134.25% (p=0.002 n=6)     19.573 ±  8%   +129.11% (p=0.002 n=6)    19.592 ± 25%  +129.33% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-4096            323.7m ± 10%     402.2m ± 15%    +24.27% (p=0.002 n=6)     311.2m ±  7%          ~ (p=0.132 n=6)     389.6m ± 27%          ~ (p=0.065 n=6)     399.7m ± 38%          ~ (p=0.065 n=6)     357.7m ± 16%          ~ (p=0.132 n=6)    394.8m ±  4%   +21.96% (p=0.002 n=6)
DecodeUtf8/Big5/mail-4096               872.2m ± 27%     681.2m ± 15%    -21.89% (p=0.041 n=6)     296.5m ± 10%    -66.01% (p=0.002 n=6)     678.5m ± 18%    -22.20% (p=0.041 n=6)     695.1m ± 17%    -20.30% (p=0.041 n=6)     517.0m ± 41%    -40.72% (p=0.002 n=6)    587.5m ± 29%   -32.64% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-4096              317.0m ± 21%     382.2m ± 14%    +20.58% (p=0.002 n=6)     226.2m ± 26%    -28.64% (p=0.002 n=6)     397.2m ± 15%    +25.30% (p=0.002 n=6)     396.9m ±  1%    +25.21% (p=0.002 n=6)     332.1m ±  4%     +4.76% (p=0.006 n=6)    398.0m ±  0%   +25.55% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-4096           501.1m ± 11%     468.8m ±  1%          ~ (p=0.065 n=6)     177.4m ±  1%    -64.60% (p=0.002 n=6)     475.1m ± 21%          ~ (p=0.065 n=6)     473.8m ± 29%          ~ (p=0.065 n=6)     336.3m ± 14%    -32.89% (p=0.002 n=6)    393.5m ±  4%   -21.48% (p=0.002 n=6)
DecodeUtf8/Big5/subtitles-4096          752.2m ±  3%     583.2m ± 12%    -22.47% (p=0.002 n=6)     254.4m ±  3%    -66.19% (p=0.002 n=6)     550.4m ± 15%    -26.84% (p=0.002 n=6)     552.4m ± 10%    -26.57% (p=0.002 n=6)     424.6m ±  9%    -43.56% (p=0.002 n=6)    493.1m ±  1%   -34.44% (p=0.002 n=6)
DecodeUtf8/Big5/web-4096                665.5m ± 14%     506.6m ± 15%    -23.88% (p=0.002 n=6)     217.2m ± 21%    -67.36% (p=0.002 n=6)     513.5m ± 20%    -22.84% (p=0.002 n=6)     516.0m ±  3%    -22.46% (p=0.002 n=6)     376.4m ± 24%    -43.43% (p=0.002 n=6)    450.9m ±  6%   -32.24% (p=0.002 n=6)
DecodeUtf8/Big5/csv-65536               501.4m ±  8%     522.7m ± 15%          ~ (p=0.065 n=6)     217.8m ± 11%    -56.56% (p=0.002 n=6)     505.9m ± 29%          ~ (p=0.513 n=6)     530.8m ±  1%     +5.84% (p=0.002 n=6)     390.8m ±  3%    -22.07% (p=0.002 n=6)    466.5m ±  2%         ~ (p=0.058 n=6)
DecodeUtf8/Big5/subtitles-65536         379.8m ±  2%     556.3m ±  7%    +46.47% (p=0.002 n=6)     230.8m ± 13%    -39.23% (p=0.002 n=6)     543.6m ± 42%          ~ (p=0.065 n=6)     556.2m ± 35%          ~ (p=0.065 n=6)     419.9m ± 13%          ~ (p=0.065 n=6)    496.1m ± 20%   +30.62% (p=0.002 n=6)
DecodeUtf8/Big5/web-65536               339.6m ±  6%     482.8m ± 19%    +42.15% (p=0.002 n=6)     192.5m ± 17%    -43.34% (p=0.002 n=6)     480.8m ± 12%    +41.56% (p=0.002 n=6)     493.9m ±  2%    +45.43% (p=0.002 n=6)     359.1m ± 25%          ~ (p=0.065 n=6)    431.5m ± 29%         ~ (p=0.065 n=6)
DecodeUtf8/Big5/ascii-65536              8.901 ± 34%     22.082 ± 30%   +148.08% (p=0.002 n=6)     21.706 ±  3%   +143.85% (p=0.002 n=6)     22.036 ± 10%   +147.56% (p=0.002 n=6)     21.904 ±  3%   +146.08% (p=0.002 n=6)     22.024 ± 12%   +147.42% (p=0.002 n=6)    21.772 ± 22%  +144.59% (p=0.002 n=6)
DecodeUtf8/Big5/invalid-65536           111.5m ±  7%     187.2m ±  4%    +67.94% (p=0.002 n=6)     125.9m ± 16%          ~ (p=0.223 n=6)     187.8m ± 13%    +68.39% (p=0.002 n=6)     188.1m ±  6%    +68.74% (p=0.002 n=6)     173.0m ± 27%    +55.20% (p=0.002 n=6)    185.8m ± 29%   +66.64% (p=0.002 n=6)
DecodeUtf8/Big5/mail-65536              414.2m ±  7%     643.9m ±  7%    +55.48% (p=0.002 n=6)     268.2m ±  2%    -35.23% (p=0.002 n=6)     641.1m ± 11%    +54.81% (p=0.002 n=6)     648.7m ±  2%    +56.63% (p=0.002 n=6)     464.6m ± 13%    +12.18% (p=0.041 n=6)    565.8m ± 32%         ~ (p=0.065 n=6)
DecodeUtf8/Big5/mixed-65536             242.4m ±  6%     383.1m ±  3%    +58.07% (p=0.002 n=6)     223.0m ± 13%     -7.98% (p=0.004 n=6)     393.8m ± 12%    +62.46% (p=0.002 n=6)     396.7m ± 17%    +63.66% (p=0.002 n=6)     333.8m ±  3%    +37.69% (p=0.002 n=6)    395.2m ±  5%   +63.06% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-65536          303.3m ± 53%     464.9m ± 30%    +53.28% (p=0.002 n=6)     175.4m ± 31%    -42.17% (p=0.037 n=6)     468.5m ± 44%    +54.45% (p=0.041 n=6)     467.8m ± 39%    +54.22% (p=0.041 n=6)     331.3m ± 39%     +9.22% (p=0.041 n=6)    428.8m ± 44%   +41.38% (p=0.041 n=6)
DecodeUtf8/Big5/ascii-1048576            8.721 ± 49%     19.662 ± 32%   +125.46% (p=0.002 n=6)     19.310 ±  8%   +121.42% (p=0.002 n=6)     19.806 ±  8%   +127.12% (p=0.002 n=6)     19.853 ± 26%   +127.66% (p=0.002 n=6)     19.383 ±  5%   +122.26% (p=0.002 n=6)    19.506 ±  5%  +123.68% (p=0.002 n=6)
DecodeUtf8/Big5/mixed-1048576           240.5m ± 14%     375.1m ± 11%    +55.97% (p=0.002 n=6)     220.1m ±  3%          ~ (p=0.065 n=6)     390.6m ±  7%    +62.39% (p=0.002 n=6)     388.6m ± 12%    +61.56% (p=0.002 n=6)     326.1m ±  7%    +35.59% (p=0.002 n=6)    383.3m ± 21%   +59.40% (p=0.002 n=6)
DecodeUtf8/Big5/nonascii-1048576        297.7m ±  8%     459.1m ± 12%    +54.23% (p=0.002 n=6)     174.2m ±  5%    -41.47% (p=0.002 n=6)     466.2m ± 35%    +56.60% (p=0.002 n=6)     464.8m ±  8%    +56.11% (p=0.002 n=6)     334.9m ±  9%    +12.51% (p=0.002 n=6)    432.3m ± 14%   +45.21% (p=0.002 n=6)
DecodeUtf8/Big5/web-1048576             330.5m ±  9%     468.8m ±  3%    +41.83% (p=0.002 n=6)     191.4m ± 20%    -42.10% (p=0.002 n=6)     478.8m ± 24%    +44.89% (p=0.002 n=6)     472.6m ± 35%    +42.98% (p=0.041 n=6)     345.8m ± 18%          ~ (p=0.180 n=6)    455.4m ± 30%   +37.78% (p=0.041 n=6)
DecodeUtf16/Big5/ascii-16                1.180 ±  6%      1.279 ±  9%     +8.31% (p=0.026 n=6)      1.410 ±  3%    +19.46% (p=0.002 n=6)      1.530 ±  1%    +29.63% (p=0.002 n=6)      1.430 ± 18%    +21.11% (p=0.026 n=6)      1.506 ± 22%    +27.60% (p=0.026 n=6)     1.365 ± 24%         ~ (p=0.065 n=6)
DecodeUtf16/Big5/csv-16                  1.149 ± 13%      1.258 ± 10%     +9.49% (p=0.026 n=6)      1.311 ± 13%    +14.10% (p=0.041 n=6)      1.522 ± 27%    +32.49% (p=0.041 n=6)      1.418 ± 28%    +23.44% (p=0.041 n=6)      1.508 ±  6%    +31.27% (p=0.002 n=6)     1.410 ± 19%   +22.67% (p=0.026 n=6)
DecodeUtf16/Big5/invalid-16             183.5m ±  3%     313.1m ± 42%    +70.65% (p=0.026 n=6)     189.3m ±  3%     +3.16% (p=0.019 n=6)     290.4m ±  1%    +58.28% (p=0.002 n=6)     270.8m ± 12%    +47.57% (p=0.002 n=6)     259.5m ±  2%    +41.42% (p=0.002 n=6)    268.6m ±  2%   +46.38% (p=0.002 n=6)
DecodeUtf16/Big5/mail-16                 1.156 ±  2%      1.296 ±  6%    +12.02% (p=0.002 n=6)      1.423 ± 25%          ~ (p=0.065 n=6)      1.449 ± 38%          ~ (p=0.394 n=6)      1.426 ± 11%    +23.29% (p=0.002 n=6)      1.511 ±  3%    +30.63% (p=0.002 n=6)     1.412 ±  1%   +22.11% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-16               425.9m ± 30%     482.6m ±  8%    +13.30% (p=0.002 n=6)     257.6m ±  2%    -39.54% (p=0.002 n=6)     451.6m ±  2%     +6.01% (p=0.002 n=6)     451.2m ±  2%     +5.93% (p=0.002 n=6)     427.2m ±  3%          ~ (p=0.589 n=6)    464.2m ± 11%    +8.98% (p=0.041 n=6)
DecodeUtf16/Big5/nonascii-16            476.3m ± 19%     452.7m ± 18%     -4.95% (p=0.035 n=6)     191.2m ± 40%    -59.86% (p=0.002 n=6)     390.2m ± 45%    -18.08% (p=0.026 n=6)     418.2m ± 34%    -12.19% (p=0.041 n=6)     351.1m ± 23%    -26.29% (p=0.002 n=6)    374.6m ± 25%   -21.35% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-16            1.160 ±  1%      1.292 ±  6%    +11.38% (p=0.002 n=6)      1.420 ±  7%    +22.41% (p=0.002 n=6)      1.528 ±  3%    +31.72% (p=0.002 n=6)      1.422 ±  3%    +22.55% (p=0.002 n=6)      1.492 ±  4%    +28.66% (p=0.002 n=6)     1.394 ±  8%   +20.15% (p=0.002 n=6)
DecodeUtf16/Big5/web-16                  1.151 ±  2%      1.284 ± 12%          ~ (p=0.065 n=6)      1.409 ±  8%    +22.37% (p=0.002 n=6)      1.528 ± 12%    +32.75% (p=0.002 n=6)      1.411 ±  5%    +22.61% (p=0.002 n=6)      1.502 ±  5%    +30.53% (p=0.002 n=6)     1.406 ±  4%   +22.14% (p=0.002 n=6)
DecodeUtf16/Big5/ascii-64                3.001 ±  6%      4.455 ±  4%    +48.48% (p=0.002 n=6)      4.557 ±  2%    +51.87% (p=0.002 n=6)      4.876 ±  3%    +62.49% (p=0.002 n=6)      4.415 ±  9%    +47.13% (p=0.002 n=6)      4.549 ± 40%          ~ (p=0.065 n=6)     4.298 ± 15%   +43.25% (p=0.002 n=6)
DecodeUtf16/Big5/csv-64                1354.2m ± 13%    1406.8m ± 16%          ~ (p=0.240 n=6)     631.7m ± 16%    -53.35% (p=0.002 n=6)    1204.5m ± 17%    -11.05% (p=0.041 n=6)    1228.8m ±  9%     -9.26% (p=0.041 n=6)    1156.6m ± 24%    -14.59% (p=0.002 n=6)   1238.8m ±  4%         ~ (p=0.065 n=6)
DecodeUtf16/Big5/invalid-64             394.7m ±  8%     533.5m ± 15%    +35.17% (p=0.002 n=6)     325.0m ± 12%    -17.66% (p=0.002 n=6)     532.7m ± 38%          ~ (p=0.065 n=6)     531.4m ± 39%          ~ (p=0.065 n=6)     465.6m ± 24%          ~ (p=0.065 n=6)    520.5m ± 28%   +31.88% (p=0.041 n=6)
DecodeUtf16/Big5/mail-64                 2.964 ± 34%      4.459 ± 27%    +50.42% (p=0.002 n=6)      4.416 ± 15%    +48.98% (p=0.002 n=6)      4.776 ± 15%    +61.11% (p=0.002 n=6)      4.366 ± 25%    +47.30% (p=0.002 n=6)      4.545 ± 40%    +53.34% (p=0.041 n=6)     4.380 ± 38%   +47.76% (p=0.041 n=6)
DecodeUtf16/Big5/mixed-64               457.2m ± 40%     451.8m ± 28%          ~ (p=0.240 n=6)     264.6m ± 29%    -42.12% (p=0.002 n=6)     445.4m ± 27%          ~ (p=0.416 n=6)     467.0m ± 20%          ~ (p=0.310 n=6)     421.7m ± 28%          ~ (p=0.065 n=6)    444.5m ± 24%         ~ (p=0.699 n=6)
DecodeUtf16/Big5/nonascii-64            664.8m ±  5%     559.7m ± 10%    -15.81% (p=0.002 n=6)     196.5m ±  9%    -70.44% (p=0.002 n=6)     492.7m ± 19%    -25.89% (p=0.002 n=6)     528.5m ± 15%    -20.49% (p=0.002 n=6)     415.0m ±  8%    -37.58% (p=0.002 n=6)    473.1m ± 14%   -28.83% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-64          1105.8m ± 12%    1033.8m ± 15%          ~ (p=0.093 n=6)     407.0m ±  4%    -63.20% (p=0.002 n=6)     832.9m ±  5%    -24.68% (p=0.002 n=6)     878.1m ± 21%    -20.58% (p=0.002 n=6)     805.0m ± 25%    -27.20% (p=0.002 n=6)    861.0m ± 25%   -22.13% (p=0.002 n=6)
DecodeUtf16/Big5/web-64                  2.945 ±  6%      4.478 ±  3%    +52.06% (p=0.002 n=6)      4.428 ± 35%    +50.37% (p=0.026 n=6)      4.953 ±  7%    +68.18% (p=0.002 n=6)      4.303 ± 18%    +46.10% (p=0.002 n=6)      4.410 ±  6%    +49.75% (p=0.002 n=6)     4.338 ± 10%   +47.28% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-256          957.9m ± 30%     822.6m ± 14%          ~ (p=0.065 n=6)     290.2m ±  5%    -69.70% (p=0.002 n=6)     675.8m ± 30%    -29.45% (p=0.026 n=6)     754.9m ± 10%          ~ (p=0.065 n=6)     639.4m ±  3%    -33.25% (p=0.002 n=6)    685.4m ± 23%   -28.45% (p=0.026 n=6)
DecodeUtf16/Big5/ascii-256               5.530 ±  5%     10.790 ±  6%    +95.12% (p=0.002 n=6)     11.649 ±  6%   +110.64% (p=0.002 n=6)     12.456 ±  1%   +125.24% (p=0.002 n=6)     11.130 ±  7%   +101.25% (p=0.002 n=6)     11.747 ±  5%   +112.41% (p=0.002 n=6)    11.257 ±  1%  +103.54% (p=0.002 n=6)
DecodeUtf16/Big5/csv-256                890.6m ±  6%     797.4m ±  6%    -10.46% (p=0.002 n=6)     292.1m ±  5%    -67.21% (p=0.002 n=6)     740.5m ±  2%    -16.86% (p=0.002 n=6)     699.5m ±  2%    -21.46% (p=0.002 n=6)     590.9m ±  4%    -33.65% (p=0.002 n=6)    699.1m ±  4%   -21.50% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-256            291.7m ±  3%     386.3m ±  1%    +32.43% (p=0.002 n=6)     274.0m ± 11%     -6.09% (p=0.004 n=6)     388.9m ±  9%    +33.32% (p=0.002 n=6)     384.4m ±  3%    +31.76% (p=0.002 n=6)     353.7m ±  3%    +21.24% (p=0.002 n=6)    383.6m ± 10%   +31.52% (p=0.002 n=6)
DecodeUtf16/Big5/mail-256              1592.8m ± 27%    1488.0m ± 38%          ~ (p=0.132 n=6)     537.9m ±  8%    -66.23% (p=0.002 n=6)    1177.2m ±  3%    -26.10% (p=0.026 n=6)    1190.2m ± 11%    -25.28% (p=0.026 n=6)    1093.0m ± 12%    -31.38% (p=0.002 n=6)   1091.2m ±  7%   -31.50% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-256              453.3m ±  3%     411.0m ±  4%     -9.34% (p=0.002 n=6)     256.5m ±  5%    -43.42% (p=0.002 n=6)     415.8m ±  6%     -8.27% (p=0.002 n=6)     420.0m ±  8%     -7.36% (p=0.002 n=6)     406.7m ±  5%    -10.29% (p=0.002 n=6)    422.8m ±  2%    -6.74% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-256           689.6m ±  5%     581.5m ±  2%    -15.68% (p=0.002 n=6)     187.0m ±  5%    -72.88% (p=0.002 n=6)     468.9m ± 29%    -32.00% (p=0.002 n=6)     533.2m ± 21%    -22.67% (p=0.002 n=6)     400.0m ± 12%    -42.00% (p=0.002 n=6)    475.8m ± 11%   -31.01% (p=0.002 n=6)
DecodeUtf16/Big5/web-256               1722.0m ± 15%    1606.9m ± 28%          ~ (p=0.093 n=6)     603.2m ±  5%    -64.97% (p=0.002 n=6)    1228.7m ±  2%    -28.65% (p=0.002 n=6)    1276.1m ±  2%    -25.90% (p=0.002 n=6)    1208.6m ±  3%    -29.81% (p=0.002 n=6)   1215.7m ±  8%   -29.40% (p=0.002 n=6)
DecodeUtf16/Big5/csv-4096               876.6m ±  4%     682.1m ± 12%    -22.18% (p=0.002 n=6)     228.4m ±  4%    -73.94% (p=0.002 n=6)     535.2m ±  5%    -38.94% (p=0.002 n=6)     615.9m ± 26%    -29.74% (p=0.002 n=6)     511.1m ±  2%    -41.69% (p=0.002 n=6)    541.1m ±  1%   -38.27% (p=0.002 n=6)
DecodeUtf16/Big5/ascii-4096              6.719 ± 14%     19.073 ± 10%   +183.84% (p=0.002 n=6)     19.558 ±  4%   +191.06% (p=0.002 n=6)     19.787 ±  1%   +194.47% (p=0.002 n=6)     19.540 ±  8%   +190.80% (p=0.002 n=6)     19.615 ±  5%   +191.91% (p=0.002 n=6)    19.575 ±  6%  +191.32% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-4096           333.4m ±  6%     428.2m ±  5%    +28.45% (p=0.002 n=6)     294.1m ± 20%    -11.77% (p=0.002 n=6)     426.9m ± 23%    +28.06% (p=0.041 n=6)     430.2m ± 11%    +29.04% (p=0.002 n=6)     392.8m ±  7%    +17.83% (p=0.002 n=6)    429.9m ±  7%   +28.95% (p=0.002 n=6)
DecodeUtf16/Big5/mail-4096             1097.6m ±  6%     899.0m ±  6%    -18.10% (p=0.002 n=6)     305.4m ± 15%    -72.18% (p=0.002 n=6)     681.2m ±  7%    -37.93% (p=0.002 n=6)     788.2m ± 40%    -28.19% (p=0.002 n=6)     670.6m ± 40%    -38.90% (p=0.002 n=6)    692.0m ±  3%   -36.95% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-4096             381.3m ± 12%     411.2m ±  7%     +7.81% (p=0.015 n=6)     219.2m ±  3%    -42.53% (p=0.002 n=6)     421.5m ±  1%    +10.54% (p=0.002 n=6)     423.4m ±  2%    +11.04% (p=0.002 n=6)     375.9m ±  2%          ~ (p=0.394 n=6)    424.4m ±  2%   +11.28% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-4096          787.1m ±  7%     615.5m ±  2%    -21.81% (p=0.002 n=6)     181.2m ±  8%    -76.99% (p=0.002 n=6)     493.1m ± 25%    -37.35% (p=0.002 n=6)     547.9m ± 24%    -30.39% (p=0.002 n=6)     420.6m ± 36%    -46.57% (p=0.002 n=6)    512.9m ±  4%   -34.85% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-4096         950.9m ± 23%     745.4m ±  2%    -21.61% (p=0.041 n=6)     256.1m ±  3%    -73.06% (p=0.002 n=6)     564.5m ±  3%    -40.64% (p=0.002 n=6)     647.9m ±  7%    -31.86% (p=0.002 n=6)     559.8m ±  9%    -41.13% (p=0.002 n=6)    608.7m ±  4%   -35.99% (p=0.002 n=6)
DecodeUtf16/Big5/web-4096               872.9m ± 14%     681.0m ±  3%    -21.98% (p=0.002 n=6)     221.7m ±  3%    -74.60% (p=0.002 n=6)     530.9m ±  3%    -39.18% (p=0.002 n=6)     575.0m ±  3%    -34.13% (p=0.002 n=6)     502.6m ±  4%    -42.43% (p=0.002 n=6)    549.8m ±  1%   -37.02% (p=0.002 n=6)
DecodeUtf16/Big5/csv-65536              837.6m ± 24%     670.9m ±  9%    -19.90% (p=0.041 n=6)     225.1m ±  1%    -73.13% (p=0.002 n=6)     553.4m ±  8%    -33.93% (p=0.002 n=6)     600.9m ±  6%    -28.27% (p=0.002 n=6)     509.6m ±  5%    -39.16% (p=0.002 n=6)    534.8m ± 14%   -36.15% (p=0.002 n=6)
DecodeUtf16/Big5/subtitles-65536        484.7m ± 11%     723.8m ±  3%    +49.32% (p=0.002 n=6)     240.9m ± 14%    -50.30% (p=0.002 n=6)     612.9m ± 10%    +26.46% (p=0.002 n=6)     652.3m ± 12%    +34.58% (p=0.002 n=6)     533.3m ±  4%    +10.03% (p=0.002 n=6)    585.4m ±  5%   +20.78% (p=0.002 n=6)
DecodeUtf16/Big5/web-65536              450.5m ±  3%     625.0m ±  3%    +38.73% (p=0.002 n=6)     197.9m ±  4%    -56.06% (p=0.002 n=6)     539.2m ±  4%    +19.69% (p=0.002 n=6)     552.8m ±  4%    +22.71% (p=0.002 n=6)     466.5m ± 19%          ~ (p=0.132 n=6)    486.9m ±  2%    +8.09% (p=0.002 n=6)
DecodeUtf16/Big5/ascii-65536             7.741 ± 12%     18.966 ± 11%   +145.01% (p=0.002 n=6)     19.065 ±  4%   +146.29% (p=0.002 n=6)     19.051 ±  1%   +146.10% (p=0.002 n=6)     19.098 ±  4%   +146.71% (p=0.002 n=6)     18.990 ±  3%   +145.31% (p=0.002 n=6)    18.789 ±  5%  +142.72% (p=0.002 n=6)
DecodeUtf16/Big5/invalid-65536          114.0m ±  3%     176.5m ± 11%    +54.80% (p=0.002 n=6)     126.6m ±  1%    +11.00% (p=0.002 n=6)     190.6m ±  9%    +67.12% (p=0.002 n=6)     191.2m ±  1%    +67.69% (p=0.002 n=6)     182.9m ±  4%    +60.41% (p=0.002 n=6)    191.1m ±  1%   +67.60% (p=0.002 n=6)
DecodeUtf16/Big5/mail-65536             506.0m ±  8%     802.1m ± 28%    +58.53% (p=0.002 n=6)     270.6m ± 21%    -46.51% (p=0.002 n=6)     655.0m ± 11%    +29.44% (p=0.002 n=6)     697.6m ± 12%    +37.88% (p=0.002 n=6)     595.5m ± 33%          ~ (p=0.132 n=6)    665.4m ± 30%   +31.50% (p=0.041 n=6)
DecodeUtf16/Big5/mixed-65536            261.1m ± 10%     403.3m ±  3%    +54.46% (p=0.002 n=6)     210.9m ±  6%    -19.21% (p=0.002 n=6)     421.2m ±  7%    +61.30% (p=0.002 n=6)     418.3m ± 14%    +60.21% (p=0.002 n=6)     370.7m ±  9%    +41.96% (p=0.002 n=6)    421.1m ±  8%   +61.26% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-65536         475.4m ± 17%     609.8m ±  1%    +28.27% (p=0.002 n=6)     174.2m ±  1%    -63.35% (p=0.002 n=6)     589.9m ±  4%    +24.10% (p=0.002 n=6)     553.1m ±  6%    +16.35% (p=0.002 n=6)     432.4m ± 12%     -9.06% (p=0.041 n=6)    525.0m ±  7%   +10.43% (p=0.009 n=6)
DecodeUtf16/Big5/ascii-1048576           7.284 ± 17%      9.315 ±  6%    +27.88% (p=0.002 n=6)      9.309 ± 20%    +27.80% (p=0.004 n=6)      9.453 ± 13%    +29.79% (p=0.002 n=6)      9.350 ± 11%    +28.37% (p=0.002 n=6)      9.331 ±  7%    +28.10% (p=0.002 n=6)     9.235 ±  9%   +26.79% (p=0.002 n=6)
DecodeUtf16/Big5/mixed-1048576          256.6m ± 16%     408.1m ± 14%    +59.06% (p=0.002 n=6)     208.2m ±  8%    -18.88% (p=0.002 n=6)     412.5m ± 16%    +60.76% (p=0.002 n=6)     419.3m ± 10%    +63.41% (p=0.002 n=6)     364.0m ±  5%    +41.86% (p=0.002 n=6)    421.2m ±  6%   +64.17% (p=0.002 n=6)
DecodeUtf16/Big5/nonascii-1048576       457.8m ± 10%     605.9m ±  7%    +32.34% (p=0.002 n=6)     174.4m ±  9%    -61.89% (p=0.002 n=6)     602.0m ±  2%    +31.51% (p=0.002 n=6)     582.8m ±  6%    +27.30% (p=0.002 n=6)     433.5m ±  3%          ~ (p=0.065 n=6)    544.2m ±  3%   +18.87% (p=0.002 n=6)
DecodeUtf16/Big5/web-1048576            437.0m ±  6%     615.6m ± 15%    +40.87% (p=0.002 n=6)     201.0m ±  6%    -54.00% (p=0.002 n=6)     519.3m ±  4%    +18.83% (p=0.002 n=6)     562.8m ±  2%    +28.78% (p=0.002 n=6)     461.6m ±  3%     +5.62% (p=0.002 n=6)    487.4m ± 13%   +11.54% (p=0.041 n=6)
EncodeUtf8/Big5/ascii-16                 1.296 ±  3%      1.102 ±  5%    -14.92% (p=0.002 n=6)      1.125 ±  4%    -13.18% (p=0.002 n=6)      1.124 ±  5%    -13.26% (p=0.002 n=6)      1.125 ±  2%    -13.22% (p=0.002 n=6)      1.124 ±  4%    -13.22% (p=0.002 n=6)     1.098 ±  3%   -15.29% (p=0.002 n=6)
EncodeUtf8/Big5/csv-16                   1.305 ±  7%      1.113 ±  1%    -14.70% (p=0.002 n=6)      1.109 ±  3%    -15.01% (p=0.002 n=6)      1.120 ±  7%    -14.12% (p=0.002 n=6)      1.114 ± 29%    -14.63% (p=0.002 n=6)      1.104 ± 19%    -15.38% (p=0.002 n=6)     1.095 ±  8%   -16.10% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-16              3.200m ±  0%   146.950m ± 10%  +4492.19% (p=0.002 n=6)   185.800m ±  9%  +5706.25% (p=0.002 n=6)   223.800m ± 39%  +6893.75% (p=0.002 n=6)   300.100m ± 32%  +9278.12% (p=0.002 n=6)   294.150m ± 19%  +9092.19% (p=0.002 n=6)   12.500m ± 10%  +290.62% (p=0.002 n=6)
EncodeUtf8/Big5/mail-16                  1.304 ±  8%      1.115 ±  6%    -14.49% (p=0.002 n=6)      1.109 ±  2%    -14.96% (p=0.002 n=6)      1.120 ±  5%    -14.08% (p=0.002 n=6)      1.118 ±  2%    -14.25% (p=0.002 n=6)      1.110 ±  2%    -14.84% (p=0.002 n=6)     1.091 ±  1%   -16.32% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-16                180.8m ±  2%     197.5m ± 13%          ~ (p=0.065 n=6)     247.3m ±  2%    +36.77% (p=0.002 n=6)     239.9m ±  7%    +32.65% (p=0.002 n=6)     457.9m ±  8%   +153.19% (p=0.002 n=6)     462.2m ±  6%   +155.60% (p=0.002 n=6)    239.3m ±  1%   +32.35% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-16             31.60m ±  4%    156.00m ±  8%   +393.67% (p=0.002 n=6)    201.10m ±  6%   +536.39% (p=0.002 n=6)    193.30m ±  1%   +511.71% (p=0.002 n=6)    466.40m ± 11%  +1375.95% (p=0.002 n=6)    467.25m ±  2%  +1378.64% (p=0.002 n=6)    81.55m ±  1%  +158.07% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-16             1.305 ±  1%      1.120 ±  2%    -14.16% (p=0.002 n=6)      1.117 ± 27%    -14.41% (p=0.002 n=6)      1.106 ±  5%    -15.23% (p=0.002 n=6)      1.108 ±  2%    -15.08% (p=0.002 n=6)      1.111 ±  5%    -14.85% (p=0.002 n=6)     1.095 ±  3%   -16.08% (p=0.002 n=6)
EncodeUtf8/Big5/web-16                   1.286 ± 14%      1.125 ±  0%          ~ (p=0.065 n=6)      1.123 ± 22%    -12.67% (p=0.026 n=6)      1.105 ±  7%    -14.11% (p=0.015 n=6)      1.124 ± 16%    -12.59% (p=0.041 n=6)      1.123 ±  2%          ~ (p=0.065 n=6)     1.100 ±  0%   -14.49% (p=0.004 n=6)
EncodeUtf8/Big5/ascii-64                 3.128 ±  3%      4.242 ±  2%    +35.59% (p=0.002 n=6)      4.163 ±  1%    +33.06% (p=0.002 n=6)      4.215 ±  4%    +34.73% (p=0.002 n=6)      4.183 ±  1%    +33.71% (p=0.002 n=6)      4.178 ±  1%    +33.56% (p=0.002 n=6)     4.272 ±  1%   +36.54% (p=0.002 n=6)
EncodeUtf8/Big5/csv-64                  91.05m ± 15%    403.25m ±  1%   +342.89% (p=0.002 n=6)    521.35m ± 15%   +472.60% (p=0.002 n=6)    513.90m ± 20%   +464.42% (p=0.002 n=6)   1138.50m ±  3%  +1150.41% (p=0.002 n=6)   1126.15m ±  4%  +1136.85% (p=0.002 n=6)   245.60m ± 19%  +169.74% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-64              5.200m ± 54%   203.050m ± 45%  +3804.81% (p=0.002 n=6)   236.800m ± 15%  +4453.85% (p=0.002 n=6)   235.200m ± 10%  +4423.08% (p=0.002 n=6)   351.550m ±  7%  +6660.58% (p=0.002 n=6)   354.050m ± 19%  +6708.65% (p=0.002 n=6)   17.250m ± 61%  +231.73% (p=0.002 n=6)
EncodeUtf8/Big5/mail-64                  3.148 ±  3%      4.257 ±  2%    +35.21% (p=0.002 n=6)      4.139 ±  3%    +31.47% (p=0.002 n=6)      4.231 ±  1%    +34.40% (p=0.002 n=6)      4.130 ±  6%    +31.20% (p=0.002 n=6)      4.086 ±  3%    +29.80% (p=0.002 n=6)     4.126 ±  7%   +31.06% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-64                37.45m ±  1%    205.40m ±  2%   +448.46% (p=0.002 n=6)    252.75m ±  3%   +574.90% (p=0.002 n=6)    258.00m ± 11%   +588.92% (p=0.002 n=6)    469.60m ± 17%  +1153.94% (p=0.002 n=6)    443.20m ± 15%  +1083.44% (p=0.002 n=6)    99.40m ± 25%  +165.42% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-64             20.50m ±  3%    164.20m ±  2%   +700.98% (p=0.002 n=6)    201.65m ±  6%   +883.66% (p=0.002 n=6)    207.45m ±  3%   +911.95% (p=0.002 n=6)    506.70m ±  6%  +2371.71% (p=0.002 n=6)    533.15m ±  1%  +2500.73% (p=0.002 n=6)    61.85m ±  7%  +201.71% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-64            46.50m ± 11%    287.85m ±  2%   +519.03% (p=0.002 n=6)    359.05m ±  6%   +672.15% (p=0.002 n=6)    353.80m ±  2%   +660.86% (p=0.002 n=6)    855.75m ±  1%  +1740.32% (p=0.002 n=6)    856.70m ±  7%  +1742.37% (p=0.002 n=6)   131.90m ±  4%  +183.66% (p=0.002 n=6)
EncodeUtf8/Big5/web-64                   3.133 ± 26%      4.190 ± 28%    +33.71% (p=0.041 n=6)      4.120 ± 28%    +31.47% (p=0.041 n=6)      4.249 ±  4%    +35.60% (p=0.002 n=6)      4.179 ±  4%    +33.37% (p=0.002 n=6)      4.171 ± 12%    +33.11% (p=0.002 n=6)     4.237 ± 12%   +35.20% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-256           26.60m ± 10%    223.10m ± 16%   +738.72% (p=0.002 n=6)    263.90m ±  7%   +892.11% (p=0.002 n=6)    284.00m ±  1%   +967.67% (p=0.002 n=6)    717.70m ±  1%  +2598.12% (p=0.002 n=6)    715.55m ±  2%  +2590.04% (p=0.002 n=6)    78.60m ±  2%  +195.49% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-256                4.981 ±  6%     12.167 ±  4%   +144.27% (p=0.002 n=6)     12.188 ±  1%   +144.69% (p=0.002 n=6)     11.520 ±  3%   +131.26% (p=0.002 n=6)     12.142 ±  5%   +143.75% (p=0.002 n=6)     12.147 ±  4%   +143.85% (p=0.002 n=6)    12.121 ±  1%  +143.35% (p=0.002 n=6)
EncodeUtf8/Big5/csv-256                 25.15m ±  6%    225.05m ±  1%   +794.83% (p=0.002 n=6)    266.90m ±  1%   +961.23% (p=0.002 n=6)    279.40m ±  2%  +1010.93% (p=0.002 n=6)    684.60m ±  8%  +2622.07% (p=0.002 n=6)    688.85m ±  1%  +2638.97% (p=0.002 n=6)    72.30m ± 12%  +187.48% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-256             3.800m ±  0%   180.150m ±  2%  +4640.79% (p=0.002 n=6)   213.300m ±  4%  +5513.16% (p=0.002 n=6)   228.900m ±  4%  +5923.68% (p=0.002 n=6)   337.350m ±  2%  +8777.63% (p=0.002 n=6)   334.950m ± 10%  +8714.47% (p=0.002 n=6)   13.800m ±  1%  +263.16% (p=0.002 n=6)
EncodeUtf8/Big5/mail-256                46.45m ±  2%    374.75m ±  5%   +706.78% (p=0.002 n=6)    457.65m ±  5%   +885.25% (p=0.002 n=6)    476.20m ±  2%   +925.19% (p=0.002 n=6)   1178.40m ±  3%  +2436.92% (p=0.002 n=6)   1146.45m ±  3%  +2368.14% (p=0.002 n=6)   136.30m ±  2%  +193.43% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-256               27.90m ±  8%    207.35m ±  1%   +643.19% (p=0.002 n=6)    245.20m ± 15%   +778.85% (p=0.002 n=6)    261.65m ± 23%   +837.81% (p=0.002 n=6)    477.35m ±  2%  +1610.93% (p=0.002 n=6)    479.30m ±  4%  +1617.92% (p=0.002 n=6)    77.45m ±  7%  +177.60% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-256            19.60m ± 10%    171.25m ±  2%   +773.72% (p=0.002 n=6)    201.20m ±  1%   +926.53% (p=0.002 n=6)    214.50m ±  8%   +994.39% (p=0.002 n=6)    548.85m ±  5%  +2700.26% (p=0.002 n=6)    552.75m ±  1%  +2720.15% (p=0.002 n=6)    56.10m ± 16%  +186.22% (p=0.002 n=6)
EncodeUtf8/Big5/web-256                 51.05m ±  9%    411.45m ±  5%   +705.97% (p=0.002 n=6)    489.65m ±  2%   +859.16% (p=0.002 n=6)    506.45m ±  4%   +892.07% (p=0.002 n=6)   1206.40m ±  7%  +2263.17% (p=0.002 n=6)   1223.25m ± 10%  +2296.18% (p=0.002 n=6)   155.00m ±  8%  +203.62% (p=0.002 n=6)
EncodeUtf8/Big5/csv-4096                18.65m ± 15%     99.65m ± 10%   +434.32% (p=0.002 n=6)     68.65m ± 10%   +268.10% (p=0.002 n=6)    239.05m ±  5%  +1181.77% (p=0.002 n=6)    605.25m ±  7%  +3145.31% (p=0.002 n=6)    604.80m ±  8%  +3142.90% (p=0.002 n=6)    49.45m ± 10%  +165.15% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-4096               6.267 ±  4%     19.672 ± 10%   +213.89% (p=0.002 n=6)     19.739 ±  8%   +214.95% (p=0.002 n=6)     19.194 ± 10%   +206.26% (p=0.002 n=6)     19.895 ±  6%   +217.44% (p=0.002 n=6)     19.676 ±  4%   +213.95% (p=0.002 n=6)    19.843 ± 11%  +216.62% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-4096            4.550m ± 10%   109.850m ± 15%  +2314.29% (p=0.002 n=6)    92.650m ±  2%  +1936.26% (p=0.002 n=6)   227.750m ±  3%  +4905.49% (p=0.002 n=6)   350.600m ±  8%  +7605.49% (p=0.002 n=6)   353.400m ±  9%  +7667.03% (p=0.002 n=6)   14.750m ±  6%  +224.18% (p=0.002 n=6)
EncodeUtf8/Big5/mail-4096               23.10m ±  6%    210.95m ± 12%   +813.20% (p=0.002 n=6)    115.10m ±  6%   +398.27% (p=0.002 n=6)    292.35m ± 12%  +1165.58% (p=0.002 n=6)    717.15m ± 33%  +3004.55% (p=0.002 n=6)    716.40m ± 35%  +3001.30% (p=0.002 n=6)    61.10m ±  5%  +164.50% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-4096              23.40m ±  2%    162.45m ±  6%   +594.23% (p=0.002 n=6)     98.20m ±  4%   +319.66% (p=0.002 n=6)    264.15m ±  6%  +1028.85% (p=0.002 n=6)    480.50m ±  8%  +1953.42% (p=0.002 n=6)    480.45m ±  8%  +1953.21% (p=0.002 n=6)    56.50m ±  1%  +141.45% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-4096           16.35m ±  9%     81.40m ±  3%   +397.86% (p=0.002 n=6)     61.30m ± 10%   +274.92% (p=0.002 n=6)    215.80m ±  5%  +1219.88% (p=0.002 n=6)    550.20m ±  8%  +3265.14% (p=0.002 n=6)    552.50m ± 11%  +3279.20% (p=0.002 n=6)    42.10m ±  9%  +157.49% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-4096          21.40m ±  4%    138.30m ±  2%   +546.26% (p=0.002 n=6)     93.15m ±  3%   +335.28% (p=0.002 n=6)    267.50m ±  9%  +1150.00% (p=0.002 n=6)    672.60m ±  4%  +3042.99% (p=0.002 n=6)    669.75m ±  6%  +3029.67% (p=0.002 n=6)    54.65m ±  4%  +155.37% (p=0.002 n=6)
EncodeUtf8/Big5/web-4096                18.25m ±  6%    107.90m ± 19%   +491.23% (p=0.002 n=6)     79.00m ±  1%   +332.88% (p=0.002 n=6)    241.65m ±  3%  +1224.11% (p=0.002 n=6)    613.35m ±  6%  +3260.82% (p=0.002 n=6)    608.50m ±  5%  +3234.25% (p=0.002 n=6)    49.75m ±  4%  +172.60% (p=0.002 n=6)
EncodeUtf8/Big5/csv-65536               18.90m ± 13%     73.75m ± 21%   +290.21% (p=0.002 n=6)     60.20m ± 21%   +218.52% (p=0.002 n=6)    244.00m ± 15%  +1191.01% (p=0.002 n=6)    598.35m ± 24%  +3065.87% (p=0.002 n=6)    603.95m ± 46%  +3095.50% (p=0.002 n=6)    47.85m ± 13%  +153.17% (p=0.002 n=6)
EncodeUtf8/Big5/subtitles-65536         20.15m ± 35%     70.90m ±  3%   +251.86% (p=0.002 n=6)     62.05m ±  3%   +207.94% (p=0.002 n=6)    266.15m ±  1%  +1220.84% (p=0.002 n=6)    663.05m ± 31%  +3190.57% (p=0.002 n=6)    637.20m ± 19%  +3062.28% (p=0.002 n=6)    49.30m ± 17%  +144.67% (p=0.002 n=6)
EncodeUtf8/Big5/web-65536               17.50m ±  2%     62.15m ±  4%   +255.14% (p=0.002 n=6)     53.90m ± 11%   +208.00% (p=0.002 n=6)    229.85m ± 17%  +1213.43% (p=0.002 n=6)    566.20m ± 21%  +3135.43% (p=0.002 n=6)    576.55m ± 24%  +3194.57% (p=0.002 n=6)    44.05m ±  4%  +151.71% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-65536              6.866 ± 17%     22.090 ±  6%   +221.72% (p=0.002 n=6)     22.173 ± 10%   +222.94% (p=0.002 n=6)     21.581 ± 13%   +214.31% (p=0.002 n=6)     21.943 ±  5%   +219.58% (p=0.002 n=6)     22.041 ± 20%   +221.01% (p=0.002 n=6)    21.901 ± 17%  +218.97% (p=0.002 n=6)
EncodeUtf8/Big5/invalid-65536           4.750m ± 14%    62.650m ± 11%  +1218.95% (p=0.002 n=6)    61.050m ± 11%  +1185.26% (p=0.002 n=6)   141.750m ± 11%  +2884.21% (p=0.002 n=6)   200.150m ± 34%  +4113.68% (p=0.002 n=6)   200.450m ± 14%  +4120.00% (p=0.002 n=6)   14.900m ±  4%  +213.68% (p=0.002 n=6)
EncodeUtf8/Big5/mail-65536              22.35m ± 15%     77.75m ± 12%   +247.87% (p=0.002 n=6)     68.25m ±  4%   +205.37% (p=0.002 n=6)    290.15m ± 11%  +1198.21% (p=0.002 n=6)    699.85m ± 12%  +3031.32% (p=0.002 n=6)    716.40m ±  6%  +3105.37% (p=0.002 n=6)    55.50m ±  3%  +148.32% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-65536             21.85m ± 18%     73.15m ±  5%   +234.78% (p=0.002 n=6)     65.05m ±  3%   +197.71% (p=0.002 n=6)    256.35m ± 10%  +1073.23% (p=0.002 n=6)    460.30m ±  9%  +2006.64% (p=0.002 n=6)    450.65m ± 16%  +1962.47% (p=0.002 n=6)    52.00m ± 24%  +137.99% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-65536          16.05m ±  7%     57.65m ±  2%   +259.19% (p=0.002 n=6)     49.80m ±  5%   +210.28% (p=0.002 n=6)    215.50m ±  2%  +1242.68% (p=0.002 n=6)    544.95m ± 12%  +3295.33% (p=0.002 n=6)    552.15m ±  1%  +3340.19% (p=0.002 n=6)    40.60m ±  3%  +152.96% (p=0.002 n=6)
EncodeUtf8/Big5/ascii-1048576            6.654 ±  4%     19.741 ±  6%   +196.68% (p=0.002 n=6)     19.004 ± 14%   +185.62% (p=0.002 n=6)     19.315 ± 11%   +190.28% (p=0.002 n=6)     19.490 ±  5%   +192.92% (p=0.002 n=6)     19.514 ± 11%   +193.27% (p=0.002 n=6)    19.940 ± 14%  +199.68% (p=0.002 n=6)
EncodeUtf8/Big5/mixed-1048576           21.60m ±  1%     72.70m ± 21%   +236.57% (p=0.002 n=6)     64.65m ±  9%   +199.31% (p=0.002 n=6)    258.75m ±  2%  +1097.92% (p=0.002 n=6)    465.85m ±  6%  +2056.71% (p=0.002 n=6)    459.10m ± 12%  +2025.46% (p=0.002 n=6)    52.05m ±  1%  +140.97% (p=0.002 n=6)
EncodeUtf8/Big5/nonascii-1048576        15.45m ±  6%     57.85m ±  2%   +274.43% (p=0.002 n=6)     50.15m ±  2%   +224.60% (p=0.002 n=6)    213.05m ± 10%  +1278.96% (p=0.002 n=6)    543.90m ± 18%  +3420.39% (p=0.002 n=6)    543.05m ± 11%  +3414.89% (p=0.002 n=6)    40.30m ±  9%  +160.84% (p=0.002 n=6)
EncodeUtf8/Big5/web-1048576             16.95m ± 24%     61.75m ± 24%   +264.31% (p=0.002 n=6)     53.85m ±  6%   +217.70% (p=0.002 n=6)    228.50m ±  8%  +1248.08% (p=0.002 n=6)    564.80m ± 10%  +3232.15% (p=0.002 n=6)    567.20m ±  9%  +3246.31% (p=0.002 n=6)    43.75m ± 25%  +158.11% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-16                2.492 ±  3%      2.139 ±  1%    -14.15% (p=0.002 n=6)      2.093 ±  2%    -16.01% (p=0.002 n=6)      2.138 ± 15%    -14.22% (p=0.002 n=6)      2.130 ±  5%    -14.53% (p=0.002 n=6)      2.125 ±  1%    -14.75% (p=0.002 n=6)     2.131 ±  5%   -14.47% (p=0.002 n=6)
EncodeUtf16/Big5/csv-16                  2.484 ±  1%      2.088 ±  6%    -15.94% (p=0.002 n=6)      2.065 ±  8%    -16.86% (p=0.002 n=6)      2.145 ± 24%    -13.64% (p=0.002 n=6)      2.124 ± 23%    -14.49% (p=0.002 n=6)      2.117 ±  5%    -14.78% (p=0.002 n=6)     2.118 ±  2%   -14.73% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-16             3.750m ± 12%   136.750m ±  7%  +3546.67% (p=0.002 n=6)   160.800m ± 14%  +4188.00% (p=0.002 n=6)   212.500m ±  4%  +5566.67% (p=0.002 n=6)   282.950m ±  4%  +7445.33% (p=0.002 n=6)   288.950m ±  6%  +7605.33% (p=0.002 n=6)   11.200m ± 14%  +198.67% (p=0.002 n=6)
EncodeUtf16/Big5/mail-16                 2.464 ±  9%      2.100 ±  7%    -14.78% (p=0.002 n=6)      2.126 ±  5%    -13.70% (p=0.002 n=6)      2.116 ± 11%    -14.12% (p=0.002 n=6)      2.117 ±  1%    -14.09% (p=0.002 n=6)      2.127 ±  7%    -13.68% (p=0.002 n=6)     2.113 ±  1%   -14.24% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-16               193.5m ± 15%     217.1m ±  1%    +12.17% (p=0.002 n=6)     281.8m ±  4%    +45.60% (p=0.002 n=6)     273.9m ± 21%    +41.49% (p=0.002 n=6)     719.4m ± 38%   +271.71% (p=0.002 n=6)     721.3m ±  5%   +272.67% (p=0.002 n=6)    257.8m ± 34%   +33.17% (p=0.041 n=6)
EncodeUtf16/Big5/nonascii-16            21.25m ± 12%    106.85m ±  8%   +402.82% (p=0.002 n=6)    141.00m ±  3%   +563.53% (p=0.002 n=6)    137.20m ±  1%   +545.65% (p=0.002 n=6)    447.20m ± 21%  +2004.47% (p=0.002 n=6)    454.40m ± 15%  +2038.35% (p=0.002 n=6)    54.05m ± 10%  +154.35% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-16            2.447 ±  7%      2.094 ± 24%    -14.45% (p=0.002 n=6)      2.116 ± 12%    -13.54% (p=0.002 n=6)      2.119 ±  4%    -13.41% (p=0.002 n=6)      2.105 ± 11%    -13.97% (p=0.002 n=6)      2.067 ± 16%    -15.56% (p=0.002 n=6)     2.112 ±  2%   -13.69% (p=0.002 n=6)
EncodeUtf16/Big5/web-16                  2.429 ±  4%      2.089 ±  3%    -13.98% (p=0.002 n=6)      2.120 ±  8%    -12.71% (p=0.002 n=6)      2.146 ±  4%    -11.64% (p=0.002 n=6)      2.137 ± 12%    -12.01% (p=0.002 n=6)      2.138 ±  4%    -11.95% (p=0.002 n=6)     2.138 ±  4%   -11.99% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-64                6.210 ± 24%      7.824 ±  1%    +26.00% (p=0.002 n=6)      7.799 ± 12%    +25.60% (p=0.002 n=6)      7.772 ±  1%    +25.16% (p=0.002 n=6)      7.754 ±  2%    +24.88% (p=0.002 n=6)      7.567 ±  5%    +21.86% (p=0.002 n=6)     7.462 ±  3%   +20.16% (p=0.002 n=6)
EncodeUtf16/Big5/csv-64                 136.5m ± 18%     614.2m ± 17%   +349.96% (p=0.002 n=6)     825.9m ±  9%   +505.09% (p=0.002 n=6)     831.6m ±  1%   +509.23% (p=0.002 n=6)    2392.6m ±  9%  +1652.82% (p=0.002 n=6)    2416.2m ± 37%  +1670.15% (p=0.002 n=6)    370.0m ± 13%  +171.06% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-64             6.900m ±  1%   253.850m ±  3%  +3578.99% (p=0.002 n=6)   301.800m ± 20%  +4273.91% (p=0.002 n=6)   372.350m ±  6%  +5296.38% (p=0.002 n=6)   552.800m ± 20%  +7911.59% (p=0.002 n=6)   560.100m ±  3%  +8017.39% (p=0.002 n=6)   20.900m ±  0%  +202.90% (p=0.002 n=6)
EncodeUtf16/Big5/mail-64                 6.369 ± 14%      7.799 ±  4%    +22.46% (p=0.002 n=6)      7.730 ±  8%    +21.38% (p=0.002 n=6)      7.552 ±  7%    +18.59% (p=0.002 n=6)      7.769 ±  6%    +21.99% (p=0.002 n=6)      7.807 ±  6%    +22.59% (p=0.002 n=6)     7.586 ±  1%   +19.11% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-64               37.20m ± 22%    206.05m ±  5%   +453.90% (p=0.002 n=6)    264.65m ±  2%   +611.42% (p=0.002 n=6)    281.40m ±  9%   +656.45% (p=0.002 n=6)    503.55m ± 10%  +1253.63% (p=0.002 n=6)    508.80m ± 11%  +1267.74% (p=0.002 n=6)   103.75m ±  7%  +178.90% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-64            13.60m ± 18%    113.70m ± 26%   +736.03% (p=0.002 n=6)    138.15m ± 22%   +915.81% (p=0.002 n=6)    150.40m ±  6%  +1005.88% (p=0.002 n=6)    599.95m ±  7%  +4311.40% (p=0.002 n=6)    608.35m ±  7%  +4373.16% (p=0.002 n=6)    40.70m ±  4%  +199.26% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-64           53.60m ±  7%    342.80m ± 16%   +539.55% (p=0.002 n=6)    461.75m ±  3%   +761.47% (p=0.002 n=6)    469.75m ±  3%   +776.40% (p=0.002 n=6)   1586.05m ±  4%  +2859.05% (p=0.002 n=6)   1615.20m ±  5%  +2913.43% (p=0.002 n=6)   158.90m ± 17%  +196.46% (p=0.002 n=6)
EncodeUtf16/Big5/web-64                  6.312 ±  7%      7.775 ±  4%    +23.18% (p=0.002 n=6)      7.481 ±  7%    +18.51% (p=0.002 n=6)      7.593 ±  6%    +20.28% (p=0.002 n=6)      7.667 ± 14%    +21.45% (p=0.002 n=6)      7.815 ±  2%    +23.81% (p=0.002 n=6)     7.569 ±  3%   +19.90% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-256          27.15m ±  3%    226.35m ±  3%   +733.70% (p=0.002 n=6)    278.05m ±  2%   +924.13% (p=0.002 n=6)    306.05m ±  1%  +1027.26% (p=0.002 n=6)   1148.55m ± 11%  +4130.39% (p=0.002 n=6)   1126.50m ± 10%  +4049.17% (p=0.002 n=6)    77.50m ± 10%  +185.45% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-256               10.69 ±  5%      20.32 ±  9%    +90.17% (p=0.002 n=6)      20.50 ±  7%    +91.86% (p=0.002 n=6)      20.49 ± 22%    +91.74% (p=0.002 n=6)      21.30 ±  2%    +99.26% (p=0.002 n=6)      21.32 ±  5%    +99.52% (p=0.002 n=6)     20.37 ±  8%   +90.57% (p=0.002 n=6)
EncodeUtf16/Big5/csv-256                24.80m ±  5%    215.70m ±  8%   +769.76% (p=0.002 n=6)    275.05m ± 15%  +1009.07% (p=0.002 n=6)    299.80m ±  4%  +1108.87% (p=0.002 n=6)   1118.55m ±  6%  +4410.28% (p=0.002 n=6)   1048.90m ±  8%  +4129.44% (p=0.002 n=6)    71.00m ±  2%  +186.29% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-256            4.900m ±  2%   189.500m ±  3%  +3767.35% (p=0.002 n=6)   231.650m ±  7%  +4627.55% (p=0.002 n=6)   290.900m ±  1%  +5836.73% (p=0.002 n=6)   427.100m ±  6%  +8616.33% (p=0.002 n=6)   434.150m ±  2%  +8760.20% (p=0.002 n=6)   14.400m ±  5%  +193.88% (p=0.002 n=6)
EncodeUtf16/Big5/mail-256               65.00m ±  2%    530.50m ±  2%   +716.15% (p=0.002 n=6)    665.80m ±  2%   +924.31% (p=0.002 n=6)    718.30m ± 10%  +1005.08% (p=0.002 n=6)   2607.25m ± 20%  +3911.15% (p=0.002 n=6)   2667.60m ±  3%  +4004.00% (p=0.002 n=6)   194.35m ±  1%  +199.00% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-256              27.75m ±  3%    211.80m ±  2%   +663.24% (p=0.002 n=6)    253.35m ±  3%   +812.97% (p=0.002 n=6)    281.40m ±  1%   +914.05% (p=0.002 n=6)    430.60m ±  1%  +1451.71% (p=0.002 n=6)    430.40m ±  6%  +1450.99% (p=0.002 n=6)    76.90m ± 11%  +177.12% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-256           13.05m ± 30%    114.65m ±  4%   +778.54% (p=0.002 n=6)    140.65m ±  8%   +977.78% (p=0.002 n=6)    154.05m ±  7%  +1080.46% (p=0.002 n=6)    636.00m ± 28%  +4773.56% (p=0.002 n=6)    652.15m ± 26%  +4897.32% (p=0.002 n=6)    37.25m ± 28%  +185.44% (p=0.002 n=6)
EncodeUtf16/Big5/web-256                77.15m ± 27%    599.90m ± 12%   +677.58% (p=0.002 n=6)    738.15m ±  6%   +856.77% (p=0.002 n=6)    798.35m ±  8%   +934.80% (p=0.002 n=6)   2887.75m ± 28%  +3643.03% (p=0.002 n=6)   2865.05m ± 16%  +3613.61% (p=0.002 n=6)   227.75m ± 15%  +195.20% (p=0.002 n=6)
EncodeUtf16/Big5/csv-4096               16.20m ±  6%     75.10m ±  3%   +363.58% (p=0.002 n=6)     64.80m ±  2%   +300.00% (p=0.002 n=6)    229.35m ±  8%  +1315.74% (p=0.002 n=6)    853.40m ±  3%  +5167.90% (p=0.002 n=6)    833.15m ± 11%  +5042.90% (p=0.002 n=6)    42.75m ± 16%  +163.89% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-4096              13.97 ±  3%      33.91 ±  7%   +142.69% (p=0.002 n=6)      29.44 ± 17%   +110.70% (p=0.002 n=6)      31.00 ± 41%   +121.90% (p=0.002 n=6)      35.42 ±  5%   +153.53% (p=0.002 n=6)      35.22 ±  5%   +152.10% (p=0.002 n=6)     34.18 ± 17%  +144.65% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-4096           5.300m ±  6%   104.650m ±  1%  +1874.53% (p=0.002 n=6)   102.250m ±  1%  +1829.25% (p=0.002 n=6)   299.400m ±  1%  +5549.06% (p=0.002 n=6)   459.650m ±  3%  +8572.64% (p=0.002 n=6)   454.000m ±  3%  +8466.04% (p=0.002 n=6)   16.200m ±  4%  +205.66% (p=0.002 n=6)
EncodeUtf16/Big5/mail-4096              24.80m ±  4%    155.85m ±  2%   +528.43% (p=0.002 n=6)    124.60m ±  3%   +402.42% (p=0.002 n=6)    346.40m ±  0%  +1296.77% (p=0.002 n=6)   1338.05m ±  1%  +5295.36% (p=0.002 n=6)   1331.30m ±  6%  +5268.15% (p=0.002 n=6)    65.65m ±  4%  +164.72% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-4096             22.65m ± 11%    109.15m ±  3%   +381.90% (p=0.002 n=6)     99.10m ±  2%   +337.53% (p=0.002 n=6)    278.20m ±  6%  +1128.26% (p=0.002 n=6)    415.45m ±  7%  +1734.22% (p=0.002 n=6)    415.30m ±  1%  +1733.55% (p=0.002 n=6)    56.60m ± 18%  +149.89% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-4096          11.15m ±  7%     48.70m ±  2%   +336.77% (p=0.002 n=6)     41.75m ±  5%   +274.44% (p=0.002 n=6)    154.70m ±  3%  +1287.44% (p=0.002 n=6)    644.50m ±  3%  +5680.27% (p=0.002 n=6)    663.60m ±  4%  +5851.57% (p=0.002 n=6)    28.05m ±  8%  +151.57% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-4096         20.10m ±  6%    102.80m ±  3%   +411.44% (p=0.002 n=6)     87.45m ±  5%   +335.07% (p=0.002 n=6)    269.75m ±  4%  +1242.04% (p=0.002 n=6)   1036.85m ± 14%  +5058.46% (p=0.002 n=6)   1019.05m ±  4%  +4969.90% (p=0.002 n=6)    51.55m ±  2%  +156.47% (p=0.002 n=6)
EncodeUtf16/Big5/web-4096               16.15m ±  2%     77.40m ±  3%   +379.26% (p=0.002 n=6)     66.10m ±  2%   +309.29% (p=0.002 n=6)    219.05m ±  1%  +1256.35% (p=0.002 n=6)    847.15m ± 18%  +5145.51% (p=0.002 n=6)    866.60m ± 25%  +5265.94% (p=0.002 n=6)    41.20m ±  9%  +155.11% (p=0.002 n=6)
EncodeUtf16/Big5/csv-65536              15.30m ± 16%     55.70m ±  6%   +264.05% (p=0.002 n=6)     53.15m ±  9%   +247.39% (p=0.002 n=6)    225.75m ±  5%  +1375.49% (p=0.002 n=6)    837.10m ±  3%  +5371.24% (p=0.002 n=6)    823.05m ±  4%  +5279.41% (p=0.002 n=6)    39.85m ±  8%  +160.46% (p=0.002 n=6)
EncodeUtf16/Big5/subtitles-65536        18.30m ±  5%     62.45m ±  7%   +241.26% (p=0.002 n=6)     58.95m ±  4%   +222.13% (p=0.002 n=6)    262.75m ±  4%  +1335.79% (p=0.002 n=6)    994.95m ± 15%  +5336.89% (p=0.002 n=6)   1007.05m ±  3%  +5403.01% (p=0.002 n=6)    47.80m ±  6%  +161.20% (p=0.002 n=6)
EncodeUtf16/Big5/web-65536              13.25m ±  3%     45.60m ±  1%   +244.15% (p=0.002 n=6)     42.15m ±  4%   +218.11% (p=0.002 n=6)    188.45m ±  2%  +1322.26% (p=0.002 n=6)    736.05m ± 12%  +5455.09% (p=0.002 n=6)    735.95m ± 25%  +5454.34% (p=0.002 n=6)    34.00m ± 13%  +156.60% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-65536             14.13 ±  5%      36.54 ±  1%   +158.51% (p=0.002 n=6)      33.81 ±  4%   +139.21% (p=0.002 n=6)      32.74 ± 18%   +131.62% (p=0.002 n=6)      36.37 ±  8%   +157.28% (p=0.002 n=6)      36.67 ±  0%   +159.44% (p=0.002 n=6)     35.04 ±  8%  +147.86% (p=0.002 n=6)
EncodeUtf16/Big5/invalid-65536          5.250m ±  3%    67.650m ± 14%  +1188.57% (p=0.002 n=6)    65.250m ± 13%  +1142.86% (p=0.002 n=6)   160.450m ±  4%  +2956.19% (p=0.002 n=6)   217.900m ±  3%  +4050.48% (p=0.002 n=6)   212.900m ±  4%  +3955.24% (p=0.002 n=6)   16.200m ± 14%  +208.57% (p=0.002 n=6)
EncodeUtf16/Big5/mail-65536             22.75m ±  3%     75.35m ±  7%   +231.21% (p=0.002 n=6)     72.35m ±  1%   +218.02% (p=0.002 n=6)    323.25m ±  3%  +1320.88% (p=0.002 n=6)   1164.00m ±  4%  +5016.48% (p=0.002 n=6)   1181.95m ± 10%  +5095.38% (p=0.002 n=6)    57.70m ±  2%  +153.63% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-65536            21.50m ±  2%     67.75m ± 12%   +215.12% (p=0.002 n=6)     64.85m ± 15%   +201.63% (p=0.002 n=6)    272.85m ±  6%  +1169.07% (p=0.002 n=6)    409.65m ± 11%  +1805.35% (p=0.002 n=6)    410.40m ±  6%  +1808.84% (p=0.002 n=6)    52.00m ±  2%  +141.86% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-65536         10.55m ± 19%     37.00m ±  7%   +250.71% (p=0.002 n=6)     34.35m ±  8%   +225.59% (p=0.002 n=6)    154.50m ± 11%  +1364.45% (p=0.002 n=6)    635.25m ±  7%  +5921.33% (p=0.002 n=6)    643.15m ± 15%  +5996.21% (p=0.002 n=6)    27.45m ± 22%  +160.19% (p=0.002 n=6)
EncodeUtf16/Big5/ascii-1048576           13.35 ± 22%      19.57 ±  6%    +46.59% (p=0.002 n=6)      19.85 ± 14%    +48.68% (p=0.002 n=6)      19.67 ±  7%    +47.39% (p=0.002 n=6)      20.05 ± 19%    +50.20% (p=0.002 n=6)      19.95 ± 12%    +49.44% (p=0.002 n=6)     20.05 ±  3%   +50.18% (p=0.002 n=6)
EncodeUtf16/Big5/mixed-1048576          21.50m ± 14%     67.65m ±  7%   +214.65% (p=0.002 n=6)     64.20m ±  4%   +198.60% (p=0.002 n=6)    268.15m ±  8%  +1147.21% (p=0.002 n=6)    409.30m ±  7%  +1803.72% (p=0.002 n=6)    404.50m ±  7%  +1781.40% (p=0.002 n=6)    52.75m ± 12%  +145.35% (p=0.002 n=6)
EncodeUtf16/Big5/nonascii-1048576       10.15m ±  7%     37.15m ± 17%   +266.01% (p=0.002 n=6)     34.25m ± 16%   +237.44% (p=0.002 n=6)    153.25m ±  1%  +1409.85% (p=0.002 n=6)    643.20m ± 18%  +6236.95% (p=0.002 n=6)    631.65m ± 40%  +6123.15% (p=0.002 n=6)    27.35m ± 16%  +169.46% (p=0.002 n=6)
EncodeUtf16/Big5/web-1048576            13.05m ± 11%     45.25m ±  9%   +246.74% (p=0.002 n=6)     41.45m ±  3%   +217.62% (p=0.002 n=6)    186.30m ±  5%  +1327.59% (p=0.002 n=6)    699.45m ± 16%  +5259.77% (p=0.002 n=6)    708.20m ± 10%  +5326.82% (p=0.002 n=6)    33.40m ± 21%  +155.94% (p=0.002 n=6)
geomean                                 236.5m           569.0m         +140.61%                   373.7m          +58.05%                   747.8m         +216.25%                    1.022         +332.31%                   943.1m         +298.81%                  320.1m         +35.36%
```
