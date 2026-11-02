# CJK fast paths: the decode writers, ASCII inside Japanese text, ISO-2022-JP's errors, and the decodeAs hooks, 2026-11-02

Wave 2, CJK. Intel(R) Xeon(R) Processor @ 2.60GHz (Ice Lake-SP, 4 vCPUs
on two cores, AVX-512), in an orb. Zig 0.16 ReleaseFast for the host
CPU; encoding_rs 0.8.44. Every A/B below is `just arms=... bench-compare
10 FILTER` with `BENCHTIME_MS=20`: each arm is a `bench-<arm> serve`
process pinned to core 3 (`taskset -c 3`, whose sibling core 2 ran
nothing), every arm times each row back to back in an order that rotates
from row to row and round to round, 10 rounds after a sizing round, then
benchstat. `main` is the bench arm built at `2130053` (origin/main);
the other arms are this branch's commits or a worktree with one change,
named below. Every arm's output matched encoding_rs on all 7,040 rows it
checked. GB/s and MB/s count input bytes. The table layouts are in
cjk-tables-20261102.md.

Headlines, against `main`, geomean over each operation's 44 rows:

1. Big5 decode writes its code points without `codec.tryPut`'s
   optional: 1.10x to UTF-8 and 1.09x to UTF-16, now 1.44x and 1.32x
   encoding_rs. GBK and gb18030 the same way: 1.15x and 1.16x to UTF-8,
   level to UTF-16.
2. Shift_JIS and EUC-JP copy an ASCII run that ends inside a block with
   one block, and a lone ASCII byte between Japanese characters with
   none: 1.07x to 1.08x on both outputs, 1.2x to 1.9x on the `csv-64`
   and `mixed` rows.
3. ISO-2022-JP replaces a byte that is an error in the ASCII state inside
   its ASCII loop: invalid input decodes 2.9x to 4.5x as fast up to 4 KiB,
   from 0.5x encoding_rs to 1.8x to 2.9x.
4. `decodeAs` and `encodeAs` in japanese.zig: `DecoderFor(&.{.shift_jis})`
   adds 16,530 bytes of `.rodata` instead of 29,650 (ReleaseSmall).
5. The full CJK run, `2130053` against this branch: 3.77x to 3.81x
   encoding_rs over 1,232 rows, and 50 rows below encoding_rs to 18.

## 1. Big5, GBK, and gb18030: a writer without an optional

`big5: write decoded code points without an optional` and
`gb18030: write decoded code points without an optional`. The two-byte
path wrote each code point with `codec.tryPut`, whose `?usize`, inlined
into the loop, goes through a stack slot on every character, the store
the Korean orb removed from euc_kr.zig (korean-20261102.md). Each family
now has a `putIndex` like euc_kr.zig's: index gb18030's code points are
U+00A4 to U+FFE5, so one UTF-16 unit or two or three UTF-8 bytes; index
Big5's are BMP or plane 2, so Big5's checks for four bytes first. A
`codec.putBmp` shared by the three would remove the copies (requested in
the report; codec.zig is the single-byte orb's).

Arms: `main`, and `zig` at `823accc` (these two commits and the
Japanese ones, which no Chinese row runs), `just arms="rust zig main
runs rows" bench-compare 10` over every CJK row:

| op                  | rows | main GB/s | zig GB/s | zig/main | rust GB/s | zig/rust |
| ------------------- | ---: | --------: | -------: | -------: | --------: | -------: |
| Big5/DecodeUtf8     |   44 |     1.138 |    1.252 |     1.10 |     0.871 |     1.44 |
| Big5/DecodeUtf16    |   44 |     1.237 |    1.348 |     1.09 |     1.025 |     1.32 |
| GBK/DecodeUtf8      |   44 |     1.192 |    1.371 |     1.15 |     0.766 |     1.79 |
| GBK/DecodeUtf16     |   44 |     1.438 |    1.416 |     0.98 |     0.863 |     1.64 |
| gb18030/DecodeUtf8  |   44 |     1.196 |    1.385 |     1.16 |     0.761 |     1.82 |
| gb18030/DecodeUtf16 |   44 |     1.447 |    1.416 |     0.98 |     0.863 |     1.64 |

benchstat over the 352 Chinese decode rows: +7.44% geomean. To UTF-16
the writer was already one store, so only UTF-8 gains on gb18030; Big5
gains on both, because its old path also checked for four-unit
characters through `codec.unitsOf`. Chinese text, MB/s:

| row                              | main | zig | rust | zig/main | zig/rust |
| -------------------------------- | ---: | --: | ---: | -------: | -------: |
| DecodeUtf8/Big5/nonascii-256     |  569 | 706 |  640 |     1.24 |     1.10 |
| DecodeUtf8/Big5/nonascii-4096    |  638 | 749 |  509 |     1.17 |     1.47 |
| DecodeUtf8/Big5/web-4096         |  645 | 765 |  678 |     1.19 |     1.13 |
| DecodeUtf16/Big5/nonascii-4096   |  811 | 914 |  861 |     1.13 |     1.06 |
| DecodeUtf16/Big5/web-4096        |  822 | 956 | 1007 |     1.16 |     0.95 |
| DecodeUtf8/gb18030/nonascii-256  |  664 | 847 |  423 |     1.28 |     2.00 |
| DecodeUtf8/gb18030/nonascii-4096 |  696 | 898 |  425 |     1.29 |     2.11 |
| DecodeUtf8/gb18030/web-4096      |  714 | 897 |  484 |     1.25 |     1.85 |

Per call at 16 bytes, geomean ns over the shapes:

| op                  | main ns | zig ns | rust ns |
| ------------------- | ------: | -----: | ------: |
| DecodeUtf8/Big5     |    13.6 |   13.3 |    18.1 |
| DecodeUtf16/Big5    |    13.7 |   13.2 |    18.0 |
| DecodeUtf8/GBK      |    13.5 |   12.0 |    18.2 |
| DecodeUtf16/GBK     |    13.2 |   13.3 |    17.6 |
| DecodeUtf8/gb18030  |    13.1 |   11.4 |    18.1 |
| DecodeUtf16/gb18030 |    12.4 |   12.9 |    17.3 |

## 2. Shift_JIS and EUC-JP: ASCII inside Japanese text

`japanese: copy ASCII a block at a time inside Shift_JIS and EUC-JP
text`. The shared fast loop (`decodeSteps`) tested 16 bytes for a byte
above 0x7F at each ASCII byte and, when the block had one, wrote one
byte and tested again at the next: a run of k ASCII bytes before a
Japanese character cost k vector tests. Three arms, each a worktree of
`823accc` with one change to that loop:

- `j0`: the old ASCII loop, with `putBmp` writing the jis0208 code points
  (U+00A7 to U+FFE5: no one-byte or four-byte case, no room check, since
  the loop has checked room for the run).
- `jb`: `codec.asciiRun` (copy a block, return the count up to the first
  non-ASCII byte) for every ASCII byte, and `codec.put` as before.
- `ja`: `jb` with `putBmp`, and a lone ASCII byte (the next byte is not
  ASCII: a space, digit, or newline between Japanese characters) written
  alone, without a block. This is the commit.

`zig` is `823accc` itself, which had `asciiRun` for every ASCII byte and
`putBmp`, without the lone-byte case: copying a whole block for one byte
made the `mixed` rows (one ASCII character, one Japanese, repeated)
2-3x slower than `main`, and pure Japanese text 10-20% slower on EUC-JP.
`just arms="rust zig j0 ja jb runs rb rc" bench-compare 10 '^Decode[^/]*/(Shift_JIS|EUC-JP)/' ...`,
ratios to `zig`:

| op                    | rows | zig GB/s |   j0 |   ja |   jb | rust |
| --------------------- | ---: | -------: | ---: | ---: | ---: | ---: |
| EUC-JP/DecodeUtf8     |   44 |    1.281 | 1.03 | 1.13 | 1.10 | 0.65 |
| EUC-JP/DecodeUtf16    |   44 |    1.505 | 1.09 | 1.16 | 1.16 | 0.65 |
| Shift_JIS/DecodeUtf8  |   44 |    1.099 | 1.02 | 1.11 | 1.07 | 0.75 |
| Shift_JIS/DecodeUtf16 |   44 |    1.230 | 1.05 | 1.12 | 1.12 | 0.65 |

Then `ja` against `main` directly (`nx` is `ja` with the tables of
cjk-tables-20261102.md, which no decode row reads differently;
`just arms="rust zig main nx" bench-compare 10 ...`):

| op                    | rows | main GB/s | nx GB/s | nx/main | rust GB/s | nx/rust |
| --------------------- | ---: | --------: | ------: | ------: | --------: | ------: |
| EUC-JP/DecodeUtf8     |   44 |     1.376 |   1.479 |    1.07 |     0.827 |    1.79 |
| EUC-JP/DecodeUtf16    |   44 |     1.687 |   1.801 |    1.07 |     0.973 |    1.85 |
| Shift_JIS/DecodeUtf8  |   44 |     1.135 |   1.227 |    1.08 |     0.830 |    1.48 |
| Shift_JIS/DecodeUtf16 |   44 |     1.272 |   1.360 |    1.07 |     0.809 |    1.68 |

benchstat over the 176 rows: +7.31% geomean. Japanese text up to 4 KiB,
MB/s:

| row                                | main |   nx | rust | nx/main | nx/rust |
| ---------------------------------- | ---: | ---: | ---: | ------: | ------: |
| DecodeUtf8/Shift_JIS/csv-64        | 1312 | 1711 | 1436 |    1.30 |    1.19 |
| DecodeUtf8/Shift_JIS/csv-256       |  767 |  805 |  831 |    1.05 |    0.97 |
| DecodeUtf8/Shift_JIS/csv-4096      |  649 |  730 |  703 |    1.12 |    1.04 |
| DecodeUtf8/Shift_JIS/mail-256      | 1367 | 1386 | 1506 |    1.01 |    0.92 |
| DecodeUtf8/Shift_JIS/mail-4096     |  793 |  795 |  834 |    1.00 |    0.95 |
| DecodeUtf8/Shift_JIS/nonascii-64   |  535 |  551 |  614 |    1.03 |    0.90 |
| DecodeUtf8/Shift_JIS/subtitles-64  |  892 |  971 | 1107 |    1.09 |    0.88 |
| DecodeUtf8/Shift_JIS/subtitles-256 |  776 |  939 |  777 |    1.21 |    1.21 |
| DecodeUtf8/Shift_JIS/web-256       | 1569 | 1575 | 1677 |    1.00 |    0.94 |
| DecodeUtf8/Shift_JIS/web-4096      |  653 |  697 |  718 |    1.07 |    0.97 |
| DecodeUtf8/Shift_JIS/mixed-4096    |  734 |  895 |  382 |    1.22 |    2.34 |
| DecodeUtf16/EUC-JP/csv-64          | 1569 | 2597 | 1605 |    1.65 |    1.62 |
| DecodeUtf16/EUC-JP/subtitles-256   | 1490 | 1930 | 1097 |    1.30 |    1.76 |
| DecodeUtf16/EUC-JP/mixed-4096      | 1309 | 1564 |  463 |    1.19 |    3.38 |

Shift_JIS to UTF-8 on real text was 0.66x to 0.95x encoding_rs up to 4
KiB; it is now 0.88x to 1.21x, and the rows still below (`mail-256` and
`-4096`, `nonascii-64`, `subtitles-64`, `web-256` and `-4096`, 0.88x to
0.97x) are kana-heavy: encoding_rs maps hiragana and katakana by
arithmetic, without a table, and this package reads a page number and a
cell for every character (index jis0208 is `japanese_paged`). The same
rows at 64 KiB, where kanji dominate, are 1.5x to 2x encoding_rs. A
kana path in `sjisPair` is the next thing to measure: it costs every
kanji a compare, and text alternates the two.

Per call at 16 bytes, geomean ns over the shapes (no change):

| op                    | main ns | nx ns | rust ns |
| --------------------- | ------: | ----: | ------: |
| DecodeUtf8/EUC-JP     |    13.0 |  13.3 |    18.5 |
| DecodeUtf16/EUC-JP    |    12.9 |  13.2 |    17.3 |
| DecodeUtf8/Shift_JIS  |    14.2 |  14.3 |    19.1 |
| DecodeUtf16/Shift_JIS |    14.2 |  14.3 |    18.6 |

## 3. ISO-2022-JP: errors in the ASCII loop

`japanese: replace ISO-2022-JP's errors in the ASCII loop`. In the ASCII
state the fast loop stopped at the first byte above 0x7F (or 0x0E, 0x0F),
and the standard's one-byte step (`isoStep`, which returns a struct with
a `u21` through memory) wrote the U+FFFD. On random bytes that is every
other byte. In replacement mode the loop now does what the step does for
such a byte, U+FFFD and "output" unset, and goes on; fatal mode, escapes,
and the other states still take the step. Arms as in section 1:

| row                                   | main | zig | rust | zig/main | zig/rust |
| ------------------------------------- | ---: | --: | ---: | -------: | -------: |
| DecodeUtf8/ISO-2022-JP/invalid-16     |   75 | 240 |  132 |     3.19 |     1.82 |
| DecodeUtf8/ISO-2022-JP/invalid-64     |  114 | 383 |  209 |     3.36 |     1.83 |
| DecodeUtf8/ISO-2022-JP/invalid-256    |  111 | 390 |  209 |     3.50 |     1.87 |
| DecodeUtf8/ISO-2022-JP/invalid-4096   |  106 | 307 |  145 |     2.90 |     2.12 |
| DecodeUtf8/ISO-2022-JP/invalid-65536  |   86 | 139 |  113 |     1.61 |     1.22 |
| DecodeUtf16/ISO-2022-JP/invalid-16    |   83 | 373 |  155 |     4.49 |     2.41 |
| DecodeUtf16/ISO-2022-JP/invalid-64    |  125 | 502 |  218 |     4.01 |     2.30 |
| DecodeUtf16/ISO-2022-JP/invalid-256   |  128 | 471 |  223 |     3.66 |     2.11 |
| DecodeUtf16/ISO-2022-JP/invalid-4096  |  116 | 452 |  156 |     3.89 |     2.89 |
| DecodeUtf16/ISO-2022-JP/invalid-65536 |   94 | 160 |  137 |     1.70 |     1.16 |

benchstat over the 10 rows: +207.99% geomean. ISO-2022-JP decode
overall: 1.06x (UTF-8) and 1.05x (UTF-16) geomean over 44 rows.

## 4. The decodeAs and encodeAs hooks

`japanese: add the decodeAs and encodeAs hooks`, the design orb's hunk
(`git show 2d44a56:docs/slop/comptime-shared.diff`) applied as it was:
`decode` and `encode` switch on the kind with `inline else` into
`decodeAs` and `encodeAs`, which take the encoding at compile time, so
a `DecoderFor` over one Japanese encoding links only that encoding's
loop and tables. `bench/comptime/sizes.sh` at `2130053` and at the
commit, `.rodata` and `.text` added over `none`, bytes:

| program       | mode         | before +rodata | after +rodata | before +text | after +text |
| ------------- | ------------ | -------------: | ------------: | -----------: | ----------: |
| `ct_sjis`     | ReleaseSmall |         29,650 |        16,530 |        8,028 |       3,258 |
| `ct_sjis`     | ReleaseFast  |         29,666 |        16,570 |       11,776 |       5,792 |
| `ct_enc_sjis` | ReleaseSmall |         37,024 |        36,800 |        5,645 |       2,534 |
| `ct_enc_sjis` | ReleaseFast  |         37,056 |        36,800 |        9,936 |       5,264 |

The other programs did not change. `ct_sjis` keeps index jis0208's
decode table (16,475 bytes) and drops jis0212's (13,026) and EUC-JP's and
ISO-2022-JP's loops; `ct_enc_sjis` drops the other encoders' code.
Per call, on the 16-byte rows (`just arms="rust zig ctm ctmg cth cthg"
bench-compare 10` over the Japanese 16- and 256-byte rows): `ctm` and
`cth` are bench/comptime's `bench-comptime` (a `DecoderFor` or
`EncoderFor` over the row's one encoding) at `2130053` and at the hooks
commit, `ctmg` and `cthg` its `bench-generic` (the runtime `Decoder`) at
the same two commits, `zig` the runtime decoder at this branch's head.
Geomean ns per call over the eight 16-byte rows of each operation:

| op                      |  ctm |  cth | ctmg | cthg |  zig | rust |
| ----------------------- | ---: | ---: | ---: | ---: | ---: | ---: |
| DecodeUtf8/EUC-JP       | 16.1 | 14.9 | 13.9 | 13.9 | 13.1 | 18.6 |
| DecodeUtf16/EUC-JP      | 15.1 | 14.0 | 13.3 | 13.0 | 13.3 | 17.3 |
| EncodeUtf8/EUC-JP       | 12.4 | 13.2 | 14.9 | 15.1 | 14.7 | 39.1 |
| EncodeUtf16/EUC-JP      | 11.3 | 11.2 | 13.2 | 13.1 | 13.1 | 40.4 |
| DecodeUtf8/ISO-2022-JP  | 29.8 | 33.3 | 30.7 | 31.0 | 29.1 | 43.3 |
| DecodeUtf16/ISO-2022-JP | 30.1 | 30.0 | 28.7 | 31.3 | 27.5 | 37.1 |
| EncodeUtf8/ISO-2022-JP  | 26.9 | 28.2 | 28.7 | 28.5 | 29.0 | 75.1 |
| EncodeUtf16/ISO-2022-JP | 25.4 | 23.7 | 27.1 | 25.3 | 24.2 | 91.5 |
| DecodeUtf8/Shift_JIS    | 11.8 | 11.4 | 13.9 | 14.4 | 13.8 | 18.4 |
| DecodeUtf16/Shift_JIS   | 11.1 | 10.9 | 13.3 | 13.5 | 13.9 | 18.2 |
| EncodeUtf8/Shift_JIS    | 13.1 | 13.5 | 15.6 | 15.7 | 15.4 | 41.9 |
| EncodeUtf16/Shift_JIS   | 12.5 | 12.3 | 14.9 | 15.2 | 15.0 | 44.2 |

EUC-JP decode through a one-encoding `DecoderFor` was 2 ns slower per
call than the runtime decoder at `2130053`; the hooks take back 1.1 to
1.2 ns of it (benchstat `ctm` against `cth`: -9% to -14% on the
`ascii`, `csv`, `mail`, `subtitles`, and `web` rows, both outputs), and
leave it 0.7 to 1.0 ns behind. Shift_JIS through `DecoderFor` was
already ahead of the runtime decoder and stays so. The exception is
ISO-2022-JP decode to UTF-8 at 16 bytes, 3.5 ns slower with the hooks
(+9% to +24% per row, p ≤ 0.035) while its UTF-16 rows did not move and
its 256-byte rows are level (0.99x). That points at a fixed per-call
cost, likely code placement around the entry, but it is not proven:
not chased, since ISO-2022-JP's decoder changed again two commits
later. EUC-JP encode to UTF-8 moved 12.4 to 13.2 ns, +9% and +15% on
two rows and within noise on the rest. At 256 bytes the hooks are level
on every operation (geomean 1.00x), except Shift_JIS decode to UTF-8,
1.07x.

## 5. Before and after: the CJK rows

`just bench-compare 10 '/(Shift_JIS|EUC-JP|ISO-2022-JP|GBK|gb18030|Big5|EUC-KR)/'`,
the defaults (50 ms a sample, 10 rounds, every comparison arm), 1,232
rows: before at `2130053` (origin/main, 17:00 to 18:01), after at
`f1ee332`, this branch before its rebase onto `09e3109`, with the code
of `084f6f1` (18:20 to 19:24). The rebase moved the bench loop to testingx 0.4.0 and changed
no code, so the after run stayed on the old loop to compare like with
like. Each run is interleaved within itself, so the encoding_rs columns
are A/Bs; the before and after GB/s are two runs an hour apart. zig's
output matched encoding_rs's on all 7,040 rows it checked, both runs.
Geomean over each operation's 44 rows:

| op                      | before GB/s | after GB/s | after/before | before vs encoding_rs | after vs encoding_rs |
| ----------------------- | ----------: | ---------: | -----------: | --------------------: | -------------------: |
| DecodeUtf8/GBK          |        1.19 |       1.41 |        1.18x |                 1.56x |                1.80x |
| DecodeUtf16/GBK         |        1.42 |       1.49 |        1.05x |                 1.65x |                1.65x |
| EncodeUtf8/GBK          |        1.26 |       1.15 |        0.91x |                14.65x |               12.94x |
| EncodeUtf16/GBK         |        1.70 |       1.53 |        0.90x |                17.83x |               15.71x |
| DecodeUtf8/gb18030      |        1.20 |       1.43 |        1.19x |                 1.57x |                1.83x |
| DecodeUtf16/gb18030     |        1.45 |       1.49 |        1.03x |                 1.67x |                1.67x |
| EncodeUtf8/gb18030      |        1.27 |       1.17 |        0.92x |                14.56x |               13.14x |
| EncodeUtf16/gb18030     |        1.70 |       1.56 |        0.92x |                17.71x |               15.52x |
| DecodeUtf8/Big5         |        1.14 |       1.29 |        1.13x |                 1.30x |                1.43x |
| DecodeUtf16/Big5        |        1.23 |       1.37 |        1.11x |                 1.18x |                1.27x |
| EncodeUtf8/Big5         |        1.26 |       1.26 |        1.00x |                12.24x |               12.19x |
| EncodeUtf16/Big5        |        1.78 |       1.79 |        1.01x |                15.38x |               15.37x |
| DecodeUtf8/EUC-JP       |        1.36 |       1.50 |        1.10x |                 1.67x |                1.80x |
| DecodeUtf16/EUC-JP      |        1.67 |       1.83 |        1.10x |                 1.73x |                1.84x |
| EncodeUtf8/EUC-JP       |        1.11 |       1.17 |        1.05x |                 5.60x |                5.66x |
| EncodeUtf16/EUC-JP      |        1.65 |       1.73 |        1.05x |                 7.36x |                7.51x |
| DecodeUtf8/ISO-2022-JP  |        0.85 |       0.92 |        1.08x |                 2.25x |                2.39x |
| DecodeUtf16/ISO-2022-JP |        1.17 |       1.18 |        1.01x |                 2.81x |                2.77x |
| EncodeUtf8/ISO-2022-JP  |        0.68 |       0.71 |        1.04x |                 5.89x |                5.80x |
| EncodeUtf16/ISO-2022-JP |        1.02 |       1.08 |        1.06x |                 7.84x |                8.10x |
| DecodeUtf8/Shift_JIS    |        1.10 |       1.21 |        1.10x |                 1.36x |                1.46x |
| DecodeUtf16/Shift_JIS   |        1.24 |       1.36 |        1.10x |                 1.58x |                1.67x |
| EncodeUtf8/Shift_JIS    |        1.03 |       1.07 |        1.04x |                 5.30x |                5.30x |
| EncodeUtf16/Shift_JIS   |        1.39 |       1.44 |        1.04x |                 6.43x |                6.56x |
| DecodeUtf8/EUC-KR       |        1.37 |       1.46 |        1.07x |                 1.37x |                1.39x |
| DecodeUtf16/EUC-KR      |        1.43 |       1.39 |        0.97x |                 1.46x |                1.39x |
| EncodeUtf8/EUC-KR       |        1.12 |       1.14 |        1.02x |                 3.84x |                3.76x |
| EncodeUtf16/EUC-KR      |        1.86 |       1.90 |        1.02x |                 5.25x |                5.20x |

Overall, against encoding_rs: 3.77x before, 3.81x after; rows whose
whole interval is below encoding_rs (bench-summary's `<1` column): 50
before, 18 after. GBK and gb18030 encode are the table diet's price
(cjk-tables-20261102.md); EUC-KR decode to UTF-16, 0.97x, changed
neither its code nor its decode table (`flat_runs` emits chinese_rank's
decode unchanged) and was 0.95x in section 1's interleaved A/B as well,
which points at code placement, not proven.

The 18 rows still below encoding_rs after, ratio and 95% interval:

```text
DecodeUtf16/GBK/subtitles-64                  0.838  [0.789, 0.870]
DecodeUtf16/GBK/web-256                       0.923  [0.829, 0.967]
DecodeUtf16/gb18030/subtitles-64              0.828  [0.803, 0.875]
DecodeUtf8/Big5/nonascii-16                   0.924  [0.900, 0.966]
DecodeUtf16/Big5/mixed-64                     0.931  [0.917, 0.962]
DecodeUtf16/Big5/nonascii-64                  0.907  [0.867, 0.936]
DecodeUtf16/Big5/subtitles-64                 0.869  [0.836, 0.993]
DecodeUtf16/Big5/subtitles-256                0.920  [0.908, 0.934]
DecodeUtf16/Big5/csv-256                      0.931  [0.860, 0.967]
DecodeUtf16/Big5/csv-4096                     0.958  [0.922, 0.985]
DecodeUtf16/Big5/subtitles-4096               0.900  [0.825, 0.916]
DecodeUtf16/Big5/csv-65536                    0.974  [0.683, 0.986]
DecodeUtf8/Shift_JIS/subtitles-64             0.883  [0.854, 0.923]
DecodeUtf8/Shift_JIS/mail-256                 0.926  [0.840, 0.949]
DecodeUtf8/Shift_JIS/subtitles-4096           0.941  [0.889, 0.974]
DecodeUtf8/Shift_JIS/mail-4096                0.927  [0.903, 0.976]
DecodeUtf8/EUC-KR/mixed-256                   0.952  [0.947, 0.964]
DecodeUtf16/EUC-KR/mixed-4096                 0.970  [0.901, 0.983]
```

- Shift_JIS decode to UTF-8 on `mail` and `subtitles` (0.88x to 0.94x):
  encoding_rs computes kana from the trail byte, and we look every
  character up in index jis0208's paged decode table. A kana path is
  not tried: it adds a branch that mispredicts on text that alternates
  kana and kanji, as this corpus does.
- Big5, GBK, and gb18030 decode to UTF-16 on `subtitles`, `csv`, and
  short `nonascii` rows (0.83x to 0.97x), and Big5 to UTF-8 at 16
  bytes: short lines of hanzi between ASCII line breaks and digits.
  Not profiled, so no cause is claimed; section 1's writer narrowed
  these rows (Big5 decode to UTF-16 had 15 rows below before, 8 after).
- EUC-KR's `mixed` rows (0.95x to 0.97x): the `mixed` shape alternates
  ASCII and Hangul character by character. Section 2's lone-ASCII write
  might serve it; not tried, since EUC-KR's decoder is unchanged on this
  branch.

bench-summary, before:

```text
zig/arm, geomean              rows  zig GB/s     rust      icu    iconv libiconv       go     ±   <1    ~   slowest vs rust
DecodeUtf8/GBK                  44      1.19     1.56     4.53     3.37     6.33     3.86    1%    1    4   0.79 [0.72, 0.84] nonascii-16
DecodeUtf16/GBK                 44      1.42     1.65     3.21     3.46     7.01        -    1%    1    4   0.84 [0.83, 0.85] subtitles-64
EncodeUtf8/GBK                  44      1.26    14.65     2.36     3.88     6.66     2.37    1%    0    0   1.62 [1.56, 1.65] mail-16
EncodeUtf16/GBK                 44      1.70    17.83     2.48     3.91     7.25        -    1%    0    0   1.41 [1.37, 1.44] ascii-1048576
DecodeUtf8/gb18030              44      1.20     1.57     4.33     3.49     6.63     3.97    1%    1    4   0.79 [0.76, 0.88] nonascii-16
DecodeUtf16/gb18030             44      1.45     1.67     3.07     3.65     7.48        -    1%    0    3   0.83 [0.83, 1.05] subtitles-64
EncodeUtf8/gb18030              44      1.27    14.56     4.53     3.35     5.98     2.40    1%    0    0   1.61 [1.54, 1.66] subtitles-16
EncodeUtf16/gb18030             44      1.70    17.71     2.87     3.21     6.41        -    1%    0    0   1.41 [1.34, 1.48] ascii-1048576
DecodeUtf8/Big5                 44      1.14     1.30    10.37     9.80    14.86     4.53    1%    8    6   0.81 [0.81, 0.84] nonascii-16
DecodeUtf16/Big5                44      1.23     1.18     5.13     9.38    13.02        -    2%   15    2   0.77 [0.73, 0.79] subtitles-4096
EncodeUtf8/Big5                 44      1.26    12.24     7.33    12.88    15.99     6.41    1%    0    0   1.50 [1.25, 1.57] csv-16
EncodeUtf16/Big5                44      1.78    15.38     6.36    14.04    15.46        -    1%    0    0   1.33 [1.30, 1.37] ascii-1048576
DecodeUtf8/EUC-JP               44      1.36     1.67     5.51     4.63     8.22     4.72    1%    0    1   1.05 [0.99, 1.08] csv-64
DecodeUtf16/EUC-JP              44      1.67     1.73     4.01     5.03     9.30        -    2%    0    1   0.97 [0.94, 1.00] csv-64
EncodeUtf8/EUC-JP               44      1.11     5.60     4.56    11.15     5.75     2.42    1%    0    0   1.25 [1.20, 1.29] web-16
EncodeUtf16/EUC-JP              44      1.65     7.36     3.32    14.57     6.79        -    1%    0    0   1.34 [1.23, 1.37] web-16
DecodeUtf8/ISO-2022-JP          44      0.85     2.25     5.54     2.93     4.41     2.89    1%    5    0   0.53 [0.50, 0.54] invalid-256
DecodeUtf16/ISO-2022-JP         44      1.17     2.81     5.80     3.64     5.73        -    1%    5    0   0.54 [0.53, 0.56] invalid-16
EncodeUtf8/ISO-2022-JP          44      0.68     5.89     7.21     8.83     4.17     1.67    1%    0    0   1.50 [1.45, 1.61] web-16
EncodeUtf16/ISO-2022-JP         44      1.02     7.84     7.40    10.54     4.96        -    1%    0    0   1.57 [1.36, 1.59] invalid-65536
DecodeUtf8/Shift_JIS            44      1.10     1.36     4.41     4.26     6.81     4.70    1%   10    2   0.82 [0.81, 0.85] subtitles-64
DecodeUtf16/Shift_JIS           44      1.24     1.58     2.95     4.47     7.21        -    2%    1    2   0.84 [0.82, 0.87] csv-64
EncodeUtf8/Shift_JIS            44      1.03     5.30     1.81     3.07     5.78     2.54    1%    0    0   1.27 [1.23, 1.29] csv-16
EncodeUtf16/Shift_JIS           44      1.39     6.43     1.88     2.96     6.36        -    1%    0    0   1.32 [1.29, 1.35] web-16
DecodeUtf8/EUC-KR               44      1.37     1.37     5.12     4.56     7.75     3.98    1%    2    2   0.95 [0.94, 0.96] mixed-256
DecodeUtf16/EUC-KR              44      1.43     1.46     2.94     4.16     7.42        -    0%    1    2   0.96 [0.93, 0.99] mixed-256
EncodeUtf8/EUC-KR               44      1.12     3.84     2.20     4.00     5.66     2.08    1%    0    0   1.55 [1.40, 1.57] subtitles-16
EncodeUtf16/EUC-KR              44      1.86     5.25     2.73     4.12     6.87        -    1%    0    0   1.30 [1.26, 1.39] ascii-1048576
all                           1232      1.28     3.77     3.85     4.82     6.80     3.11         50   33

ns/call, median      bytes       zig      rust       icu     iconv  libiconv        go  zig/rust
DecodeUtf8              16       8.5      11.6      93.3      83.0      84.7      49.8      1.46
DecodeUtf8              64      48.1      62.7     210.1     190.5     300.9     169.7      1.51
DecodeUtf8             256     284.1     402.3     731.0     608.2    1193.2     775.3      1.30
DecodeUtf16             16       9.4      11.4      47.2      94.1      81.7         -      1.27
DecodeUtf16             64      38.5      52.4     103.4     185.6     289.1         -      1.58
DecodeUtf16            256     196.1     328.5     459.5     504.0    1079.5         -      1.46
EncodeUtf8              16       8.0      10.3      82.3      98.9      89.9      29.3      1.62
EncodeUtf8              64      70.8     584.8     166.2     216.3     329.8     109.8      5.69
EncodeUtf8             256     463.4    4999.6     589.3     798.7    1318.3     559.2      8.85
EncodeUtf16             16       8.2      11.0      48.6     111.9      84.6         -      1.60
EncodeUtf16             64      51.6     569.2     125.0     202.9     305.4         -      7.43
EncodeUtf16            256     293.8    4937.8     480.7     608.7    1216.5         -     13.03
```

bench-summary, after:

```text
zig/arm, geomean              rows  zig GB/s     rust      icu    iconv libiconv       go     ±   <1    ~   slowest vs rust
DecodeUtf8/GBK                  44      1.41     1.80     5.26     3.93     7.38     4.46    1%    0    0   1.14 [1.05, 1.19] mixed-64
DecodeUtf16/GBK                 44      1.49     1.65     3.21     3.46     7.04        -    1%    2    2   0.84 [0.79, 0.87] subtitles-64
EncodeUtf8/GBK                  44      1.15    12.94     2.09     3.43     5.93     2.09    2%    0    0   1.59 [1.51, 1.62] ascii-16
EncodeUtf16/GBK                 44      1.53    15.71     2.18     3.43     6.37        -    1%    0    0   1.39 [1.27, 1.41] ascii-1048576
DecodeUtf8/gb18030              44      1.43     1.83     5.03     4.10     7.79     4.66    1%    0    0   1.15 [1.14, 1.28] mixed-64
DecodeUtf16/gb18030             44      1.49     1.67     3.09     3.65     7.49        -    1%    1    4   0.83 [0.80, 0.88] subtitles-64
EncodeUtf8/gb18030              44      1.17    13.14     4.06     3.02     5.41     2.15    1%    0    0   1.62 [1.31, 1.77] subtitles-16
EncodeUtf16/gb18030             44      1.56    15.52     2.52     2.81     5.63        -    1%    0    0   1.38 [1.27, 1.50] ascii-1048576
DecodeUtf8/Big5                 44      1.29     1.43    10.96    10.39    15.89     5.02    2%    1    5   0.92 [0.90, 0.97] nonascii-16
DecodeUtf16/Big5                44      1.37     1.27     5.39     9.92    13.75        -    2%    8    7   0.87 [0.84, 0.99] subtitles-64
EncodeUtf8/Big5                 44      1.26    12.19     7.23    12.84    15.90     6.33    1%    0    0   1.49 [1.46, 1.50] ascii-16
EncodeUtf16/Big5                44      1.79    15.37     6.36    14.09    15.44        -    1%    0    0   1.34 [1.30, 1.37] ascii-1048576
DecodeUtf8/EUC-JP               44      1.50     1.80     5.89     5.00     8.86     5.06    2%    0    0   1.17 [1.12, 1.23] subtitles-64
DecodeUtf16/EUC-JP              44      1.83     1.84     4.22     5.27     9.75        -    1%    0    2   1.11 [1.03, 1.30] ascii-1048576
EncodeUtf8/EUC-JP               44      1.17     5.66     4.60    11.25     5.84     2.45    1%    0    0   1.31 [1.28, 1.33] mail-16
EncodeUtf16/EUC-JP              44      1.73     7.51     3.37    14.92     6.93        -    2%    0    0   1.33 [1.18, 1.66] ascii-1048576
DecodeUtf8/ISO-2022-JP          44      0.92     2.39     5.83     2.92     4.41     2.89    1%    0    0   1.15 [1.02, 1.22] mixed-16
DecodeUtf16/ISO-2022-JP         44      1.18     2.77     5.63     3.31     5.21        -    1%    0    0   1.16 [1.12, 1.28] ascii-16
EncodeUtf8/ISO-2022-JP          44      0.71     5.80     7.08     8.68     4.11     1.65    1%    0    0   1.37 [1.31, 1.45] subtitles-16
EncodeUtf16/ISO-2022-JP         44      1.08     8.10     7.63    10.85     5.12        -    1%    0    0   1.57 [1.45, 1.60] invalid-65536
DecodeUtf8/Shift_JIS            44      1.21     1.46     4.75     4.59     7.29     5.07    1%    4    7   0.88 [0.85, 0.92] subtitles-64
DecodeUtf16/Shift_JIS           44      1.36     1.67     3.07     4.65     7.51        -    1%    0    0   1.07 [1.00, 1.14] subtitles-64
EncodeUtf8/Shift_JIS            44      1.07     5.30     1.80     3.06     5.81     2.52    2%    0    0   1.27 [1.21, 1.30] web-16
EncodeUtf16/Shift_JIS           44      1.44     6.56     1.91     3.01     6.49        -    1%    0    0   1.34 [1.20, 1.35] web-16
DecodeUtf8/EUC-KR               44      1.46     1.39     5.22     4.65     7.88     4.04    2%    1    4   0.95 [0.95, 0.96] mixed-256
DecodeUtf16/EUC-KR              44      1.39     1.39     2.81     3.94     7.05        -    1%    1    1   0.96 [0.92, 1.05] mixed-256
EncodeUtf8/EUC-KR               44      1.14     3.76     2.16     3.94     5.56     2.05    2%    0    0   1.56 [1.44, 1.96] ascii-16
EncodeUtf16/EUC-KR              44      1.90     5.20     2.71     4.08     6.78        -    1%    0    0   1.30 [1.22, 1.33] ascii-1048576
all                           1232      1.33     3.81     3.86     4.82     6.80     3.17         18   32

ns/call, median      bytes       zig      rust       icu     iconv  libiconv        go  zig/rust
DecodeUtf8              16       8.8      11.5      93.4      81.3      84.5      49.2      1.47
DecodeUtf8              64      43.2      61.1     198.8     189.3     294.2     160.6      1.47
DecodeUtf8             256     247.7     404.7     718.0     597.1    1136.0     730.2      1.52
DecodeUtf16             16       9.3      11.3      46.2      92.0      78.7         -      1.23
DecodeUtf16             64      38.0      52.3     102.2     180.9     284.2         -      1.50
DecodeUtf16            256     198.2     320.5     440.1     476.2    1053.1         -      1.51
EncodeUtf8              16       7.7      10.2      83.3      94.8      86.7      28.8      1.60
EncodeUtf8              64      69.5     561.9     166.7     202.8     325.8     107.1      5.69
EncodeUtf8             256     465.2    4751.5     592.1     797.6    1283.3     536.7      8.92
EncodeUtf16             16       8.1      11.0      47.5     104.9      84.3         -      1.65
EncodeUtf16             64      46.8     522.4     125.0     197.0     301.6         -      8.06
EncodeUtf16            256     297.5    4609.2     462.3     594.3    1172.1         -     12.88
```

## Method

As in the header. The arms: `zig` and `main` as named in each section;
`j0`, `ja`, `jb` built from worktrees of `823accc` with the one change
each describes; `runs`, `rows`, `rb`, `rc`, and `nx` are the table arms
of cjk-tables-20261102.md. Each was `cd bench && zig build -p <dir>` and
copied to `zig-out/bin/bench-<arm>`. The runs:

- `BENCHTIME_MS=20 just arms="rust zig main runs rows" bench-compare 10 '/(Shift_JIS|EUC-JP|ISO-2022-JP|GBK|gb18030|Big5|EUC-KR)/'`, 1,232 rows (sections 1 and 3).
- `BENCHTIME_MS=20 just arms="rust zig j0 ja jb runs rb rc" bench-compare 10 '^Decode[^/]*/(Shift_JIS|EUC-JP)/' '^Encode[^/]*/(GBK|gb18030|EUC-KR|Big5)/'`, 528 rows (section 2's variants).
- `BENCHTIME_MS=20 just arms="rust zig main nx" bench-compare 10` with the same filter (section 2 against `main`).
- `BENCHTIME_MS=20 just arms="rust zig ctm ctmg cth cthg" bench-compare 10 '/(Shift_JIS|EUC-JP|ISO-2022-JP)/[a-z]+-(16|256)$'`, 96 rows (section 4), with bench/comptime's `bench-comptime` and `bench-generic` built at `2130053` and at the hooks commit (`cd bench/comptime && zig build arms`, ReleaseFast) and copied in as arms.

## Raw output

benchstat, `main` against `zig`, the 352 Chinese decode rows (section 1),
GB/s:

```text
                                     │     main      │                  zig                  │
                                     │     GB/s      │     GB/s       vs base                │
DecodeUtf8/GBK/ascii-16                  2.117 ± 12%     2.099 ± 12%        ~ (p=0.481 n=10)
DecodeUtf8/GBK/csv-16                    2.129 ± 21%     2.130 ± 18%        ~ (p=0.796 n=10)
DecodeUtf8/GBK/invalid-16               391.0m ± 17%    471.7m ± 22%  +20.64% (p=0.000 n=10)
DecodeUtf8/GBK/mail-16                   2.178 ±  3%     2.145 ±  3%        ~ (p=0.247 n=10)
DecodeUtf8/GBK/mixed-16                 534.2m ± 20%    717.2m ± 21%  +34.24% (p=0.000 n=10)
DecodeUtf8/GBK/nonascii-16              400.5m ± 24%    639.8m ± 11%  +59.73% (p=0.001 n=10)
DecodeUtf8/GBK/subtitles-16              2.190 ±  9%     2.106 ± 13%        ~ (p=0.436 n=10)
DecodeUtf8/GBK/web-16                    2.121 ± 11%     2.228 ± 15%        ~ (p=0.912 n=10)
DecodeUtf8/GBK/ascii-64                  7.088 ±  5%     7.158 ± 18%        ~ (p=0.796 n=10)
DecodeUtf8/GBK/csv-64                    1.426 ±  8%     1.988 ±  7%  +39.41% (p=0.000 n=10)
DecodeUtf8/GBK/invalid-64               378.3m ±  5%    386.8m ± 27%        ~ (p=0.063 n=10)
DecodeUtf8/GBK/mail-64                   7.331 ± 22%     7.016 ± 27%        ~ (p=0.796 n=10)
DecodeUtf8/GBK/mixed-64                 476.8m ± 20%    516.5m ± 21%   +8.33% (p=0.029 n=10)
DecodeUtf8/GBK/nonascii-64              571.8m ± 24%    749.0m ± 16%  +30.99% (p=0.000 n=10)
DecodeUtf8/GBK/subtitles-64              1.009 ± 22%     1.221 ± 17%  +20.98% (p=0.019 n=10)
DecodeUtf8/GBK/web-64                    7.505 ± 20%     7.232 ± 24%        ~ (p=0.912 n=10)
DecodeUtf8/GBK/csv-256                  897.0m ± 19%   1072.4m ± 26%  +19.55% (p=0.004 n=10)
DecodeUtf8/GBK/subtitles-256            783.7m ± 22%    990.2m ± 12%  +26.33% (p=0.004 n=10)
DecodeUtf8/GBK/ascii-256                 15.45 ± 27%     16.06 ± 25%        ~ (p=0.393 n=10)
DecodeUtf8/GBK/invalid-256              468.1m ± 20%    497.0m ± 20%        ~ (p=0.184 n=10)
DecodeUtf8/GBK/mail-256                  1.343 ± 24%     1.669 ± 23%  +24.24% (p=0.009 n=10)
DecodeUtf8/GBK/mixed-256                458.3m ±  5%    500.7m ± 20%   +9.25% (p=0.000 n=10)
DecodeUtf8/GBK/nonascii-256             661.3m ±  5%    851.4m ± 26%  +28.75% (p=0.000 n=10)
DecodeUtf8/GBK/web-256                   1.546 ± 11%     1.877 ±  7%  +21.38% (p=0.000 n=10)
DecodeUtf8/GBK/csv-4096                 738.9m ± 27%    917.1m ± 28%  +24.13% (p=0.007 n=10)
DecodeUtf8/GBK/ascii-4096                24.47 ±  8%     24.06 ±  6%        ~ (p=0.853 n=10)
DecodeUtf8/GBK/invalid-4096             472.6m ±  6%    517.5m ± 16%   +9.50% (p=0.001 n=10)
DecodeUtf8/GBK/mail-4096                811.5m ± 12%   1030.8m ± 11%  +27.02% (p=0.000 n=10)
DecodeUtf8/GBK/mixed-4096               461.6m ± 22%    547.4m ± 10%  +18.60% (p=0.041 n=10)
DecodeUtf8/GBK/nonascii-4096            693.6m ± 11%    895.3m ± 22%  +29.06% (p=0.002 n=10)
DecodeUtf8/GBK/subtitles-4096           756.9m ± 20%    988.6m ± 17%  +30.61% (p=0.002 n=10)
DecodeUtf8/GBK/web-4096                 756.9m ± 15%    906.4m ± 11%  +19.75% (p=0.004 n=10)
DecodeUtf8/GBK/mail-65536               814.0m ±  8%   1036.3m ± 15%  +27.30% (p=0.000 n=10)
DecodeUtf8/GBK/web-65536                659.2m ±  9%    858.9m ±  7%  +30.28% (p=0.000 n=10)
DecodeUtf8/GBK/ascii-65536               25.34 ± 19%     25.41 ± 18%        ~ (p=0.529 n=10)
DecodeUtf8/GBK/csv-65536                795.1m ± 13%    964.0m ± 18%  +21.24% (p=0.000 n=10)
DecodeUtf8/GBK/invalid-65536            270.6m ±  6%    256.6m ± 12%        ~ (p=0.271 n=10)
DecodeUtf8/GBK/mixed-65536              478.8m ± 23%    489.4m ±  6%        ~ (p=0.896 n=10)
DecodeUtf8/GBK/nonascii-65536           691.7m ±  9%    889.6m ±  5%  +28.62% (p=0.000 n=10)
DecodeUtf8/GBK/subtitles-65536          727.9m ±  7%    933.4m ± 14%  +28.23% (p=0.002 n=10)
DecodeUtf8/GBK/web-1048576              636.6m ± 18%    800.8m ± 16%  +25.78% (p=0.004 n=10)
DecodeUtf8/GBK/ascii-1048576             18.16 ± 16%     18.79 ± 10%        ~ (p=0.436 n=10)
DecodeUtf8/GBK/mixed-1048576            453.3m ± 15%    480.4m ± 20%   +5.98% (p=0.043 n=10)
DecodeUtf8/GBK/nonascii-1048576         682.4m ± 11%    875.9m ± 20%  +28.37% (p=0.000 n=10)
DecodeUtf16/GBK/ascii-16                 1.821 ± 20%     1.850 ± 19%        ~ (p=0.739 n=10)
DecodeUtf16/GBK/csv-16                   1.806 ± 32%     1.799 ±  4%        ~ (p=0.971 n=10)
DecodeUtf16/GBK/invalid-16              488.1m ±  4%    513.8m ±  3%   +5.28% (p=0.005 n=10)
DecodeUtf16/GBK/mail-16                  1.811 ±  4%     1.788 ±  3%        ~ (p=0.190 n=10)
DecodeUtf16/GBK/mixed-16                726.6m ± 11%    737.0m ±  3%        ~ (p=0.218 n=10)
DecodeUtf16/GBK/nonascii-16             681.0m ±  4%    592.1m ±  2%  -13.05% (p=0.000 n=10)
DecodeUtf16/GBK/subtitles-16             1.815 ± 12%     1.803 ± 21%        ~ (p=0.912 n=10)
DecodeUtf16/GBK/web-16                   1.809 ± 22%     1.800 ± 21%        ~ (p=0.631 n=10)
DecodeUtf16/GBK/ascii-64                 6.118 ± 11%     5.969 ±  6%        ~ (p=0.089 n=10)
DecodeUtf16/GBK/csv-64                   2.159 ±  4%     2.044 ± 18%        ~ (p=0.190 n=10)
DecodeUtf16/GBK/invalid-64              398.0m ±  4%    395.5m ± 23%        ~ (p=0.912 n=10)
DecodeUtf16/GBK/mail-64                  6.061 ± 37%     5.983 ±  5%        ~ (p=0.315 n=10)
DecodeUtf16/GBK/mixed-64                555.5m ± 22%    601.6m ± 12%        ~ (p=0.971 n=10)
DecodeUtf16/GBK/nonascii-64             880.1m ±  3%    801.8m ± 21%   -8.91% (p=0.023 n=10)
DecodeUtf16/GBK/subtitles-64             1.325 ± 23%     1.227 ±  6%   -7.46% (p=0.023 n=10)
DecodeUtf16/GBK/web-64                   6.199 ± 20%     6.229 ± 21%        ~ (p=0.579 n=10)
DecodeUtf16/GBK/csv-256                  1.334 ± 22%     1.301 ± 20%        ~ (p=0.353 n=10)
DecodeUtf16/GBK/subtitles-256            1.143 ±  7%     1.094 ±  5%   -4.24% (p=0.043 n=10)
DecodeUtf16/GBK/ascii-256                14.90 ± 20%     14.11 ± 26%        ~ (p=0.436 n=10)
DecodeUtf16/GBK/invalid-256             504.6m ± 23%    526.0m ± 16%        ~ (p=0.796 n=10)
DecodeUtf16/GBK/mail-256                 1.908 ±  8%     1.903 ± 13%        ~ (p=0.393 n=10)
DecodeUtf16/GBK/mixed-256               531.6m ± 14%    533.4m ±  5%        ~ (p=0.796 n=10)
DecodeUtf16/GBK/nonascii-256             1.066 ± 16%     1.045 ± 27%        ~ (p=0.063 n=10)
DecodeUtf16/GBK/web-256                  2.264 ± 12%     2.151 ± 19%        ~ (p=0.853 n=10)
DecodeUtf16/GBK/csv-4096                 1.237 ± 15%     1.106 ± 18%  -10.60% (p=0.009 n=10)
DecodeUtf16/GBK/ascii-4096               23.71 ± 16%     23.00 ± 19%        ~ (p=0.436 n=10)
DecodeUtf16/GBK/invalid-4096            590.2m ± 14%    576.2m ± 17%        ~ (p=0.739 n=10)
DecodeUtf16/GBK/mail-4096                1.223 ±  6%     1.177 ± 13%        ~ (p=0.247 n=10)
DecodeUtf16/GBK/mixed-4096              521.6m ±  7%    518.7m ±  7%        ~ (p=0.060 n=10)
DecodeUtf16/GBK/nonascii-4096            1.157 ±  6%     1.156 ±  6%        ~ (p=0.739 n=10)
DecodeUtf16/GBK/subtitles-4096           1.207 ± 17%     1.216 ± 15%        ~ (p=0.739 n=10)
DecodeUtf16/GBK/web-4096                 1.167 ± 10%     1.174 ±  7%        ~ (p=0.912 n=10)
DecodeUtf16/GBK/mail-65536               1.209 ± 18%     1.147 ±  9%        ~ (p=0.165 n=10)
DecodeUtf16/GBK/web-65536                1.033 ±  4%     1.018 ±  7%        ~ (p=1.000 n=10)
DecodeUtf16/GBK/ascii-65536              23.24 ±  9%     24.03 ± 17%        ~ (p=0.353 n=10)
DecodeUtf16/GBK/csv-65536                1.177 ±  8%     1.109 ±  5%        ~ (p=0.190 n=10)
DecodeUtf16/GBK/invalid-65536           265.1m ±  7%    270.3m ±  6%        ~ (p=0.197 n=10)
DecodeUtf16/GBK/mixed-65536             518.9m ±  6%    518.7m ±  8%        ~ (p=0.928 n=10)
DecodeUtf16/GBK/nonascii-65536           1.152 ± 20%     1.162 ±  1%        ~ (p=0.684 n=10)
DecodeUtf16/GBK/subtitles-65536          1.111 ± 20%     1.062 ± 21%        ~ (p=0.143 n=10)
DecodeUtf16/GBK/web-1048576             981.9m ±  7%    984.4m ± 22%        ~ (p=0.579 n=10)
DecodeUtf16/GBK/ascii-1048576            8.611 ± 13%     8.570 ± 10%        ~ (p=0.912 n=10)
DecodeUtf16/GBK/mixed-1048576           524.4m ± 23%    523.0m ± 23%        ~ (p=0.436 n=10)
DecodeUtf16/GBK/nonascii-1048576         1.079 ± 23%     1.132 ± 16%        ~ (p=0.075 n=10)
DecodeUtf8/gb18030/ascii-16              2.089 ±  8%     2.104 ±  9%        ~ (p=0.796 n=10)
DecodeUtf8/gb18030/csv-16                2.078 ±  9%     2.115 ±  9%        ~ (p=0.516 n=10)
DecodeUtf8/gb18030/invalid-16           576.7m ± 13%    727.1m ±  9%  +26.08% (p=0.000 n=10)
DecodeUtf8/gb18030/mail-16               2.076 ±  6%     2.085 ±  7%        ~ (p=0.796 n=10)
DecodeUtf8/gb18030/mixed-16             529.7m ± 21%    711.5m ± 20%  +34.31% (p=0.000 n=10)
DecodeUtf8/gb18030/nonascii-16          396.8m ±  9%    631.8m ±  6%  +59.21% (p=0.000 n=10)
DecodeUtf8/gb18030/subtitles-16          2.212 ± 19%     2.175 ± 18%        ~ (p=0.796 n=10)
DecodeUtf8/gb18030/web-16                2.057 ± 28%     2.215 ± 20%   +7.69% (p=0.043 n=10)
DecodeUtf8/gb18030/ascii-64              7.026 ±  9%     6.934 ±  4%        ~ (p=0.315 n=10)
DecodeUtf8/gb18030/csv-64                1.413 ± 10%     1.996 ± 19%  +41.21% (p=0.000 n=10)
DecodeUtf8/gb18030/invalid-64           478.6m ± 17%    527.1m ± 20%  +10.15% (p=0.023 n=10)
DecodeUtf8/gb18030/mail-64               6.917 ± 21%     7.062 ± 18%        ~ (p=0.436 n=10)
DecodeUtf8/gb18030/mixed-64             461.4m ±  5%    520.8m ± 14%  +12.86% (p=0.001 n=10)
DecodeUtf8/gb18030/nonascii-64          566.8m ± 27%    712.6m ± 27%  +25.72% (p=0.004 n=10)
DecodeUtf8/gb18030/subtitles-64          1.009 ± 17%     1.237 ± 14%  +22.60% (p=0.001 n=10)
DecodeUtf8/gb18030/web-64                6.981 ±  9%     7.017 ±  8%        ~ (p=0.670 n=10)
DecodeUtf8/gb18030/csv-256              871.5m ±  9%   1101.8m ± 15%  +26.43% (p=0.000 n=10)
DecodeUtf8/gb18030/subtitles-256        753.9m ± 11%    968.9m ±  7%  +28.52% (p=0.000 n=10)
DecodeUtf8/gb18030/ascii-256             15.46 ±  6%     15.79 ±  2%        ~ (p=0.353 n=10)
DecodeUtf8/gb18030/invalid-256          475.4m ±  8%    494.1m ± 19%   +3.94% (p=0.035 n=10)
DecodeUtf8/gb18030/mail-256              1.323 ± 11%     1.635 ± 12%  +23.57% (p=0.000 n=10)
DecodeUtf8/gb18030/mixed-256            458.8m ± 24%    497.1m ± 21%   +8.35% (p=0.035 n=10)
DecodeUtf8/gb18030/nonascii-256         663.7m ± 20%    847.4m ± 26%  +27.69% (p=0.000 n=10)
DecodeUtf8/gb18030/web-256               1.572 ±  6%     1.905 ± 17%  +21.20% (p=0.000 n=10)
DecodeUtf8/gb18030/csv-4096             752.2m ±  8%    920.9m ±  9%  +22.44% (p=0.009 n=10)
DecodeUtf8/gb18030/ascii-4096            24.20 ± 12%     23.50 ± 14%        ~ (p=0.393 n=10)
DecodeUtf8/gb18030/invalid-4096         444.8m ±  9%    473.4m ± 13%   +6.43% (p=0.009 n=10)
DecodeUtf8/gb18030/mail-4096            804.1m ±  7%   1016.3m ±  7%  +26.38% (p=0.001 n=10)
DecodeUtf8/gb18030/mixed-4096           461.6m ± 12%    504.5m ± 10%        ~ (p=0.052 n=10)
DecodeUtf8/gb18030/nonascii-4096        695.6m ± 28%    898.4m ±  9%  +29.15% (p=0.005 n=10)
DecodeUtf8/gb18030/subtitles-4096       749.2m ±  9%    967.1m ±  2%  +29.08% (p=0.000 n=10)
DecodeUtf8/gb18030/web-4096             714.5m ± 13%    896.6m ±  7%  +25.49% (p=0.001 n=10)
DecodeUtf8/gb18030/mail-65536           797.9m ± 25%   1027.6m ±  8%  +28.79% (p=0.000 n=10)
DecodeUtf8/gb18030/web-65536            687.4m ±  9%    834.6m ± 24%  +21.43% (p=0.000 n=10)
DecodeUtf8/gb18030/ascii-65536           26.69 ± 11%     25.94 ± 25%        ~ (p=0.971 n=10)
DecodeUtf8/gb18030/csv-65536            741.3m ± 13%    962.5m ± 26%  +29.83% (p=0.000 n=10)
DecodeUtf8/gb18030/invalid-65536        256.6m ±  7%    253.5m ±  6%        ~ (p=0.190 n=10)
DecodeUtf8/gb18030/mixed-65536          472.0m ±  4%    500.9m ±  4%   +6.13% (p=0.002 n=10)
DecodeUtf8/gb18030/nonascii-65536       689.6m ±  2%    883.6m ±  6%  +28.12% (p=0.000 n=10)
DecodeUtf8/gb18030/subtitles-65536      725.8m ±  7%    942.5m ±  6%  +29.87% (p=0.000 n=10)
DecodeUtf8/gb18030/web-1048576          661.4m ±  4%    831.4m ±  4%  +25.70% (p=0.002 n=10)
DecodeUtf8/gb18030/ascii-1048576         18.24 ± 15%     19.88 ±  8%        ~ (p=0.063 n=10)
DecodeUtf8/gb18030/mixed-1048576        471.8m ± 11%    478.9m ± 16%        ~ (p=0.247 n=10)
DecodeUtf8/gb18030/nonascii-1048576     675.3m ± 18%    873.8m ± 13%  +29.39% (p=0.000 n=10)
DecodeUtf16/gb18030/ascii-16             1.800 ±  9%     1.793 ±  4%        ~ (p=0.172 n=10)
DecodeUtf16/gb18030/csv-16               1.798 ±  7%     1.784 ±  7%        ~ (p=0.684 n=10)
DecodeUtf16/gb18030/invalid-16          770.0m ±  8%    670.4m ±  4%  -12.95% (p=0.002 n=10)
DecodeUtf16/gb18030/mail-16              1.810 ± 24%     1.804 ± 29%        ~ (p=0.739 n=10)
DecodeUtf16/gb18030/mixed-16            743.2m ± 24%    731.9m ± 24%        ~ (p=0.481 n=10)
DecodeUtf16/gb18030/nonascii-16         676.3m ±  5%    592.1m ±  5%  -12.44% (p=0.000 n=10)
DecodeUtf16/gb18030/subtitles-16         1.803 ±  7%     1.797 ±  5%        ~ (p=0.481 n=10)
DecodeUtf16/gb18030/web-16               1.822 ±  5%     1.805 ±  6%        ~ (p=0.631 n=10)
DecodeUtf16/gb18030/ascii-64             6.115 ±  6%     6.115 ±  6%        ~ (p=0.971 n=10)
DecodeUtf16/gb18030/csv-64               2.177 ± 26%     2.048 ± 24%   -5.94% (p=0.011 n=10)
DecodeUtf16/gb18030/invalid-64          568.1m ± 20%    522.0m ± 27%        ~ (p=0.075 n=10)
DecodeUtf16/gb18030/mail-64              6.096 ± 22%     5.963 ±  7%        ~ (p=0.165 n=10)
DecodeUtf16/gb18030/mixed-64            531.3m ± 21%    552.4m ± 19%        ~ (p=0.075 n=10)
DecodeUtf16/gb18030/nonascii-64         888.6m ± 16%    850.9m ± 14%        ~ (p=0.089 n=10)
DecodeUtf16/gb18030/subtitles-64         1.347 ± 17%     1.231 ± 20%   -8.60% (p=0.035 n=10)
DecodeUtf16/gb18030/web-64               6.088 ±  3%     6.009 ±  7%        ~ (p=0.796 n=10)
DecodeUtf16/gb18030/csv-256              1.287 ± 11%     1.238 ±  2%   -3.85% (p=0.019 n=10)
DecodeUtf16/gb18030/subtitles-256        1.141 ±  3%     1.064 ±  4%   -6.73% (p=0.003 n=10)
DecodeUtf16/gb18030/ascii-256            14.12 ±  9%     14.41 ±  5%        ~ (p=0.912 n=10)
DecodeUtf16/gb18030/invalid-256         517.1m ± 17%    500.5m ± 22%        ~ (p=0.436 n=10)
DecodeUtf16/gb18030/mail-256             1.868 ±  1%     1.898 ± 12%        ~ (p=0.052 n=10)
DecodeUtf16/gb18030/mixed-256           512.1m ±  4%    507.5m ±  2%        ~ (p=0.093 n=10)
DecodeUtf16/gb18030/nonascii-256         1.063 ±  7%     1.044 ±  6%        ~ (p=0.393 n=10)
DecodeUtf16/gb18030/web-256              2.153 ±  5%     2.168 ±  9%        ~ (p=0.971 n=10)
DecodeUtf16/gb18030/csv-4096             1.125 ±  8%     1.073 ± 12%        ~ (p=0.315 n=10)
DecodeUtf16/gb18030/ascii-4096           22.74 ± 18%     22.63 ±  6%        ~ (p=0.684 n=10)
DecodeUtf16/gb18030/invalid-4096        516.4m ± 13%    512.6m ± 12%        ~ (p=0.280 n=10)
DecodeUtf16/gb18030/mail-4096            1.222 ± 18%     1.176 ± 13%        ~ (p=0.971 n=10)
DecodeUtf16/gb18030/mixed-4096          544.7m ± 18%    536.5m ± 19%        ~ (p=0.481 n=10)
DecodeUtf16/gb18030/nonascii-4096        1.153 ±  6%     1.153 ±  6%        ~ (p=0.912 n=10)
DecodeUtf16/gb18030/subtitles-4096       1.201 ± 24%     1.223 ± 19%        ~ (p=0.912 n=10)
DecodeUtf16/gb18030/web-4096             1.172 ± 15%     1.102 ±  9%        ~ (p=0.165 n=10)
DecodeUtf16/gb18030/mail-65536           1.163 ±  9%     1.120 ±  8%   -3.67% (p=0.043 n=10)
DecodeUtf16/gb18030/web-65536            1.001 ±  9%     1.000 ± 13%        ~ (p=0.796 n=10)
DecodeUtf16/gb18030/ascii-65536          22.98 ± 12%     23.20 ± 13%        ~ (p=0.218 n=10)
DecodeUtf16/gb18030/csv-65536            1.139 ± 13%     1.092 ±  7%        ~ (p=0.280 n=10)
DecodeUtf16/gb18030/invalid-65536       264.1m ± 12%    272.0m ± 25%   +2.99% (p=0.035 n=10)
DecodeUtf16/gb18030/mixed-65536         544.6m ±  7%    538.2m ± 17%        ~ (p=1.000 n=10)
DecodeUtf16/gb18030/nonascii-65536       1.166 ± 21%     1.201 ± 18%        ~ (p=0.353 n=10)
DecodeUtf16/gb18030/subtitles-65536      1.110 ± 19%     1.013 ± 19%        ~ (p=0.063 n=10)
DecodeUtf16/gb18030/web-1048576        1010.4m ± 17%    937.7m ±  8%   -7.19% (p=0.003 n=10)
DecodeUtf16/gb18030/ascii-1048576        8.414 ± 12%     8.355 ± 12%        ~ (p=0.631 n=10)
DecodeUtf16/gb18030/mixed-1048576       527.5m ± 15%    527.7m ± 13%        ~ (p=0.838 n=10)
DecodeUtf16/gb18030/nonascii-1048576     1.029 ±  9%     1.133 ± 10%  +10.16% (p=0.004 n=10)
DecodeUtf8/Big5/ascii-16                 2.147 ±  5%     2.230 ±  7%        ~ (p=0.105 n=10)
DecodeUtf8/Big5/csv-16                   2.150 ±  3%     2.241 ±  2%   +4.20% (p=0.000 n=10)
DecodeUtf8/Big5/invalid-16              360.2m ±  3%    330.4m ±  4%   -8.26% (p=0.000 n=10)
DecodeUtf8/Big5/mail-16                  2.124 ±  4%     2.234 ±  2%   +5.18% (p=0.004 n=10)
DecodeUtf8/Big5/mixed-16                526.2m ± 14%    529.4m ± 16%        ~ (p=0.796 n=10)
DecodeUtf8/Big5/nonascii-16             384.8m ± 14%    434.5m ± 13%  +12.93% (p=0.011 n=10)
DecodeUtf8/Big5/subtitles-16             2.196 ± 16%     2.261 ±  9%        ~ (p=0.436 n=10)
DecodeUtf8/Big5/web-16                   2.298 ± 18%     2.282 ± 18%        ~ (p=0.684 n=10)
DecodeUtf8/Big5/ascii-64                 6.914 ± 18%     7.452 ± 19%   +7.79% (p=0.029 n=10)
DecodeUtf8/Big5/csv-64                   1.651 ± 15%     1.577 ± 16%        ~ (p=0.353 n=10)
DecodeUtf8/Big5/invalid-64              603.8m ± 22%    641.1m ± 13%        ~ (p=0.218 n=10)
DecodeUtf8/Big5/mail-64                  6.708 ± 13%     7.246 ±  6%   +8.02% (p=0.001 n=10)
DecodeUtf8/Big5/mixed-64                481.9m ±  6%    512.1m ±  8%   +6.27% (p=0.043 n=10)
DecodeUtf8/Big5/nonascii-64             516.3m ± 28%    607.2m ± 15%  +17.62% (p=0.009 n=10)
DecodeUtf8/Big5/subtitles-64            927.1m ± 11%   1033.5m ±  5%  +11.48% (p=0.011 n=10)
DecodeUtf8/Big5/web-64                   6.614 ± 19%     7.447 ± 18%        ~ (p=0.052 n=10)
DecodeUtf8/Big5/subtitles-256           748.8m ± 11%    870.8m ±  4%  +16.29% (p=0.001 n=10)
DecodeUtf8/Big5/ascii-256                14.50 ± 12%     16.12 ±  9%  +11.17% (p=0.009 n=10)
DecodeUtf8/Big5/csv-256                 712.2m ±  8%    794.8m ±  7%  +11.61% (p=0.015 n=10)
DecodeUtf8/Big5/invalid-256             436.7m ± 21%    450.9m ± 20%        ~ (p=0.912 n=10)
DecodeUtf8/Big5/mail-256                 1.433 ± 22%     1.619 ± 22%  +12.96% (p=0.005 n=10)
DecodeUtf8/Big5/mixed-256               463.7m ±  9%    482.2m ± 27%   +4.00% (p=0.043 n=10)
DecodeUtf8/Big5/nonascii-256            569.1m ± 13%    706.2m ±  6%  +24.11% (p=0.000 n=10)
DecodeUtf8/Big5/web-256                  1.581 ± 15%     1.854 ± 14%  +17.26% (p=0.003 n=10)
DecodeUtf8/Big5/csv-4096                638.6m ±  8%    805.8m ± 13%  +26.18% (p=0.000 n=10)
DecodeUtf8/Big5/ascii-4096               23.19 ±  6%     23.19 ±  6%        ~ (p=0.853 n=10)
DecodeUtf8/Big5/invalid-4096            462.2m ±  6%    495.5m ±  4%   +7.20% (p=0.011 n=10)
DecodeUtf8/Big5/mail-4096               828.3m ± 14%    992.0m ± 28%  +19.76% (p=0.003 n=10)
DecodeUtf8/Big5/mixed-4096              463.6m ± 11%    480.4m ±  1%        ~ (p=0.353 n=10)
DecodeUtf8/Big5/nonascii-4096           637.9m ± 11%    748.9m ± 18%  +17.40% (p=0.000 n=10)
DecodeUtf8/Big5/subtitles-4096          680.4m ±  6%    818.0m ±  9%  +20.24% (p=0.000 n=10)
DecodeUtf8/Big5/web-4096                644.9m ±  3%    765.2m ±  3%  +18.67% (p=0.000 n=10)
DecodeUtf8/Big5/csv-65536               621.3m ± 18%    735.5m ± 11%  +18.39% (p=0.000 n=10)
DecodeUtf8/Big5/subtitles-65536         674.0m ±  2%    801.4m ± 10%  +18.92% (p=0.000 n=10)
DecodeUtf8/Big5/web-65536               588.6m ±  7%    699.0m ±  8%  +18.76% (p=0.000 n=10)
DecodeUtf8/Big5/ascii-65536              25.93 ± 14%     25.31 ±  6%        ~ (p=0.853 n=10)
DecodeUtf8/Big5/invalid-65536           212.7m ± 22%    216.2m ±  3%        ~ (p=0.218 n=10)
DecodeUtf8/Big5/mail-65536              776.4m ±  6%    926.2m ±  6%  +19.30% (p=0.001 n=10)
DecodeUtf8/Big5/mixed-65536             456.8m ± 10%    483.4m ± 25%   +5.82% (p=0.023 n=10)
DecodeUtf8/Big5/nonascii-65536          584.7m ±  2%    716.5m ± 22%  +22.55% (p=0.000 n=10)
DecodeUtf8/Big5/ascii-1048576            18.59 ± 11%     18.95 ±  8%        ~ (p=0.971 n=10)
DecodeUtf8/Big5/mixed-1048576           450.9m ± 18%    483.1m ± 17%        ~ (p=0.190 n=10)
DecodeUtf8/Big5/nonascii-1048576        575.8m ± 13%    692.5m ±  2%  +20.26% (p=0.000 n=10)
DecodeUtf8/Big5/web-1048576             579.1m ± 10%    694.2m ±  4%  +19.89% (p=0.000 n=10)
DecodeUtf16/Big5/ascii-16                1.950 ± 18%     1.959 ± 13%        ~ (p=0.853 n=10)
DecodeUtf16/Big5/csv-16                  1.984 ±  8%     1.978 ± 10%        ~ (p=0.739 n=10)
DecodeUtf16/Big5/invalid-16             365.6m ± 17%    352.3m ±  7%        ~ (p=0.052 n=10)
DecodeUtf16/Big5/mail-16                 1.956 ±  7%     1.983 ± 12%        ~ (p=0.954 n=10)
DecodeUtf16/Big5/mixed-16               588.3m ± 23%    685.0m ± 20%  +16.44% (p=0.023 n=10)
DecodeUtf16/Big5/nonascii-16            560.8m ± 25%    644.3m ± 23%        ~ (p=0.075 n=10)
DecodeUtf16/Big5/subtitles-16            1.961 ± 24%     1.952 ± 26%        ~ (p=0.579 n=10)
DecodeUtf16/Big5/web-16                  1.940 ±  7%     1.941 ±  4%        ~ (p=0.755 n=10)
DecodeUtf16/Big5/ascii-64                6.406 ± 11%     6.499 ± 12%        ~ (p=0.436 n=10)
DecodeUtf16/Big5/csv-64                  1.560 ± 14%     2.091 ± 17%  +34.08% (p=0.000 n=10)
DecodeUtf16/Big5/invalid-64             631.6m ± 14%    672.8m ± 18%   +6.52% (p=0.023 n=10)
DecodeUtf16/Big5/mail-64                 6.370 ± 12%     6.509 ± 11%        ~ (p=0.143 n=10)
DecodeUtf16/Big5/mixed-64               472.9m ±  6%    507.0m ±  7%        ~ (p=0.075 n=10)
DecodeUtf16/Big5/nonascii-64            644.6m ± 20%    722.9m ± 27%  +12.15% (p=0.043 n=10)
DecodeUtf16/Big5/subtitles-64            1.114 ± 14%     1.210 ± 16%        ~ (p=0.052 n=10)
DecodeUtf16/Big5/web-64                  6.492 ± 12%     6.623 ±  3%        ~ (p=0.436 n=10)
DecodeUtf16/Big5/subtitles-256          913.3m ±  5%   1056.4m ±  5%  +15.67% (p=0.000 n=10)
DecodeUtf16/Big5/ascii-256               13.02 ± 19%     15.13 ±  2%  +16.22% (p=0.029 n=10)
DecodeUtf16/Big5/csv-256                854.4m ±  4%   1032.0m ± 22%  +20.79% (p=0.000 n=10)
DecodeUtf16/Big5/invalid-256            444.0m ±  7%    460.6m ±  7%   +3.75% (p=0.029 n=10)
DecodeUtf16/Big5/mail-256                1.746 ± 10%     2.074 ± 17%  +18.78% (p=0.000 n=10)
DecodeUtf16/Big5/mixed-256              460.0m ±  6%    490.2m ±  2%   +6.58% (p=0.000 n=10)
DecodeUtf16/Big5/nonascii-256           749.6m ±  4%    852.3m ±  5%  +13.70% (p=0.000 n=10)
DecodeUtf16/Big5/web-256                 1.844 ± 12%     2.065 ±  8%  +12.01% (p=0.000 n=10)
DecodeUtf16/Big5/csv-4096               862.3m ± 14%    987.8m ±  6%  +14.55% (p=0.000 n=10)
DecodeUtf16/Big5/ascii-4096              23.61 ± 17%     23.03 ± 21%        ~ (p=0.971 n=10)
DecodeUtf16/Big5/invalid-4096           495.8m ±  9%    522.5m ± 11%        ~ (p=0.190 n=10)
DecodeUtf16/Big5/mail-4096               1.057 ± 11%     1.227 ± 16%  +16.11% (p=0.001 n=10)
DecodeUtf16/Big5/mixed-4096             485.9m ± 20%    506.1m ± 22%        ~ (p=0.123 n=10)
DecodeUtf16/Big5/nonascii-4096          810.8m ±  9%    914.0m ±  9%  +12.73% (p=0.009 n=10)
DecodeUtf16/Big5/subtitles-4096         830.1m ±  3%    985.1m ± 14%  +18.67% (p=0.001 n=10)
DecodeUtf16/Big5/web-4096               822.4m ±  8%    956.3m ±  6%  +16.28% (p=0.001 n=10)
DecodeUtf16/Big5/csv-65536              786.9m ±  4%    933.9m ± 14%  +18.69% (p=0.002 n=10)
DecodeUtf16/Big5/subtitles-65536        853.6m ± 26%    996.4m ± 28%        ~ (p=0.105 n=10)
DecodeUtf16/Big5/web-65536              776.7m ± 10%    887.1m ± 18%  +14.21% (p=0.000 n=10)
DecodeUtf16/Big5/ascii-65536             22.87 ± 15%     22.78 ±  8%        ~ (p=0.481 n=10)
DecodeUtf16/Big5/invalid-65536          219.9m ± 11%    220.8m ±  7%        ~ (p=0.853 n=10)
DecodeUtf16/Big5/mail-65536              1.072 ±  8%     1.210 ± 13%  +12.89% (p=0.002 n=10)
DecodeUtf16/Big5/mixed-65536            484.8m ± 23%    502.0m ± 22%        ~ (p=0.123 n=10)
DecodeUtf16/Big5/nonascii-65536         787.2m ±  5%    915.2m ±  5%  +16.26% (p=0.001 n=10)
DecodeUtf16/Big5/ascii-1048576           8.517 ± 11%     8.422 ± 13%        ~ (p=0.912 n=10)
DecodeUtf16/Big5/mixed-1048576          476.2m ±  6%    492.5m ±  6%   +3.41% (p=0.010 n=10)
DecodeUtf16/Big5/nonascii-1048576       779.6m ± 21%    894.4m ±  6%  +14.72% (p=0.017 n=10)
DecodeUtf16/Big5/web-1048576            768.6m ±  5%    863.9m ±  4%  +12.39% (p=0.001 n=10)
geomean                                  1.269           1.363         +7.44%
```

benchstat, `main` against `nx`, the 176 Shift_JIS and EUC-JP decode rows
(section 2), GB/s:

```text
                                       │     main      │                  nx                   │
                                       │     GB/s      │     GB/s       vs base                │
DecodeUtf8/EUC-JP/ascii-16                 1.963 ± 17%     1.834 ± 23%        ~ (p=0.481 n=10)
DecodeUtf8/EUC-JP/csv-16                   2.033 ± 11%     2.012 ± 28%        ~ (p=0.684 n=10)
DecodeUtf8/EUC-JP/invalid-16              401.2m ± 13%    382.7m ± 12%        ~ (p=0.315 n=10)
DecodeUtf8/EUC-JP/mail-16                  1.871 ± 10%     1.849 ±  9%        ~ (p=0.353 n=10)
DecodeUtf8/EUC-JP/mixed-16                710.7m ±  8%    697.1m ±  9%        ~ (p=0.684 n=10)
DecodeUtf8/EUC-JP/nonascii-16             671.0m ± 18%    694.8m ± 10%        ~ (p=0.342 n=10)
DecodeUtf8/EUC-JP/subtitles-16             1.914 ± 11%     1.912 ± 12%        ~ (p=0.436 n=10)
DecodeUtf8/EUC-JP/web-16                   1.970 ± 16%     1.830 ± 19%        ~ (p=0.123 n=10)
DecodeUtf8/EUC-JP/subtitles-64             1.227 ± 14%     1.311 ± 16%        ~ (p=0.315 n=10)
DecodeUtf8/EUC-JP/ascii-64                 5.876 ±  9%     5.735 ± 10%        ~ (p=0.353 n=10)
DecodeUtf8/EUC-JP/csv-64                   1.506 ± 16%     2.112 ± 22%  +40.26% (p=0.000 n=10)
DecodeUtf8/EUC-JP/invalid-64              352.9m ± 21%    404.3m ±  4%  +14.57% (p=0.027 n=10)
DecodeUtf8/EUC-JP/mail-64                  5.845 ±  8%     5.824 ± 10%        ~ (p=0.579 n=10)
DecodeUtf8/EUC-JP/mixed-64                756.9m ± 21%    883.2m ± 11%  +16.69% (p=0.003 n=10)
DecodeUtf8/EUC-JP/nonascii-64             800.8m ± 14%    774.2m ± 21%        ~ (p=0.912 n=10)
DecodeUtf8/EUC-JP/web-64                   6.526 ±  9%     6.098 ± 14%        ~ (p=0.075 n=10)
DecodeUtf8/EUC-JP/subtitles-256            1.033 ± 18%     1.121 ± 26%        ~ (p=0.052 n=10)
DecodeUtf8/EUC-JP/ascii-256                12.60 ± 12%     13.79 ± 12%   +9.45% (p=0.043 n=10)
DecodeUtf8/EUC-JP/csv-256                 929.5m ± 16%   1061.0m ± 21%  +14.15% (p=0.029 n=10)
DecodeUtf8/EUC-JP/invalid-256             424.4m ± 12%    484.3m ± 11%  +14.13% (p=0.007 n=10)
DecodeUtf8/EUC-JP/mail-256                 1.766 ± 10%     1.668 ±  6%        ~ (p=0.353 n=10)
DecodeUtf8/EUC-JP/mixed-256               915.7m ± 26%   1126.0m ± 10%  +22.97% (p=0.000 n=10)
DecodeUtf8/EUC-JP/nonascii-256            879.4m ± 10%    918.4m ± 18%        ~ (p=0.280 n=10)
DecodeUtf8/EUC-JP/web-256                  1.849 ± 15%     1.953 ±  6%   +5.64% (p=0.035 n=10)
DecodeUtf8/EUC-JP/mail-4096                1.081 ± 20%     1.137 ±  6%        ~ (p=0.315 n=10)
DecodeUtf8/EUC-JP/subtitles-4096          965.5m ±  9%   1085.8m ±  8%  +12.47% (p=0.002 n=10)
DecodeUtf8/EUC-JP/ascii-4096               20.48 ±  9%     23.05 ± 25%  +12.54% (p=0.000 n=10)
DecodeUtf8/EUC-JP/csv-4096                905.6m ± 23%    992.9m ± 28%   +9.64% (p=0.023 n=10)
DecodeUtf8/EUC-JP/invalid-4096            405.6m ± 19%    478.9m ± 12%  +18.07% (p=0.004 n=10)
DecodeUtf8/EUC-JP/mixed-4096              995.0m ± 10%   1214.6m ±  9%  +22.06% (p=0.000 n=10)
DecodeUtf8/EUC-JP/nonascii-4096           931.9m ± 26%    945.0m ± 16%        ~ (p=0.218 n=10)
DecodeUtf8/EUC-JP/web-4096                952.8m ± 26%   1031.6m ± 23%   +8.28% (p=0.035 n=10)
DecodeUtf8/EUC-JP/csv-65536               817.5m ± 27%    976.0m ± 27%  +19.40% (p=0.009 n=10)
DecodeUtf8/EUC-JP/ascii-65536              23.06 ± 13%     25.27 ±  1%        ~ (p=0.089 n=10)
DecodeUtf8/EUC-JP/invalid-65536           139.5m ± 20%    164.3m ± 21%  +17.86% (p=0.023 n=10)
DecodeUtf8/EUC-JP/mail-65536               1.015 ± 16%     1.190 ± 15%  +17.26% (p=0.009 n=10)
DecodeUtf8/EUC-JP/mixed-65536              1.035 ± 21%     1.185 ± 11%  +14.48% (p=0.009 n=10)
DecodeUtf8/EUC-JP/nonascii-65536          985.6m ± 15%    953.5m ± 12%        ~ (p=0.796 n=10)
DecodeUtf8/EUC-JP/subtitles-65536         840.6m ±  9%   1002.3m ±  8%  +19.24% (p=0.000 n=10)
DecodeUtf8/EUC-JP/web-65536               816.9m ± 13%    907.0m ± 22%        ~ (p=0.063 n=10)
DecodeUtf8/EUC-JP/ascii-1048576            18.75 ± 16%     18.47 ± 19%        ~ (p=0.579 n=10)
DecodeUtf8/EUC-JP/mixed-1048576           999.2m ± 17%   1174.3m ±  8%  +17.53% (p=0.002 n=10)
DecodeUtf8/EUC-JP/nonascii-1048576        963.3m ± 14%   1005.0m ± 20%        ~ (p=0.631 n=10)
DecodeUtf8/EUC-JP/web-1048576             831.2m ± 11%    929.1m ± 26%        ~ (p=0.190 n=10)
DecodeUtf16/EUC-JP/ascii-16                1.861 ± 14%     1.793 ± 14%        ~ (p=0.315 n=10)
DecodeUtf16/EUC-JP/csv-16                  1.805 ±  8%     1.737 ±  9%        ~ (p=0.218 n=10)
DecodeUtf16/EUC-JP/invalid-16             438.2m ± 23%    454.4m ±  9%        ~ (p=0.089 n=10)
DecodeUtf16/EUC-JP/mail-16                 1.781 ± 25%     1.722 ± 11%        ~ (p=0.280 n=10)
DecodeUtf16/EUC-JP/mixed-16               732.2m ± 11%    767.6m ±  3%        ~ (p=0.143 n=10)
DecodeUtf16/EUC-JP/nonascii-16            911.2m ± 18%    854.9m ±  8%   -6.18% (p=0.029 n=10)
DecodeUtf16/EUC-JP/subtitles-16            1.787 ± 18%     1.694 ± 21%        ~ (p=0.143 n=10)
DecodeUtf16/EUC-JP/web-16                  1.755 ± 10%     1.713 ±  7%        ~ (p=0.089 n=10)
DecodeUtf16/EUC-JP/subtitles-64            1.819 ± 19%     1.978 ± 12%   +8.76% (p=0.029 n=10)
DecodeUtf16/EUC-JP/ascii-64                5.867 ± 11%     5.272 ±  6%  -10.15% (p=0.009 n=10)
DecodeUtf16/EUC-JP/csv-64                  1.569 ± 13%     2.597 ±  9%  +65.49% (p=0.000 n=10)
DecodeUtf16/EUC-JP/invalid-64             416.1m ±  5%    490.7m ± 19%  +17.92% (p=0.000 n=10)
DecodeUtf16/EUC-JP/mail-64                 5.899 ±  8%     5.493 ± 16%   -6.88% (p=0.019 n=10)
DecodeUtf16/EUC-JP/mixed-64               892.9m ± 27%   1141.5m ± 21%  +27.84% (p=0.002 n=10)
DecodeUtf16/EUC-JP/nonascii-64             1.189 ± 20%     1.138 ± 19%        ~ (p=0.190 n=10)
DecodeUtf16/EUC-JP/web-64                  6.263 ± 16%     5.725 ± 16%   -8.59% (p=0.043 n=10)
DecodeUtf16/EUC-JP/subtitles-256           1.490 ± 21%     1.930 ± 18%  +29.53% (p=0.003 n=10)
DecodeUtf16/EUC-JP/ascii-256               14.66 ± 16%     13.58 ± 16%        ~ (p=0.089 n=10)
DecodeUtf16/EUC-JP/csv-256                 1.474 ± 12%     1.722 ± 12%  +16.85% (p=0.001 n=10)
DecodeUtf16/EUC-JP/invalid-256            457.8m ±  9%    550.6m ± 12%  +20.28% (p=0.000 n=10)
DecodeUtf16/EUC-JP/mail-256                2.341 ±  6%     2.532 ±  8%   +8.14% (p=0.035 n=10)
DecodeUtf16/EUC-JP/mixed-256               1.261 ± 16%     1.495 ± 22%  +18.56% (p=0.003 n=10)
DecodeUtf16/EUC-JP/nonascii-256            1.443 ± 21%     1.423 ± 15%        ~ (p=0.631 n=10)
DecodeUtf16/EUC-JP/web-256                 2.755 ± 13%     2.883 ± 13%        ~ (p=0.579 n=10)
DecodeUtf16/EUC-JP/mail-4096               1.554 ± 19%     1.656 ±  7%        ~ (p=0.075 n=10)
DecodeUtf16/EUC-JP/subtitles-4096          1.458 ±  6%     1.644 ± 13%  +12.70% (p=0.007 n=10)
DecodeUtf16/EUC-JP/ascii-4096              23.75 ± 19%     22.90 ±  5%        ~ (p=0.105 n=10)
DecodeUtf16/EUC-JP/csv-4096                1.329 ± 20%     1.560 ± 21%  +17.42% (p=0.007 n=10)
DecodeUtf16/EUC-JP/invalid-4096           453.2m ± 12%    591.9m ± 19%  +30.60% (p=0.000 n=10)
DecodeUtf16/EUC-JP/mixed-4096              1.309 ± 21%     1.564 ± 26%  +19.49% (p=0.005 n=10)
DecodeUtf16/EUC-JP/nonascii-4096           1.575 ± 14%     1.454 ± 21%        ~ (p=0.105 n=10)
DecodeUtf16/EUC-JP/web-4096                1.480 ±  6%     1.546 ± 20%        ~ (p=0.481 n=10)
DecodeUtf16/EUC-JP/csv-65536               1.190 ± 10%     1.492 ± 12%  +25.42% (p=0.000 n=10)
DecodeUtf16/EUC-JP/ascii-65536             24.01 ± 10%     22.96 ±  5%        ~ (p=0.280 n=10)
DecodeUtf16/EUC-JP/invalid-65536          149.2m ±  7%    170.7m ±  9%  +14.37% (p=0.000 n=10)
DecodeUtf16/EUC-JP/mail-65536              1.427 ± 11%     1.535 ± 12%   +7.52% (p=0.005 n=10)
DecodeUtf16/EUC-JP/mixed-65536             1.300 ±  8%     1.559 ±  9%  +19.86% (p=0.001 n=10)
DecodeUtf16/EUC-JP/nonascii-65536          1.630 ± 10%     1.482 ±  6%   -9.06% (p=0.004 n=10)
DecodeUtf16/EUC-JP/subtitles-65536         1.214 ± 10%     1.404 ±  8%  +15.64% (p=0.000 n=10)
DecodeUtf16/EUC-JP/web-65536               1.249 ±  1%     1.294 ±  2%   +3.63% (p=0.015 n=10)
DecodeUtf16/EUC-JP/ascii-1048576           8.128 ± 20%     8.342 ± 14%        ~ (p=1.000 n=10)
DecodeUtf16/EUC-JP/mixed-1048576           1.240 ± 21%     1.574 ± 18%  +26.87% (p=0.000 n=10)
DecodeUtf16/EUC-JP/nonascii-1048576        1.554 ± 16%     1.427 ± 20%   -8.20% (p=0.015 n=10)
DecodeUtf16/EUC-JP/web-1048576             1.264 ± 10%     1.270 ± 17%        ~ (p=0.684 n=10)
DecodeUtf8/Shift_JIS/ascii-16              1.850 ± 13%     1.835 ± 11%        ~ (p=0.971 n=10)
DecodeUtf8/Shift_JIS/csv-16                1.869 ±  7%     1.829 ±  4%        ~ (p=0.063 n=10)
DecodeUtf8/Shift_JIS/invalid-16           345.2m ± 10%    343.3m ±  0%        ~ (p=0.617 n=10)
DecodeUtf8/Shift_JIS/mail-16               1.912 ± 22%     1.835 ± 10%        ~ (p=0.190 n=10)
DecodeUtf8/Shift_JIS/mixed-16             556.2m ± 13%    566.2m ± 22%        ~ (p=0.325 n=10)
DecodeUtf8/Shift_JIS/nonascii-16          505.7m ± 22%    516.9m ± 20%        ~ (p=0.218 n=10)
DecodeUtf8/Shift_JIS/subtitles-16          1.983 ± 14%     2.006 ±  9%        ~ (p=0.971 n=10)
DecodeUtf8/Shift_JIS/web-16                2.106 ± 12%     1.934 ± 14%        ~ (p=0.123 n=10)
DecodeUtf8/Shift_JIS/subtitles-64         892.4m ± 23%    970.6m ± 13%        ~ (p=0.218 n=10)
DecodeUtf8/Shift_JIS/ascii-64              6.486 ± 15%     6.356 ± 16%        ~ (p=0.315 n=10)
DecodeUtf8/Shift_JIS/csv-64                1.312 ±  6%     1.711 ±  6%  +30.37% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/invalid-64           381.7m ± 23%    384.2m ± 22%        ~ (p=0.565 n=10)
DecodeUtf8/Shift_JIS/mail-64               6.099 ± 21%     5.828 ± 25%        ~ (p=0.353 n=10)
DecodeUtf8/Shift_JIS/mixed-64             653.0m ± 14%    735.5m ± 13%  +12.63% (p=0.015 n=10)
DecodeUtf8/Shift_JIS/nonascii-64          534.6m ± 12%    551.1m ± 13%        ~ (p=0.225 n=10)
DecodeUtf8/Shift_JIS/web-64                5.896 ± 20%     6.019 ± 16%        ~ (p=0.529 n=10)
DecodeUtf8/Shift_JIS/subtitles-256        776.1m ±  9%    938.5m ± 17%  +20.93% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/ascii-256             13.66 ± 19%     14.42 ±  7%        ~ (p=0.353 n=10)
DecodeUtf8/Shift_JIS/csv-256              767.0m ± 17%    805.1m ± 19%        ~ (p=0.218 n=10)
DecodeUtf8/Shift_JIS/invalid-256          428.6m ± 15%    510.1m ± 13%  +19.00% (p=0.009 n=10)
DecodeUtf8/Shift_JIS/mail-256              1.367 ± 13%     1.386 ± 15%        ~ (p=0.306 n=10)
DecodeUtf8/Shift_JIS/mixed-256            677.5m ± 14%    950.0m ± 16%  +40.20% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/nonascii-256         600.6m ± 24%    688.1m ± 14%        ~ (p=0.061 n=10)
DecodeUtf8/Shift_JIS/web-256               1.569 ± 13%     1.575 ± 22%        ~ (p=0.315 n=10)
DecodeUtf8/Shift_JIS/subtitles-4096       713.6m ± 16%    759.6m ± 18%   +6.45% (p=0.015 n=10)
DecodeUtf8/Shift_JIS/web-4096             653.3m ± 20%    696.8m ± 20%   +6.66% (p=0.035 n=10)
DecodeUtf8/Shift_JIS/ascii-4096            21.45 ± 22%     25.61 ± 14%  +19.38% (p=0.029 n=10)
DecodeUtf8/Shift_JIS/csv-4096             648.9m ± 24%    729.9m ± 22%        ~ (p=0.063 n=10)
DecodeUtf8/Shift_JIS/invalid-4096         379.6m ±  7%    405.2m ±  9%   +6.76% (p=0.007 n=10)
DecodeUtf8/Shift_JIS/mail-4096            793.3m ± 10%    795.1m ± 16%        ~ (p=0.481 n=10)
DecodeUtf8/Shift_JIS/mixed-4096           734.2m ± 12%    895.3m ± 14%  +21.93% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/nonascii-4096        652.4m ± 19%    660.6m ± 21%        ~ (p=0.393 n=10)
DecodeUtf8/Shift_JIS/csv-65536            581.7m ± 12%    709.5m ± 11%  +21.97% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/web-65536            570.3m ± 25%    631.8m ± 24%  +10.78% (p=0.029 n=10)
DecodeUtf8/Shift_JIS/ascii-65536           23.83 ±  9%     26.04 ± 15%   +9.26% (p=0.009 n=10)
DecodeUtf8/Shift_JIS/invalid-65536        118.2m ± 19%    136.6m ± 14%  +15.57% (p=0.029 n=10)
DecodeUtf8/Shift_JIS/mail-65536           692.1m ± 21%    881.6m ± 11%  +27.38% (p=0.001 n=10)
DecodeUtf8/Shift_JIS/mixed-65536          703.8m ±  5%    848.1m ± 21%  +20.50% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/nonascii-65536       642.6m ± 15%    672.5m ± 14%        ~ (p=0.218 n=10)
DecodeUtf8/Shift_JIS/subtitles-65536      658.5m ± 14%    754.1m ± 12%  +14.52% (p=0.004 n=10)
DecodeUtf8/Shift_JIS/web-1048576          557.7m ±  7%    618.5m ±  6%  +10.91% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/ascii-1048576         18.51 ± 11%     19.95 ± 11%        ~ (p=0.063 n=10)
DecodeUtf8/Shift_JIS/mixed-1048576        733.0m ± 19%    822.4m ± 11%  +12.20% (p=0.023 n=10)
DecodeUtf8/Shift_JIS/nonascii-1048576     638.9m ± 17%    627.8m ± 11%        ~ (p=0.796 n=10)
DecodeUtf16/Shift_JIS/ascii-16             1.995 ± 14%     1.835 ± 14%        ~ (p=0.631 n=10)
DecodeUtf16/Shift_JIS/csv-16               1.733 ±  8%     1.746 ±  7%        ~ (p=0.739 n=10)
DecodeUtf16/Shift_JIS/invalid-16          336.2m ±  5%    372.9m ± 10%  +10.91% (p=0.001 n=10)
DecodeUtf16/Shift_JIS/mail-16              1.796 ±  9%     1.762 ± 11%        ~ (p=0.853 n=10)
DecodeUtf16/Shift_JIS/mixed-16            645.7m ±  8%    626.1m ± 26%        ~ (p=0.393 n=10)
DecodeUtf16/Shift_JIS/nonascii-16         651.5m ± 19%    580.0m ± 22%  -10.96% (p=0.011 n=10)
DecodeUtf16/Shift_JIS/subtitles-16         1.703 ± 12%     1.769 ±  8%        ~ (p=0.075 n=10)
DecodeUtf16/Shift_JIS/web-16               1.759 ±  8%     1.852 ±  9%        ~ (p=0.143 n=10)
DecodeUtf16/Shift_JIS/subtitles-64         1.478 ± 17%     1.111 ± 11%  -24.81% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/ascii-64             5.964 ± 15%     5.769 ± 11%        ~ (p=0.165 n=10)
DecodeUtf16/Shift_JIS/csv-64               1.110 ± 18%     2.060 ± 13%  +85.66% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/invalid-64          390.3m ± 10%    457.6m ± 14%  +17.26% (p=0.002 n=10)
DecodeUtf16/Shift_JIS/mail-64              5.838 ± 10%     6.160 ±  7%        ~ (p=0.631 n=10)
DecodeUtf16/Shift_JIS/mixed-64            711.6m ± 20%    815.1m ±  8%  +14.54% (p=0.009 n=10)
DecodeUtf16/Shift_JIS/nonascii-64         690.6m ±  9%    720.4m ±  7%        ~ (p=0.630 n=10)
DecodeUtf16/Shift_JIS/web-64               5.879 ±  7%     5.766 ±  7%        ~ (p=0.165 n=10)
DecodeUtf16/Shift_JIS/subtitles-256       931.0m ±  8%   1050.2m ± 13%  +12.80% (p=0.004 n=10)
DecodeUtf16/Shift_JIS/ascii-256            16.53 ± 16%     15.78 ± 10%        ~ (p=0.529 n=10)
DecodeUtf16/Shift_JIS/csv-256             990.9m ±  9%    983.5m ± 12%        ~ (p=0.631 n=10)
DecodeUtf16/Shift_JIS/invalid-256         408.3m ± 10%    569.0m ± 18%  +39.35% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/mail-256             1.623 ± 16%     1.653 ± 12%        ~ (p=0.971 n=10)
DecodeUtf16/Shift_JIS/mixed-256           805.1m ± 11%    977.9m ± 10%  +21.46% (p=0.007 n=10)
DecodeUtf16/Shift_JIS/nonascii-256        840.0m ±  5%    830.0m ± 23%        ~ (p=0.796 n=10)
DecodeUtf16/Shift_JIS/web-256              1.730 ±  7%     1.805 ± 11%   +4.35% (p=0.012 n=10)
DecodeUtf16/Shift_JIS/subtitles-4096      914.9m ± 22%    957.6m ± 19%        ~ (p=0.853 n=10)
DecodeUtf16/Shift_JIS/web-4096            892.0m ± 22%    881.4m ± 21%        ~ (p=0.353 n=10)
DecodeUtf16/Shift_JIS/ascii-4096           23.02 ± 25%     22.54 ± 11%        ~ (p=0.280 n=10)
DecodeUtf16/Shift_JIS/csv-4096            850.3m ±  9%    881.3m ± 19%        ~ (p=0.218 n=10)
DecodeUtf16/Shift_JIS/invalid-4096        416.3m ± 20%    508.4m ± 12%  +22.12% (p=0.035 n=10)
DecodeUtf16/Shift_JIS/mail-4096          1010.4m ±  9%    989.8m ± 20%        ~ (p=0.579 n=10)
DecodeUtf16/Shift_JIS/mixed-4096          878.4m ±  5%   1125.6m ±  6%  +28.14% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/nonascii-4096       917.1m ± 17%    877.0m ± 23%        ~ (p=0.448 n=10)
DecodeUtf16/Shift_JIS/csv-65536           736.4m ±  7%    868.7m ± 25%  +17.97% (p=0.002 n=10)
DecodeUtf16/Shift_JIS/web-65536           766.0m ±  4%    806.6m ±  6%   +5.30% (p=0.043 n=10)
DecodeUtf16/Shift_JIS/ascii-65536          23.27 ± 22%     23.05 ± 13%        ~ (p=0.579 n=10)
DecodeUtf16/Shift_JIS/invalid-65536       118.7m ± 22%    138.7m ± 13%  +16.86% (p=0.023 n=10)
DecodeUtf16/Shift_JIS/mail-65536          907.3m ± 27%    996.5m ± 12%        ~ (p=0.280 n=10)
DecodeUtf16/Shift_JIS/mixed-65536         852.3m ± 28%   1068.4m ± 27%  +25.35% (p=0.029 n=10)
DecodeUtf16/Shift_JIS/nonascii-65536      849.9m ±  6%    877.7m ±  9%   +3.27% (p=0.034 n=10)
DecodeUtf16/Shift_JIS/subtitles-65536     789.3m ±  5%    922.9m ± 18%  +16.93% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/web-1048576         780.2m ± 20%    769.2m ±  8%        ~ (p=0.853 n=10)
DecodeUtf16/Shift_JIS/ascii-1048576        8.250 ±  5%     8.801 ± 13%        ~ (p=0.315 n=10)
DecodeUtf16/Shift_JIS/mixed-1048576       835.0m ± 13%   1127.4m ± 15%  +35.02% (p=0.000 n=10)
DecodeUtf16/Shift_JIS/nonascii-1048576    834.0m ± 20%    864.8m ± 23%        ~ (p=0.393 n=10)
geomean                                    1.353           1.452         +7.31%
```

benchstat, `main` against `zig`, ISO-2022-JP's `invalid` decode rows
(section 3), GB/s:

```text
                                      │     main     │                  zig                   │
                                      │     GB/s     │     GB/s       vs base                 │
DecodeUtf8/ISO-2022-JP/invalid-16       75.20m ± 27%   239.70m ± 28%  +218.75% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/invalid-64       113.9m ± 17%    383.0m ±  4%  +236.11% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/invalid-256      111.4m ± 19%    389.7m ± 21%  +249.98% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/invalid-4096     106.0m ±  9%    306.9m ± 10%  +189.71% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/invalid-65536    85.95m ± 10%   138.60m ± 19%   +61.26% (p=0.000 n=10)
DecodeUtf16/ISO-2022-JP/invalid-16      82.90m ± 12%   372.70m ± 10%  +349.58% (p=0.000 n=10)
DecodeUtf16/ISO-2022-JP/invalid-64      125.1m ± 11%    502.3m ±  7%  +301.32% (p=0.000 n=10)
DecodeUtf16/ISO-2022-JP/invalid-256     128.5m ± 15%    470.7m ± 15%  +266.45% (p=0.000 n=10)
DecodeUtf16/ISO-2022-JP/invalid-4096    116.0m ± 21%    451.5m ± 26%  +289.06% (p=0.000 n=10)
DecodeUtf16/ISO-2022-JP/invalid-65536   93.65m ±  9%   159.65m ± 15%   +70.48% (p=0.000 n=10)
geomean                                 102.3m          315.2m        +207.99%
```

benchstat, `ctm` against `cth`, ns per call, the 16-byte rows (section 4;
the geomean is over all 96 rows):

```text
                                      │      ctm      │                  cth                  │
                                      │    sec/op     │    sec/op      vs base                │
DecodeUtf8/EUC-JP/ascii-16               11.76n ±  8%    10.30n ± 10%  -12.38% (p=0.000 n=10)
DecodeUtf8/EUC-JP/csv-16                 11.46n ±  6%    10.38n ±  6%   -9.42% (p=0.001 n=10)
DecodeUtf8/EUC-JP/invalid-16             38.75n ±  8%    38.17n ±  8%        ~ (p=0.579 n=10)
DecodeUtf8/EUC-JP/mail-16                11.47n ± 17%    10.13n ± 16%  -11.68% (p=0.034 n=10)
DecodeUtf8/EUC-JP/mixed-16               23.59n ± 16%    23.10n ± 17%        ~ (p=0.631 n=10)
DecodeUtf8/EUC-JP/nonascii-16            22.70n ± 17%    24.43n ± 21%        ~ (p=0.218 n=10)
DecodeUtf8/EUC-JP/subtitles-16           11.54n ± 17%    10.31n ± 17%        ~ (p=0.184 n=10)
DecodeUtf8/EUC-JP/web-16                 11.93n ± 16%    10.35n ± 13%  -13.17% (p=0.005 n=10)
DecodeUtf16/EUC-JP/ascii-16             11.560n ±  9%    9.970n ± 17%  -13.75% (p=0.003 n=10)
DecodeUtf16/EUC-JP/csv-16                11.89n ± 22%    10.52n ± 21%  -11.52% (p=0.027 n=10)
DecodeUtf16/EUC-JP/invalid-16            32.54n ± 10%    36.55n ±  8%  +12.31% (p=0.001 n=10)
DecodeUtf16/EUC-JP/mail-16               11.87n ± 11%    10.57n ± 18%  -10.91% (p=0.005 n=10)
DecodeUtf16/EUC-JP/mixed-16              19.97n ±  6%    18.82n ±  7%   -5.81% (p=0.030 n=10)
DecodeUtf16/EUC-JP/nonascii-16           18.54n ±  7%    17.46n ± 11%   -5.77% (p=0.005 n=10)
DecodeUtf16/EUC-JP/subtitles-16          11.85n ±  3%    10.58n ±  5%  -10.72% (p=0.000 n=10)
DecodeUtf16/EUC-JP/web-16                11.38n ±  5%    10.41n ±  4%   -8.48% (p=0.000 n=10)
EncodeUtf8/EUC-JP/ascii-16               5.955n ±  5%    6.285n ±  8%        ~ (p=0.072 n=10)
EncodeUtf8/EUC-JP/csv-16                 5.715n ± 13%    6.240n ± 11%   +9.19% (p=0.007 n=10)
EncodeUtf8/EUC-JP/invalid-16             74.18n ± 14%    76.78n ± 14%        ~ (p=0.315 n=10)
EncodeUtf8/EUC-JP/mail-16                5.665n ± 13%    5.995n ± 12%        ~ (p=0.118 n=10)
EncodeUtf8/EUC-JP/mixed-16               28.77n ± 15%    29.17n ± 12%        ~ (p=0.739 n=10)
EncodeUtf8/EUC-JP/nonascii-16            44.95n ±  9%    45.59n ±  7%        ~ (p=0.869 n=10)
EncodeUtf8/EUC-JP/subtitles-16           5.380n ± 13%    6.165n ± 15%  +14.59% (p=0.019 n=10)
EncodeUtf8/EUC-JP/web-16                 5.690n ± 17%    6.360n ± 22%        ~ (p=0.055 n=10)
EncodeUtf16/EUC-JP/ascii-16              6.320n ±  4%    6.185n ±  4%        ~ (p=0.147 n=10)
EncodeUtf16/EUC-JP/csv-16                6.235n ± 16%    6.065n ± 17%        ~ (p=0.289 n=10)
EncodeUtf16/EUC-JP/invalid-16            58.40n ± 13%    58.03n ± 11%        ~ (p=0.739 n=10)
EncodeUtf16/EUC-JP/mail-16               6.145n ± 15%    5.700n ± 14%        ~ (p=0.159 n=10)
EncodeUtf16/EUC-JP/mixed-16              18.83n ± 11%    19.00n ± 10%        ~ (p=0.481 n=10)
EncodeUtf16/EUC-JP/nonascii-16           28.23n ± 13%    27.63n ± 10%        ~ (p=0.971 n=10)
EncodeUtf16/EUC-JP/subtitles-16          5.790n ± 10%    6.125n ±  9%        ~ (p=0.669 n=10)
EncodeUtf16/EUC-JP/web-16                6.050n ±  6%    5.995n ±  9%        ~ (p=0.853 n=10)
DecodeUtf8/ISO-2022-JP/ascii-16          21.44n ± 15%    23.27n ±  7%   +8.54% (p=0.035 n=10)
DecodeUtf8/ISO-2022-JP/csv-16            21.94n ± 11%    23.98n ±  4%   +9.28% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/mail-16           21.36n ±  9%    24.11n ±  7%  +12.82% (p=0.000 n=10)
DecodeUtf8/ISO-2022-JP/mixed-16          23.44n ± 12%    29.00n ± 16%  +23.75% (p=0.001 n=10)
DecodeUtf8/ISO-2022-JP/subtitles-16      22.33n ± 17%    25.00n ± 17%  +12.00% (p=0.015 n=10)
DecodeUtf8/ISO-2022-JP/web-16            20.49n ± 11%    24.05n ± 15%  +17.35% (p=0.009 n=10)
DecodeUtf8/ISO-2022-JP/invalid-16        212.0n ± 18%    208.7n ±  9%        ~ (p=0.280 n=10)
DecodeUtf8/ISO-2022-JP/nonascii-16       27.44n ± 15%    30.54n ± 16%  +11.26% (p=0.027 n=10)
DecodeUtf16/ISO-2022-JP/ascii-16         22.45n ± 12%    22.64n ± 13%        ~ (p=0.393 n=10)
DecodeUtf16/ISO-2022-JP/csv-16           23.14n ± 14%    22.32n ± 12%        ~ (p=0.247 n=10)
DecodeUtf16/ISO-2022-JP/mail-16          23.07n ± 14%    23.33n ±  7%        ~ (p=0.971 n=10)
DecodeUtf16/ISO-2022-JP/mixed-16         23.49n ± 10%    22.43n ±  8%   -4.55% (p=0.034 n=10)
DecodeUtf16/ISO-2022-JP/subtitles-16     24.36n ± 10%    24.40n ± 10%        ~ (p=0.782 n=10)
DecodeUtf16/ISO-2022-JP/web-16           22.85n ± 13%    22.09n ±  7%        ~ (p=0.529 n=10)
DecodeUtf16/ISO-2022-JP/invalid-16       182.0n ± 11%    196.0n ± 10%        ~ (p=0.123 n=10)
DecodeUtf16/ISO-2022-JP/nonascii-16      23.80n ±  9%    23.48n ± 10%        ~ (p=0.289 n=10)
EncodeUtf8/ISO-2022-JP/ascii-16          18.37n ±  7%    19.23n ± 12%        ~ (p=0.072 n=10)
EncodeUtf8/ISO-2022-JP/csv-16            18.42n ±  6%    19.64n ± 16%        ~ (p=0.075 n=10)
EncodeUtf8/ISO-2022-JP/mail-16           18.39n ± 15%    19.96n ± 11%   +8.48% (p=0.009 n=10)
EncodeUtf8/ISO-2022-JP/mixed-16          26.32n ±  5%    26.08n ±  6%   -0.91% (p=0.011 n=10)
EncodeUtf8/ISO-2022-JP/subtitles-16      18.43n ± 19%    20.16n ± 22%   +9.36% (p=0.029 n=10)
EncodeUtf8/ISO-2022-JP/web-16            17.55n ± 16%    19.35n ± 14%  +10.26% (p=0.020 n=10)
EncodeUtf8/ISO-2022-JP/invalid-16        166.5n ±  5%    175.4n ±  9%        ~ (p=0.089 n=10)
EncodeUtf8/ISO-2022-JP/nonascii-16       31.15n ±  9%    29.95n ±  7%        ~ (p=0.810 n=10)
EncodeUtf16/ISO-2022-JP/ascii-16         18.59n ± 13%    16.64n ± 10%  -10.49% (p=0.029 n=10)
EncodeUtf16/ISO-2022-JP/csv-16           18.57n ± 13%    17.59n ± 16%        ~ (p=0.089 n=10)
EncodeUtf16/ISO-2022-JP/mail-16          19.05n ± 19%    16.88n ± 11%        ~ (p=0.052 n=10)
EncodeUtf16/ISO-2022-JP/mixed-16         19.01n ± 19%    17.85n ± 19%        ~ (p=0.075 n=10)
EncodeUtf16/ISO-2022-JP/subtitles-16     19.66n ± 20%    18.55n ± 21%        ~ (p=0.063 n=10)
EncodeUtf16/ISO-2022-JP/web-16           19.46n ± 20%    17.58n ± 18%   -9.64% (p=0.009 n=10)
EncodeUtf16/ISO-2022-JP/invalid-16       152.4n ± 21%    144.4n ±  9%   -5.24% (p=0.029 n=10)
EncodeUtf16/ISO-2022-JP/nonascii-16      24.09n ± 13%    23.76n ± 15%        ~ (p=0.363 n=10)
DecodeUtf8/Shift_JIS/ascii-16            6.230n ±  6%    6.260n ±  7%        ~ (p=0.542 n=10)
DecodeUtf8/Shift_JIS/csv-16              6.570n ± 11%    6.470n ±  7%        ~ (p=0.469 n=10)
DecodeUtf8/Shift_JIS/invalid-16          46.20n ± 16%    42.45n ± 13%        ~ (p=0.105 n=10)
DecodeUtf8/Shift_JIS/mail-16             6.275n ± 13%    6.270n ± 13%        ~ (p=0.781 n=10)
DecodeUtf8/Shift_JIS/mixed-16            31.71n ± 12%    26.50n ±  9%  -16.43% (p=0.000 n=10)
DecodeUtf8/Shift_JIS/nonascii-16         26.44n ± 12%    26.80n ± 11%        ~ (p=0.912 n=10)
DecodeUtf8/Shift_JIS/subtitles-16        6.105n ±  9%    5.950n ± 10%        ~ (p=0.579 n=10)
DecodeUtf8/Shift_JIS/web-16              6.150n ±  7%    6.195n ±  7%        ~ (p=0.645 n=10)
DecodeUtf16/Shift_JIS/ascii-16           6.875n ±  7%    6.475n ± 19%   -5.82% (p=0.004 n=10)
DecodeUtf16/Shift_JIS/csv-16             6.705n ± 18%    6.440n ± 17%        ~ (p=0.159 n=10)
DecodeUtf16/Shift_JIS/invalid-16         43.36n ± 20%    45.14n ± 19%        ~ (p=0.138 n=10)
DecodeUtf16/Shift_JIS/mail-16            6.370n ± 13%    6.610n ± 10%        ~ (p=0.985 n=10)
DecodeUtf16/Shift_JIS/mixed-16           20.82n ± 11%    22.32n ± 16%        ~ (p=0.631 n=10)
DecodeUtf16/Shift_JIS/nonascii-16        20.72n ± 10%    19.18n ± 16%        ~ (p=0.280 n=10)
DecodeUtf16/Shift_JIS/subtitles-16       6.270n ± 11%    6.065n ± 10%        ~ (p=0.280 n=10)
DecodeUtf16/Shift_JIS/web-16             6.815n ± 19%    6.075n ± 13%  -10.86% (p=0.037 n=10)
EncodeUtf8/Shift_JIS/ascii-16            5.870n ± 17%    6.250n ± 18%   +6.47% (p=0.043 n=10)
EncodeUtf8/Shift_JIS/csv-16              5.940n ± 10%    6.175n ± 11%        ~ (p=0.288 n=10)
EncodeUtf8/Shift_JIS/invalid-16          66.87n ±  7%    68.90n ±  9%        ~ (p=0.986 n=10)
EncodeUtf8/Shift_JIS/mail-16             5.940n ± 16%    5.900n ± 17%        ~ (p=0.699 n=10)
EncodeUtf8/Shift_JIS/mixed-16            31.93n ± 15%    35.73n ± 20%        ~ (p=0.393 n=10)
EncodeUtf8/Shift_JIS/nonascii-16         57.88n ± 10%    55.83n ± 19%        ~ (p=0.353 n=10)
EncodeUtf8/Shift_JIS/subtitles-16        5.610n ±  9%    6.020n ± 16%        ~ (p=0.404 n=10)
EncodeUtf8/Shift_JIS/web-16              5.895n ± 18%    6.015n ± 18%        ~ (p=0.280 n=10)
EncodeUtf16/Shift_JIS/ascii-16           6.145n ± 16%    6.435n ± 21%        ~ (p=0.836 n=10)
EncodeUtf16/Shift_JIS/csv-16             6.405n ±  9%    6.180n ± 17%        ~ (p=0.446 n=10)
EncodeUtf16/Shift_JIS/invalid-16         52.38n ± 13%    52.52n ± 17%        ~ (p=0.853 n=10)
EncodeUtf16/Shift_JIS/mail-16            6.355n ±  8%    6.320n ±  9%        ~ (p=0.912 n=10)
EncodeUtf16/Shift_JIS/mixed-16           25.90n ±  4%    26.14n ±  4%        ~ (p=0.853 n=10)
EncodeUtf16/Shift_JIS/nonascii-16        42.75n ±  7%    37.79n ± 15%  -11.61% (p=0.001 n=10)
EncodeUtf16/Shift_JIS/subtitles-16       6.465n ±  4%    6.310n ± 19%        ~ (p=0.592 n=10)
EncodeUtf16/Shift_JIS/web-16             6.395n ±  9%    6.325n ± 19%        ~ (p=0.631 n=10)
geomean                                  62.81n          62.62n         -0.31%
```
