# Japanese table layouts and encoder lookups, 2026-11-02

Plan decisions 1 (table layout) and 2 (encoder lookup), measured on the
Japanese indexes (jis0208, jis0212, iso-2022-jp-katakana) through the
Shift_JIS, EUC-JP, and ISO-2022-JP codecs, against encoding_rs 0.8.44.

Headline: `japanese_paged` (decode: 32/64/128-entry pages behind a page
index with empty pages shared; encode: a 64-code-point bitmap per block with
a popcount rank into a packed value array). jis0208 decode+encode is 36,785
B against flat's 51,512 B (−29%); its lookups cost 0.95 ns to decode and
1.38 ns to encode against fixed flat's 0.74–0.80 ns and bisection's 41 ns. At codec
level it is 3.92× encoding_rs geomean over 144 rows (1.54× and 1.70× on
decode to UTF-8 and UTF-16, 8.7× and 10.5× on encode), and the committed tables add 50,005 B of `.rodata` against encoding_rs's 26,262 B
of Japanese tables (default features, whose kanji encode is a linear scan).

## Method

Intel(R) Xeon(R) Processor @ 2.60GHz (4 vCPUs, AVX-512), in an orb. Zig
0.16 ReleaseFast for the host CPU, encoding_rs 0.8.44 with default features.

- **Sizes** come from the generated tables: each layout's
  `gen/layouts/*.zig` run on each index (`zig build gen -- layout`),
  summing the arrays it emits. Decode arrays and encode arrays
  are counted apart. `test-layouts` checks every layout against every index.
- **Lookup microbenchmark** (scratch, not committed): each layout's
  `decode(pointer)` and `encode(cp)` called in a `noinline` loop, pinned
  with `taskset -c 3`, best of 60 timings. "text" streams are the 524,288
  pointers (and their code points) of the two-byte characters of
  `bench/corpus-gen/Shift_JIS/nonascii-1048576.bin`, in order; "all"
  streams are the 7,724 entries of jis0208 shuffled; "miss" encodes 65,536
  random BMP code points, which mostly miss. jis0212 is decode only (the
  standard never encodes it).
- **Codec A/B**: the bench binary built once per layout (the layout swapped
  in `gen/sources.zig`, everything else identical), all arms run by
  `bench-compare` as pinned servers timed back to back in rotating order
  (command below). `zig` is `japanese_paged`; `zflat` is the flat layout as committed on
  main; `zflatfix` is flat with the early-return fix below.

## Layouts tried

| layout            | decode                                                                          | encode                                                           |
| ----------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `flat` (main)     | one `[pointer]u16` array                                                        | code points sorted with their pointers, bisection                |
| `japanese_rows`   | rows of 64 or 128 trimmed to their used span, row index                         | 64-cp blocks: bitmap + popcount rank into a packed pointer array |
| `japanese_paged`  | 32/64/128 pages (size chosen per index) behind a page index; empty pages shared | as rows                                                          |
| `japanese_ranged` | runs of consecutive code points, bisected                                       | runs of consecutive pointers, bisected                           |
| `japanese_hash`   | as rows                                                                         | seeded hash-and-displace perfect hash, verified by decoding      |

## Sizes (bytes, decode + encode)

| index                | flat               | rows               | paged              | ranged             | hash               |
| -------------------- | ------------------ | ------------------ | ------------------ | ------------------ | ------------------ |
| jis0208              | 22208+29304=51512  | 16220+20310=36530  | 16475+20310=36785  | 15586+32408=47994  | 16220+18316=34536  |
| jis0212 (decode)     | 14422              | 12722              | 13026              | 12228              | 12722              |
| iso-2022-jp-katakana | 126+252=378        | 130+362=492        | 194+362=556        | 132+212=344        | 130+158=288        |
| gb18030              | 47880+95756=143636 | 48632+54316=102948 | 48572+54316=102888 | 47886+48926=96812  | 48632+59848=108480 |
| big5                 | 79128+87918=167046 | 75972+41492=117464 | 76443+41492=117935 | 74624+45460=120084 | 75972+36634=112606 |
| euc_kr               | 47500+68192=115692 | 37316+41594=78910  | 41166+41594=82760  | 35350+49584=84934  | 37316+42620=79936  |

What ships for Japanese (jis0208 both ways, jis0212 and the katakana index
decode only) is 66,060 B flat, 50,005 B paged, 49,382 B rows, 60,354 B
ranged, and 47,388 B hash. Rank encode is the big win: the flat encode table stores a
u32 code point and a u16 pointer per entry, the bitmap stores a bit per code
point in a block and a u16 per entry. On the Chinese and Korean indexes the
same holds (paged and rows −28% to −32% against flat); ranged is smallest
on gb18030, whose four-byte ranges are long runs.

## Lookup cost (ns per lookup)

| layout              | decode text | decode all | encode text | encode all | encode miss | jis0212 decode |
| ------------------- | ----------- | ---------- | ----------- | ---------- | ----------- | -------------- |
| flat (main)         | 6.25        | 6.14       | 41          | 61         | 38          | 6.1            |
| flat + early return | 0.80        | 0.74       | 41          | 61         | 38          | 0.61           |
| rows                | 1.32        | 1.32       | 1.38        | 1.38       | 1.97        | 1.33           |
| paged               | 0.95        | 0.95       | 1.38        | 1.38       | 1.71        | 0.95           |
| ranged              | 8.4         | 11.3       | 27          | 55         | 34          | 4.5            |
| hash                | 1.32        | 1.32       | 5.96        | 5.83       | 7.68        | 1.33           |

flat's decode on main is `const v = decode_table[p]; return if (v == 0)
null else v;` behind a bounds check; Zig 0.16 compiles the optional return
through memory and the caller's reload stalls on store forwarding, 6 ns a
lookup. Returning early (`if (v == 0) return null; return v;`) brings it to
0.74–0.80 ns. The same stall hit a `u21` field in a struct returned by value (the
codec's scalar reader): widening it to `u32` doubled UTF-8 encode. Both are
requests for shared files (`gen/layouts/flat.zig`, `codec.Scalar`).

## Codec A/B

Geomean GB/s over the 36 rows of each direction (Shift_JIS, EUC-JP, and
ISO-2022-JP; web, nonascii, and mixed text; 16 B, 256 B, 64 KiB, 1 MiB),
medians of 10 rounds, and the ratio to `japanese_paged`:

|                     | rust  | flat (main) | flat fixed | rows  | **paged** | ranged | hash  |
| ------------------- | ----- | ----------- | ---------- | ----- | --------- | ------ | ----- |
| decode to UTF-8     | 0.362 | 0.308       | 0.632      | 0.517 | **0.555** | 0.274  | 0.511 |
| decode to UTF-16    | 0.427 | 0.361       | 0.825      | 0.677 | **0.723** | 0.314  | 0.682 |
| encode from UTF-8   | 0.053 | 0.136       | 0.136      | 0.463 | **0.460** | 0.163  | 0.281 |
| encode from UTF-16  | 0.049 | 0.131       | 0.134      | 0.508 | **0.516** | 0.163  | 0.290 |
| all, ratio to paged | 0.25  | 0.38        | 0.56       | 0.96  | **1.00**  | 0.39   | 0.74  |

Fixed flat decodes 14% faster than paged (geomean): paged runs at 0.71–0.80
of flat on EUC-JP and ISO-2022-JP non-ASCII text from 256 B up, and even
(0.96–1.03) on 16-byte web rows and on Shift_JIS mixed text to UTF-16. The
page index is a second dependent load. Rows is
6% slower than paged on decode. On encode, the rank table is 3.4× flat's
bisection and 1.7× the hash; rows and paged share it and tie.

A layout this run did not build but whose parts it did measure, flat
decode with the rank encode, would decode at flat's speed and encode at
paged's, for 57,066 B of Japanese tables (+7,061 B, +14% over paged).

## Recommendation

Decision 1: `japanese_paged` for the Japanese indexes. Decode is within
14% of the fixed flat layout at codec level and faster than rows
(its page index is one load instead of a row start and a length check),
and jis0208 is 29% smaller than flat. Ranged is smaller still on decode but
bisection costs 8–11 ns a lookup, and it decodes at half paged's speed.

Flat decode with the rank encode is the other point on the frontier: 14%
faster decode for 14% more table bytes. Paged wins on the bar: decode is
already 1.5–1.7× encoding_rs, while our tables are the one axis where we
trail it (below), so the bytes are worth more than the decode speed.

Decision 2: the bitmap-and-rank reverse table that rows and paged share. It
is 1.4 ns a lookup against 41–61 ns for bisection over the flat encode table
and 6 ns for the perfect hash (whose verify-by-decode doubles the loads), and
it is 31% smaller than flat's encode table; the hash is 10% smaller still
on jis0208 but 4× slower. encoding_rs's default kanji encode is a linear
scan, which is where the 8.7–10.5× encode gap comes from.

On size against encoding_rs: we ship 50,005 B of Japanese `.rodata` to its
26,262 B. Most of the difference is that encoding_rs's default build has no
reverse kanji table at all; its `fast-kanji-encode` feature adds 41,794 B
(68,056 B total) and `less-slow-kanji-encode` 11,860 B. Matching 26 KB
would mean giving up indexed encode.

For the Chinese and Korean indexes, paged and rows are within 4% of each
other and 28–32% under flat; ranged is 6% smaller on gb18030 and hash 5%
smaller on big5. The Chinese orb's speed numbers decide those.

## Raw output

```
BENCHTIME_MS=20 just arms="rust zig zflat zflatfix zrows zranged zhash" \
  bench-compare 10 '(Shift_JIS|EUC-JP|ISO-2022-JP)/(web|nonascii|mixed)-(16|256|65536|1048576)$'
```

`armsum` over `zig-out/bench-compare/*.txt` (arms as above; `zig` is paged):

```
op                rust     zflat  zflatfix     zrows       zig   zranged     zhash
DecodeUtf8       0.362     0.308     0.632     0.517     0.555     0.274     0.511  (36 rows, geomean GB/s)
DecodeUtf16      0.427     0.361     0.825     0.677     0.723     0.314     0.682  (36 rows, geomean GB/s)
EncodeUtf8       0.053     0.136     0.136     0.463     0.460     0.163     0.281  (36 rows, geomean GB/s)
EncodeUtf16      0.049     0.131     0.134     0.508     0.516     0.163     0.290  (36 rows, geomean GB/s)
all              0.142     0.211     0.312     0.536     0.556     0.219     0.410  (144 rows, geomean GB/s)
ratio to zig
DecodeUtf8        0.65      0.56      1.14      0.93      1.00      0.49      0.92
DecodeUtf16       0.59      0.50      1.14      0.94      1.00      0.43      0.94
EncodeUtf8        0.12      0.29      0.29      1.01      1.00      0.35      0.61
EncodeUtf16       0.10      0.25      0.26      0.98      1.00      0.32      0.56
all               0.25      0.38      0.56      0.96      1.00      0.39      0.74
ratio to rust
DecodeUtf8        1.00      0.85      1.75      1.43      1.54      0.76      1.41
DecodeUtf16       1.00      0.85      1.93      1.59      1.70      0.74      1.60
EncodeUtf8        1.00      2.56      2.55      8.72      8.67      3.08      5.29
EncodeUtf16       1.00      2.67      2.72     10.33     10.49      3.31      5.89
all               1.00      1.49      2.20      3.78      3.92      1.54      2.90
```

`bench-compare` summary, paged against encoding_rs. In the summary, the arm columns are our speed over that arm's, and `<1` counts the rows where we are slower.

```
zig/arm, geomean              rows  zig GB/s     rust     ±   <1    ~   slowest vs rust
DecodeUtf8/EUC-JP               12      0.64     1.73    4%    1    0   0.79 [0.77, 0.88] web-16
DecodeUtf16/EUC-JP              12      0.84     1.55    2%    1    2   0.81 [0.80, 0.84] web-16
EncodeUtf8/EUC-JP               12      0.60    10.05    3%    0    1   0.99 [0.98, 1.07] web-16
EncodeUtf16/EUC-JP              12      0.66    12.14    2%    0    0   1.07 [1.05, 1.11] web-16
DecodeUtf8/ISO-2022-JP          12      0.55     1.63    1%    0    1   1.01 [0.99, 1.05] mixed-16
DecodeUtf16/ISO-2022-JP         12      0.71     1.93    2%    1    0   0.96 [0.87, 0.98] web-16
EncodeUtf8/ISO-2022-JP          12      0.35     8.13    1%    0    0   1.14 [1.11, 1.15] web-16
EncodeUtf16/ISO-2022-JP         12      0.41    10.21    3%    0    0   1.20 [1.20, 1.23] web-16
DecodeUtf8/Shift_JIS            12      0.49     1.27    3%    4    0   0.73 [0.72, 0.79] web-256
DecodeUtf16/Shift_JIS           12      0.63     1.62    3%    1    2   0.77 [0.74, 0.83] web-16
EncodeUtf8/Shift_JIS            12      0.47     7.96    2%    1    0   0.98 [0.96, 0.98] web-16
EncodeUtf16/Shift_JIS           12      0.51     9.29    2%    0    1   1.05 [0.94, 1.06] web-16
all                            144      0.56     3.92          9    7

ns/call, median      bytes       zig      rust  zig/rust
DecodeUtf8              16      37.1      39.2      1.03
DecodeUtf8             256     410.6     543.6      1.39
DecodeUtf16             16      31.6      35.4      1.01
DecodeUtf16            256     328.2     471.4      1.41
EncodeUtf8              16      43.9     630.1     11.47
EncodeUtf8             256     716.6    6854.0      8.75
EncodeUtf16             16      35.1     609.7     14.18
EncodeUtf16            256     504.0    6803.1     10.59
```

Lookup microbenchmark (`taskset -c 3`, best of 60, ns per lookup), and the size script's output:

```
ns per lookup, best of 60; 524288 text pointers, 7724 index entries
layout                   dec text    dec all   enc text    enc all   enc miss    212 dec
flat (as committed)          6.25       6.14      41.19      60.96      38.48       6.14
flat + early return          0.80       0.74      41.43      61.35      38.27       0.61
japanese_rows                1.32       1.32       1.38       1.38       1.97       1.33
japanese_paged               0.95       0.95       1.38       1.38       1.71       0.95
japanese_ranged              8.39      11.27      27.08      55.15      34.04       4.50
japanese_hash                1.32       1.32       5.96       5.83       7.68       1.33
```

```
index                                        flat             japanese_rows            japanese_paged           japanese_ranged             japanese_hash
jis0208                         22208+29304=51512         16220+20310=36530         16475+20310=36785         15586+32408=47994         16220+18316=34536
jis0208_shift_jis               22208+29304=51512         16220+20310=36530         16475+20310=36785         15586+32408=47994         16220+18316=34536
jis0212                             14422+0=14422             12722+0=12722             13026+0=13026             12228+0=12228             12722+0=12722
iso_2022_jp_katakana                  126+252=378               130+362=492               194+362=556               132+212=344               130+158=288
gb18030                        47880+95756=143636        48632+54316=102948        48572+54316=102888         47886+48926=96812        48632+59848=108480
big5                           79128+87918=167046        75972+41492=117464        76443+41492=117935        74624+45460=120084        75972+36634=112606
euc_kr                         47500+68192=115692         37316+41594=78910         41166+41594=82760         35350+49584=84934         37316+42620=79936
```
