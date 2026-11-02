# Single-byte decode without per-byte room checks, 2026-11-02

The single-byte decoder checked for room in `dst` before every non-ASCII
byte. A byte decodes to at most one UTF-16 unit or three UTF-8 bytes (every
single-byte table is in the BMP), so when the output has room for the rest
of the 16-byte block at that worst case, the loop now writes without the
checks; with less room it falls back to the checked loop. A block that the
ASCII copy finishes returns at once.

Headline: single-byte decode +20.9% geomean over 168 rows (UTF-16 +30% to
+65% on non-ASCII and invalid input); 121 rows faster, 3 slower, 44 within
noise. Decode to UTF-16 goes from about 0.8x encoding_rs to 0.95–1.14x
geomean per encoding.

## Method

Intel(R) Xeon(R) Processor @ 2.60GHz (4 vCPUs, AVX-512), in an orb. Zig
0.16 ReleaseFast for the host CPU. `just arms="rust zigbase zig"
bench-compare 10 'Decode.*(windows-1252|KOI8-R|ISO-8859-8|windows-1251|IBM866|macintosh)/(web|nonascii|invalid)-(16|64|256|4096|1048576)$'`
with `BENCHTIME_MS=20`: `zigbase` is the arm built before the change, `zig`
after, encoding_rs 0.8.44 the reference. Each arm is a server pinned to one
core (`taskset`), and the three time each row back to back in rotating
order, 10 rounds. Then `benchstat zigbase.txt zig.txt`.

The regressions: `DecodeUtf8/ISO-8859-8/invalid-4096` −21%,
`DecodeUtf8/windows-1252/web-256` −17%, `DecodeUtf8/macintosh/web-4096`
−10%. A first version without the early return after the ASCII copy also
lost 15–20% on every `DecodeUtf16/*/web-64` row (all ASCII); the early
return removed that.

## Against encoding_rs, after

```
zig/arm, geomean              rows  zig GB/s     rust     ±   <1    ~   slowest vs rust
DecodeUtf8/IBM866               14      0.80     0.97    1%    4    4   0.59 [0.57, 0.62] web-16
DecodeUtf16/IBM866              14      1.37     0.97    2%    6    2   0.54 [0.51, 0.56] nonascii-1048576
DecodeUtf8/ISO-8859-8           14      0.80     1.07    2%    5    2   0.60 [0.59, 0.69] web-16
DecodeUtf16/ISO-8859-8          14      1.36     1.14    1%    7    1   0.53 [0.51, 0.54] nonascii-4096
DecodeUtf8/KOI8-R               14      0.77     0.96    2%    6    4   0.55 [0.51, 0.64] invalid-4096
DecodeUtf16/KOI8-R              14      1.35     0.97    1%    7    0   0.53 [0.53, 0.54] nonascii-4096
DecodeUtf8/macintosh            14      1.07     1.04    1%    5    3   0.60 [0.59, 0.72] web-16
DecodeUtf16/macintosh           14      1.85     1.08    2%    5    1   0.53 [0.51, 0.54] nonascii-1048576
DecodeUtf8/windows-1251         14      0.78     0.97    2%    6    4   0.59 [0.55, 0.68] web-16
DecodeUtf16/windows-1251        14      1.31     0.95    2%    6    1   0.53 [0.50, 0.54] nonascii-4096
DecodeUtf8/windows-1252         14      1.03     0.95    1%    7    3   0.59 [0.58, 0.66] web-16
DecodeUtf16/windows-1252        14      1.72     1.03    2%    5    0   0.53 [0.51, 0.56] nonascii-4096
all                            168      1.13     1.01         69   25

ns/call, median      bytes       zig      rust  zig/rust
DecodeUtf8              16      28.8      29.1      0.99
DecodeUtf8              64      99.1     105.3      1.05
DecodeUtf8             256     357.1     406.3      1.10
DecodeUtf16             16      19.2      18.8      1.07
DecodeUtf16             64      55.1      49.2      1.35
DecodeUtf16            256     218.6     131.1      1.16
```

## benchstat, before (zigbase) and after (zig)

```
                                          │  zigbase.txt  │                zig.txt                │
                                          │     GB/s      │     GB/s       vs base                │
DecodeUtf8/IBM866/invalid-16                 512.0m ± 10%    577.8m ± 13%  +12.83% (p=0.023 n=10)
DecodeUtf8/IBM866/nonascii-16                371.1m ± 12%    437.5m ± 11%  +17.91% (p=0.000 n=10)
DecodeUtf8/IBM866/web-16                      1.034 ± 14%     1.074 ± 10%        ~ (p=0.684 n=10)
DecodeUtf8/IBM866/invalid-64                 637.6m ± 12%    641.8m ± 12%        ~ (p=0.481 n=10)
DecodeUtf8/IBM866/nonascii-64                429.2m ± 14%    665.4m ±  9%  +55.00% (p=0.000 n=10)
DecodeUtf8/IBM866/web-64                      3.938 ± 11%     3.939 ±  9%        ~ (p=0.971 n=10)
DecodeUtf8/IBM866/invalid-256                602.9m ±  4%    654.0m ±  4%   +8.47% (p=0.019 n=10)
DecodeUtf8/IBM866/nonascii-256               447.3m ±  8%    729.9m ±  7%  +63.18% (p=0.000 n=10)
DecodeUtf8/IBM866/web-256                     2.632 ±  8%     2.808 ±  8%        ~ (p=0.063 n=10)
DecodeUtf8/IBM866/invalid-4096               299.3m ± 15%    332.3m ± 17%        ~ (p=0.123 n=10)
DecodeUtf8/IBM866/nonascii-4096              452.8m ± 20%    774.4m ± 19%  +71.02% (p=0.001 n=10)
DecodeUtf8/IBM866/web-4096                   734.6m ±  8%    908.0m ± 11%  +23.60% (p=0.000 n=10)
DecodeUtf8/IBM866/nonascii-1048576           442.9m ±  9%    754.7m ± 11%  +70.40% (p=0.000 n=10)
DecodeUtf8/IBM866/web-1048576                369.7m ± 11%    416.9m ± 15%  +12.78% (p=0.029 n=10)
DecodeUtf16/IBM866/invalid-16                672.0m ±  7%    880.3m ±  9%  +31.00% (p=0.000 n=10)
DecodeUtf16/IBM866/nonascii-16               646.4m ± 17%    832.8m ± 13%  +28.84% (p=0.000 n=10)
DecodeUtf16/IBM866/web-16                     1.720 ± 14%     1.733 ± 12%        ~ (p=0.853 n=10)
DecodeUtf16/IBM866/invalid-64                860.1m ± 14%   1076.8m ± 14%  +25.19% (p=0.000 n=10)
DecodeUtf16/IBM866/nonascii-64               915.1m ± 21%   1157.0m ± 13%  +26.43% (p=0.000 n=10)
DecodeUtf16/IBM866/web-64                     5.996 ± 14%     6.062 ± 10%        ~ (p=0.796 n=10)
DecodeUtf16/IBM866/invalid-256               863.6m ± 12%   1131.5m ± 14%  +31.01% (p=0.000 n=10)
DecodeUtf16/IBM866/nonascii-256              936.6m ± 10%   1205.6m ± 10%  +28.72% (p=0.000 n=10)
DecodeUtf16/IBM866/web-256                    3.676 ± 10%     4.704 ± 10%  +27.94% (p=0.001 n=10)
DecodeUtf16/IBM866/invalid-4096              846.8m ±  8%   1076.2m ± 11%  +27.09% (p=0.000 n=10)
DecodeUtf16/IBM866/nonascii-4096              1.019 ±  9%     1.268 ±  8%  +24.39% (p=0.000 n=10)
DecodeUtf16/IBM866/web-4096                   1.243 ± 11%     1.495 ± 16%  +20.22% (p=0.002 n=10)
DecodeUtf16/IBM866/nonascii-1048576          968.9m ± 14%   1280.7m ± 14%  +32.18% (p=0.001 n=10)
DecodeUtf16/IBM866/web-1048576               388.6m ± 12%    494.0m ± 14%  +27.12% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/invalid-16             531.4m ± 10%    547.5m ± 11%        ~ (p=0.393 n=10)
DecodeUtf8/ISO-8859-8/nonascii-16            368.5m ± 13%    444.3m ± 11%  +20.55% (p=0.001 n=10)
DecodeUtf8/ISO-8859-8/web-16                  1.103 ± 14%     1.074 ± 12%        ~ (p=0.971 n=10)
DecodeUtf8/ISO-8859-8/invalid-64             618.1m ±  9%    632.9m ± 12%        ~ (p=0.481 n=10)
DecodeUtf8/ISO-8859-8/nonascii-64            465.1m ± 12%    657.5m ± 10%  +41.35% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/web-64                  3.823 ± 14%     3.967 ± 12%        ~ (p=0.481 n=10)
DecodeUtf8/ISO-8859-8/invalid-256            571.8m ± 10%    653.9m ± 13%  +14.37% (p=0.005 n=10)
DecodeUtf8/ISO-8859-8/nonascii-256           457.4m ± 12%    727.3m ± 15%  +59.01% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/web-256                 2.286 ± 12%     2.397 ± 10%        ~ (p=0.165 n=10)
DecodeUtf8/ISO-8859-8/invalid-4096           529.7m ± 11%    417.8m ± 15%  -21.12% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/nonascii-4096          467.4m ± 11%    762.3m ± 27%  +63.07% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/web-4096               773.7m ± 12%    881.8m ± 13%  +13.96% (p=0.009 n=10)
DecodeUtf8/ISO-8859-8/nonascii-1048576       464.0m ± 11%    788.6m ± 14%  +69.96% (p=0.000 n=10)
DecodeUtf8/ISO-8859-8/web-1048576            386.8m ± 11%    433.4m ± 11%  +12.07% (p=0.015 n=10)
DecodeUtf16/ISO-8859-8/invalid-16            699.1m ± 12%    891.0m ± 16%  +27.44% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/nonascii-16           663.6m ± 14%    827.6m ± 15%  +24.71% (p=0.002 n=10)
DecodeUtf16/ISO-8859-8/web-16                 1.710 ± 13%     1.843 ±  8%        ~ (p=0.247 n=10)
DecodeUtf16/ISO-8859-8/invalid-64            840.1m ± 10%   1234.2m ±  8%  +46.91% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/nonascii-64           912.9m ±  7%   1151.1m ±  9%  +26.10% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/web-64                 5.881 ± 11%     5.959 ±  6%        ~ (p=0.971 n=10)
DecodeUtf16/ISO-8859-8/invalid-256           825.9m ± 12%   1183.0m ± 14%  +43.23% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/nonascii-256           1.034 ± 14%     1.315 ± 13%  +27.15% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/web-256                3.242 ± 14%     4.273 ± 19%  +31.81% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/invalid-4096          721.6m ± 18%   1063.5m ± 16%  +47.37% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/nonascii-4096         981.5m ± 18%   1203.5m ± 19%  +22.61% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/web-4096               1.095 ± 14%     1.373 ± 16%  +25.38% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/nonascii-1048576      926.6m ± 15%   1149.0m ± 17%  +24.00% (p=0.000 n=10)
DecodeUtf16/ISO-8859-8/web-1048576           379.6m ± 19%    471.5m ± 13%  +24.20% (p=0.001 n=10)
DecodeUtf8/KOI8-R/invalid-16                 463.2m ± 19%    503.1m ± 20%   +8.61% (p=0.029 n=10)
DecodeUtf8/KOI8-R/nonascii-16                378.2m ± 12%    433.4m ± 20%  +14.58% (p=0.011 n=10)
DecodeUtf8/KOI8-R/web-16                     998.2m ± 18%    969.6m ± 16%        ~ (p=0.078 n=10)
DecodeUtf8/KOI8-R/invalid-64                 589.4m ±  6%    614.9m ± 18%   +4.33% (p=0.043 n=10)
DecodeUtf8/KOI8-R/nonascii-64                423.9m ± 12%    645.1m ± 15%  +52.19% (p=0.000 n=10)
DecodeUtf8/KOI8-R/web-64                      3.838 ± 13%     3.908 ± 10%        ~ (p=0.631 n=10)
DecodeUtf8/KOI8-R/invalid-256                629.1m ± 13%    657.6m ± 10%        ~ (p=0.436 n=10)
DecodeUtf8/KOI8-R/nonascii-256               450.1m ± 13%    728.5m ± 10%  +61.85% (p=0.000 n=10)
DecodeUtf8/KOI8-R/web-256                     2.613 ± 15%     2.760 ± 16%        ~ (p=0.190 n=10)
DecodeUtf8/KOI8-R/invalid-4096               278.9m ± 11%    306.3m ±  9%   +9.84% (p=0.023 n=10)
DecodeUtf8/KOI8-R/nonascii-4096              459.2m ± 14%    744.5m ± 19%  +62.11% (p=0.000 n=10)
DecodeUtf8/KOI8-R/web-4096                   739.7m ± 14%    881.6m ± 19%  +19.17% (p=0.000 n=10)
DecodeUtf8/KOI8-R/nonascii-1048576           449.4m ± 14%    770.0m ± 13%  +71.37% (p=0.000 n=10)
DecodeUtf8/KOI8-R/web-1048576                368.8m ± 10%    417.8m ± 14%  +13.29% (p=0.001 n=10)
DecodeUtf16/KOI8-R/invalid-16                698.6m ± 10%    813.2m ± 16%  +16.40% (p=0.005 n=10)
DecodeUtf16/KOI8-R/nonascii-16               673.4m ±  9%    834.3m ±  8%  +23.90% (p=0.000 n=10)
DecodeUtf16/KOI8-R/web-16                     1.729 ± 10%     1.789 ±  8%        ~ (p=0.393 n=10)
DecodeUtf16/KOI8-R/invalid-64                877.3m ± 11%   1136.0m ±  8%  +29.48% (p=0.000 n=10)
DecodeUtf16/KOI8-R/nonascii-64               907.4m ±  8%   1174.2m ±  7%  +29.39% (p=0.000 n=10)
DecodeUtf16/KOI8-R/web-64                     5.970 ±  6%     5.835 ±  3%        ~ (p=0.190 n=10)
DecodeUtf16/KOI8-R/invalid-256               876.2m ±  5%   1144.4m ±  6%  +30.60% (p=0.000 n=10)
DecodeUtf16/KOI8-R/nonascii-256              922.9m ± 11%   1134.1m ± 11%  +22.88% (p=0.000 n=10)
DecodeUtf16/KOI8-R/web-256                    3.634 ±  9%     4.644 ± 11%  +27.80% (p=0.000 n=10)
DecodeUtf16/KOI8-R/invalid-4096              777.8m ± 15%   1042.2m ± 16%  +33.99% (p=0.000 n=10)
DecodeUtf16/KOI8-R/nonascii-4096             999.4m ± 11%   1250.9m ±  9%  +25.16% (p=0.000 n=10)
DecodeUtf16/KOI8-R/web-4096                   1.185 ± 10%     1.506 ±  8%  +27.12% (p=0.000 n=10)
DecodeUtf16/KOI8-R/nonascii-1048576          964.3m ±  6%   1215.1m ±  9%  +26.01% (p=0.000 n=10)
DecodeUtf16/KOI8-R/web-1048576               387.4m ±  7%    481.5m ± 10%  +24.28% (p=0.000 n=10)
DecodeUtf8/macintosh/invalid-16              513.1m ± 12%    561.2m ±  5%   +9.37% (p=0.043 n=10)
DecodeUtf8/macintosh/nonascii-16             342.6m ± 10%    423.2m ±  6%  +23.53% (p=0.000 n=10)
DecodeUtf8/macintosh/web-16                  973.8m ± 21%    965.2m ± 20%        ~ (p=0.971 n=10)
DecodeUtf8/macintosh/invalid-64              590.8m ± 18%    631.4m ± 13%        ~ (p=0.123 n=10)
DecodeUtf8/macintosh/nonascii-64             402.0m ± 16%    618.9m ± 21%  +53.99% (p=0.000 n=10)
DecodeUtf8/macintosh/web-64                   3.722 ± 17%     3.834 ± 17%        ~ (p=0.280 n=10)
DecodeUtf8/macintosh/invalid-256             585.1m ± 17%    631.2m ± 14%        ~ (p=0.143 n=10)
DecodeUtf8/macintosh/nonascii-256            428.2m ± 12%    635.0m ± 19%  +48.31% (p=0.000 n=10)
DecodeUtf8/macintosh/web-256                  11.94 ± 11%     11.32 ± 10%        ~ (p=0.165 n=10)
DecodeUtf8/macintosh/invalid-4096            364.4m ± 10%    406.1m ±  9%  +11.45% (p=0.002 n=10)
DecodeUtf8/macintosh/nonascii-4096           441.7m ±  5%    663.0m ±  6%  +50.11% (p=0.000 n=10)
DecodeUtf8/macintosh/web-4096                 5.629 ±  6%     5.079 ±  6%   -9.77% (p=0.001 n=10)
DecodeUtf8/macintosh/nonascii-1048576        329.4m ± 19%    490.9m ± 22%  +49.05% (p=0.000 n=10)
DecodeUtf8/macintosh/web-1048576              2.418 ±  5%     2.448 ±  8%        ~ (p=1.000 n=10)
DecodeUtf16/macintosh/invalid-16             717.3m ± 14%    818.9m ± 11%  +14.16% (p=0.012 n=10)
DecodeUtf16/macintosh/nonascii-16            648.9m ± 15%    813.5m ± 17%  +25.37% (p=0.000 n=10)
DecodeUtf16/macintosh/web-16                  1.644 ± 18%     1.742 ± 16%   +5.93% (p=0.035 n=10)
DecodeUtf16/macintosh/invalid-64             856.3m ±  9%   1108.4m ± 17%  +29.44% (p=0.000 n=10)
DecodeUtf16/macintosh/nonascii-64            907.8m ± 14%   1145.6m ± 14%  +26.20% (p=0.000 n=10)
DecodeUtf16/macintosh/web-64                  5.734 ±  7%     5.616 ±  8%        ~ (p=0.853 n=10)
DecodeUtf16/macintosh/invalid-256            841.4m ±  9%   1144.0m ± 10%  +35.96% (p=0.000 n=10)
DecodeUtf16/macintosh/nonascii-256           897.2m ± 11%   1124.4m ± 10%  +25.32% (p=0.000 n=10)
DecodeUtf16/macintosh/web-256                 14.93 ± 14%     15.84 ±  7%        ~ (p=0.315 n=10)
DecodeUtf16/macintosh/invalid-4096           823.0m ± 15%   1036.2m ± 18%  +25.91% (p=0.000 n=10)
DecodeUtf16/macintosh/nonascii-4096          939.6m ± 15%   1201.9m ± 12%  +27.92% (p=0.000 n=10)
DecodeUtf16/macintosh/web-4096                6.361 ± 13%     8.305 ± 12%  +30.55% (p=0.000 n=10)
DecodeUtf16/macintosh/nonascii-1048576       910.1m ± 18%   1158.5m ± 10%  +27.29% (p=0.000 n=10)
DecodeUtf16/macintosh/web-1048576             2.470 ± 14%     2.811 ±  6%  +13.80% (p=0.004 n=10)
DecodeUtf8/windows-1251/invalid-16           557.4m ± 13%    601.6m ± 11%   +7.93% (p=0.035 n=10)
DecodeUtf8/windows-1251/nonascii-16          343.1m ± 16%    417.9m ± 11%  +21.82% (p=0.000 n=10)
DecodeUtf8/windows-1251/web-16               975.6m ± 13%    967.0m ± 21%        ~ (p=0.796 n=10)
DecodeUtf8/windows-1251/invalid-64           601.2m ± 19%    639.6m ± 20%        ~ (p=0.218 n=10)
DecodeUtf8/windows-1251/nonascii-64          424.6m ± 16%    613.7m ± 23%  +44.54% (p=0.000 n=10)
DecodeUtf8/windows-1251/web-64                3.797 ± 15%     3.901 ± 15%        ~ (p=0.436 n=10)
DecodeUtf8/windows-1251/invalid-256          613.2m ± 18%    650.7m ± 11%        ~ (p=0.165 n=10)
DecodeUtf8/windows-1251/nonascii-256         424.5m ±  9%    706.9m ± 15%  +66.53% (p=0.000 n=10)
DecodeUtf8/windows-1251/web-256               2.185 ±  6%     2.274 ±  8%        ~ (p=0.393 n=10)
DecodeUtf8/windows-1251/invalid-4096         473.6m ± 10%    524.4m ± 10%  +10.70% (p=0.000 n=10)
DecodeUtf8/windows-1251/nonascii-4096        438.6m ±  4%    684.2m ± 24%  +56.03% (p=0.000 n=10)
DecodeUtf8/windows-1251/web-4096             697.8m ±  2%    822.8m ±  9%  +17.90% (p=0.000 n=10)
DecodeUtf8/windows-1251/nonascii-1048576     432.3m ±  5%    714.4m ± 17%  +65.24% (p=0.001 n=10)
DecodeUtf8/windows-1251/web-1048576          348.9m ±  3%    392.4m ±  4%  +12.45% (p=0.000 n=10)
DecodeUtf16/windows-1251/invalid-16          697.1m ±  4%    823.5m ±  7%  +18.14% (p=0.000 n=10)
DecodeUtf16/windows-1251/nonascii-16         623.1m ±  8%    799.2m ±  5%  +28.26% (p=0.000 n=10)
DecodeUtf16/windows-1251/web-16               1.635 ± 10%     1.745 ±  5%   +6.71% (p=0.015 n=10)
DecodeUtf16/windows-1251/invalid-64          857.1m ± 20%   1136.6m ± 18%  +32.61% (p=0.000 n=10)
DecodeUtf16/windows-1251/nonascii-64         910.5m ± 13%   1166.8m ± 11%  +28.14% (p=0.000 n=10)
DecodeUtf16/windows-1251/web-64               5.969 ± 14%     5.812 ± 16%        ~ (p=0.853 n=10)
DecodeUtf16/windows-1251/invalid-256         843.7m ± 11%   1130.0m ±  7%  +33.93% (p=0.000 n=10)
DecodeUtf16/windows-1251/nonascii-256        912.5m ±  4%   1159.9m ±  7%  +27.11% (p=0.000 n=10)
DecodeUtf16/windows-1251/web-256              3.113 ±  3%     3.846 ± 13%  +23.52% (p=0.000 n=10)
DecodeUtf16/windows-1251/invalid-4096        818.6m ±  8%   1052.4m ±  4%  +28.56% (p=0.000 n=10)
DecodeUtf16/windows-1251/nonascii-4096       974.8m ±  8%   1209.4m ±  4%  +24.07% (p=0.000 n=10)
DecodeUtf16/windows-1251/web-4096             1.120 ±  9%     1.437 ±  9%  +28.34% (p=0.000 n=10)
DecodeUtf16/windows-1251/nonascii-1048576    930.4m ± 19%   1178.3m ± 10%  +26.65% (p=0.001 n=10)
DecodeUtf16/windows-1251/web-1048576         386.2m ± 15%    480.4m ± 17%  +24.36% (p=0.000 n=10)
DecodeUtf8/windows-1252/invalid-16           531.8m ±  4%    548.7m ±  5%        ~ (p=0.105 n=10)
DecodeUtf8/windows-1252/nonascii-16          328.3m ± 21%    420.2m ± 22%  +28.03% (p=0.007 n=10)
DecodeUtf8/windows-1252/web-16              1001.7m ± 18%    975.8m ± 19%        ~ (p=0.631 n=10)
DecodeUtf8/windows-1252/invalid-64           619.8m ± 18%    646.4m ± 14%        ~ (p=0.165 n=10)
DecodeUtf8/windows-1252/nonascii-64          418.1m ± 15%    625.8m ± 22%  +49.70% (p=0.000 n=10)
DecodeUtf8/windows-1252/web-64                3.654 ± 11%     3.772 ± 13%        ~ (p=0.315 n=10)
DecodeUtf8/windows-1252/invalid-256          614.1m ±  9%    658.2m ±  5%   +7.19% (p=0.023 n=10)
DecodeUtf8/windows-1252/nonascii-256         416.2m ± 16%    704.0m ±  6%  +69.14% (p=0.000 n=10)
DecodeUtf8/windows-1252/web-256               7.152 ± 14%     5.971 ± 20%  -16.51% (p=0.002 n=10)
DecodeUtf8/windows-1252/invalid-4096         520.1m ± 11%    528.9m ±  9%        ~ (p=0.971 n=10)
DecodeUtf8/windows-1252/nonascii-4096        438.6m ± 19%    705.9m ± 16%  +60.96% (p=0.000 n=10)
DecodeUtf8/windows-1252/web-4096              3.816 ± 17%     3.619 ± 18%        ~ (p=0.165 n=10)
DecodeUtf8/windows-1252/nonascii-1048576     437.3m ± 16%    739.1m ± 15%  +69.03% (p=0.000 n=10)
DecodeUtf8/windows-1252/web-1048576           1.627 ± 16%     1.627 ± 17%        ~ (p=0.631 n=10)
DecodeUtf16/windows-1252/invalid-16          714.2m ± 17%    801.0m ± 16%  +12.15% (p=0.043 n=10)
DecodeUtf16/windows-1252/nonascii-16         625.6m ± 21%    795.7m ± 33%        ~ (p=0.052 n=10)
DecodeUtf16/windows-1252/web-16               1.673 ± 18%     1.728 ± 18%        ~ (p=0.393 n=10)
DecodeUtf16/windows-1252/invalid-64          832.2m ± 16%   1082.0m ± 14%  +30.02% (p=0.000 n=10)
DecodeUtf16/windows-1252/nonascii-64         997.3m ± 19%   1100.5m ± 22%  +10.34% (p=0.000 n=10)
DecodeUtf16/windows-1252/web-64               5.725 ± 19%     6.209 ± 11%        ~ (p=1.000 n=10)
DecodeUtf16/windows-1252/invalid-256         836.4m ± 16%   1154.0m ± 13%  +37.96% (p=0.000 n=10)
DecodeUtf16/windows-1252/nonascii-256        919.0m ± 16%   1129.1m ± 16%  +22.86% (p=0.000 n=10)
DecodeUtf16/windows-1252/web-256              8.860 ± 13%    10.242 ± 14%  +15.59% (p=0.019 n=10)
DecodeUtf16/windows-1252/invalid-4096        811.2m ± 14%   1032.4m ± 17%  +27.27% (p=0.000 n=10)
DecodeUtf16/windows-1252/nonascii-4096       999.4m ± 15%   1245.0m ± 13%  +24.58% (p=0.000 n=10)
DecodeUtf16/windows-1252/web-4096             4.466 ± 11%     6.023 ± 12%  +34.88% (p=0.000 n=10)
DecodeUtf16/windows-1252/nonascii-1048576    972.1m ± 15%   1279.8m ±  9%  +31.66% (p=0.000 n=10)
DecodeUtf16/windows-1252/web-1048576          1.641 ± 15%     1.867 ± 14%  +13.75% (p=0.035 n=10)
geomean                                      938.1m           1.134        +20.89%
```
