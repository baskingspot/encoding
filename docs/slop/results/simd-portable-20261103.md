# Single-byte block lookup without AVX-512: pshufb, AVX2, and NEON, 2026-11-03

Wave 2b, portable SIMD. Intel(R) Xeon(R) Processor @ 2.60GHz (Ice
Lake-SP, AVX-512 with BW and VBMI), 4 vCPUs as 2 cores of 2 threads, in
an orb. Zig 0.16.0 ReleaseFast; encoding_rs 0.8.44 (`rust`), built as
the harness builds it. Every A/B is `just bench-compare`: each arm a
`bench-<arm> serve` process pinned to core 3, every arm timing each row
back to back in an order that rotates from row to row and round to round,
20 ms samples, after a sizing round, then benchstat. The arms:

- `base`, `basev3`, `basev2`, `basev1`: `bench-zig` from origin/main at
  `3422e84`, built with `-Dcpu=native` (AVX-512), `x86_64_v3` (AVX2),
  `x86_64_v2` (SSE4.2, so SSSE3), and `x86_64` (the baseline, SSE2).
- `zig`, `newv3`, `newv2`, `newv1`: this branch, the same four builds,
  measured before its rebase onto `2f8638a`, which adds detection and
  changes no single-byte code.
  The x86-64-v2 build takes the SSSE3 path; the baseline keeps the
  lane-by-lane patch.

All four builds run on the same Ice Lake machine, so `basev3` and
`newv3` are x86-64-v3 code on a CPU that also has AVX-512, not an AVX2-only
CPU.

Headlines:

1. Single-byte decode on x86-64-v3, over all 5,280 single-byte rows
   (section 4): 1.26x origin/main to UTF-16 and 1.19x to UTF-8 geomean,
   now 71% and 81% of the AVX-512 build (from 57% and 68%) and 2.73x and
   2.61x encoding_rs; dense non-ASCII text 2.39x and 1.82x. x86-64-v2
   (SSSE3) 1.17x and 1.11x. The cost: all-ASCII calls of 256 bytes or
   fewer to UTF-16 are 0.77-0.91x, 2 to 3 ns more a call (section 4.1).
2. The encoder's 128-entry search now ends in a mask and a bit scan
   instead of `std.simd.firstTrue`: single-byte encode 1.19x (from
   UTF-16) and 1.18x (from UTF-8) on x86-64-v3, 1.28x and 1.18x with
   AVX-512, 1.19x and 1.17x on the baseline. Rows below encoding_rs, of
   4,928: x86-64-v3 217 to 58, baseline 389 to 197, AVX-512 44 to 30.
3. The six encode rows below encoding_rs on x86-64-v3: five are now
   1.19x to 2.47x it; ISO-8859-14 `nonascii-16` from UTF-16 is 0.95x,
   from 0.57x (section 5).
4. Placement: across four placements of the codecs, the new x86-64-v3
   build's operation and shape geomeans move by at most 4.4% and the
   AVX-512 build's by 8.8%, against 33% for origin/main's x86-64-v3
   build (section 3).
5. Size: the byte shuffles read the table split into low and high bytes,
   256 bytes per encoding beside its table, 7,424 bytes for the 29
   tables in an x86-64-v3 or -v2 `Decoder`; the AVX-512 and baseline
   builds link none. Single-byte code +294 bytes on x86-64-v3, -613
   with AVX-512, -1,552 on the baseline (section 6).
6. NEON is checked for correctness only, under qemu (section 7): no
   speed is claimed for aarch64.

## 1. Change

### The lookup

`decodeBlock` looks a block of 16 bytes up whole when it holds a byte
from 0x80. On AVX-512BW it keeps its two `vpermi2w` over the table. On
other targets, chosen at compile time from the target's features
(`block_lookup`):

- AVX2: `vpshufb` looks 16 entries up by a byte's low four bits, and
  gives 0 where its bit 7 is set. The 128 entries are eight chunks of
  16; each chunk is stored as 32 bytes, its entries' low bytes and then
  their high bytes, so one `vpshufb` of the block broadcast to both
  halves looks a chunk up for both bytes of every lane. The index is the
  byte less 0x80, then 16 less for each next chunk: a byte has bit 7
  clear in chunks 0 to its own and set past it. Each chunk but the first
  is stored XORed with the one before it, so the XOR of the eight
  lookups is the byte's entry. Eight `vpshufb`, seven `vpxor`, seven
  `vpaddb`, and a `vpermq` and `vpshufb` to interleave the halves into
  16 units, with no select.
- SSSE3: the same with 16-byte `pshufb`, the low and high bytes apart:
  16 shuffles.
- NEON: `tbl` of four registers looks 64 entries up and gives 0 past
  them, `tbx` keeps the lane there: the low bytes are
  `tbx(tbl(lo[0..64], b - 0x80), lo[64..128], b - 0xC0)`, the high
  bytes the same (section 7). NEON reads the chunks without the XOR.
- Otherwise (the x86-64 baseline, other targets, other backends): the
  lane-by-lane patch as before.

The shuffles cost more than patching one or two lanes, so a block with
one or two bytes from 0x80, as in Latin text with the odd accented
letter, is patched lane by lane on these targets too. `vpermi2w` is
cheaper than the patch, and the AVX-512 build is unchanged (section 2).

The split tables are computed at compile time from the generated ones
(`planesOf`), 256 bytes per encoding, and the decoder holds a pointer to
them beside its table pointer; on the AVX-512 and baseline builds the
field is `void` and they are not linked.

### The encoder's search

`Encoder.search` compares a code point with all 128 entries and took
the first match with `std.simd.firstTrue`, which LLVM lowers to a select
of lane numbers and a minimum reduction: on AVX2, eight `vpcmpeqw` and
then some forty instructions in a dependency chain. It now bitcasts the
compare to a `u128` and counts its trailing zeros (leading zeros on a
big-endian target): eight compares, four packs and masks, and two bit
scans. Every target gains from it, AVX-512 included.

## 2. Variants

Each measured with an interleaved run of 360 rows: the 30 encodings,
decode to UTF-8 and UTF-16, and `web-16`, `nonascii-16`, `mixed-256`,
`csv-4096`, `web-65536`, and `nonascii-4096`, 3 rounds. Geomeans in
GB/s over each operation's 168 rows (the 28 encodings encoding_rs has).
`web-16` is all ASCII in every encoding: its spread is the noise and
placement of these runs.

First run: the lookup with a tree of selects on bits 4 to 6 of the
byte (`newv3`, `newv2`) against the base:

```
group                                  base   basev1   basev2   basev3    newv1    newv2    newv3     rust      zig
DecodeUtf16 (168)                     5.269    2.235    2.510    2.500    2.393    3.172    2.990    1.375    5.301
DecodeUtf8 (168)                      2.957    1.777    1.766    1.822    1.785    1.878    1.825    0.839    3.052
```

The tree is seven `vpblendvb` on AVX2, two micro-ops each on this CPU;
the SSE4.1 `pblendvb` of the x86-64-v2 build is one, so `newv2` beat
`newv3`. Second run: the XORed chunks (`foldv3`, `foldv2`), every
non-ASCII block looked up:

```
group                                  base   basev2   basev3   foldv2   foldv3    newv2    newv3     rust      zig
DecodeUtf16 (168)                     5.205    2.488    2.485    3.109    3.681    3.136    2.961    1.349    5.186
DecodeUtf8 (168)                      2.934    1.738    1.817    1.991    2.175    1.868    1.788    0.829    2.939
group                                  base   basev2   basev3   foldv2   foldv3    newv2    newv3     rust      zig
DecodeUtf16/csv-4096 (28)             9.280    5.272    5.465    4.899    6.014    4.874    4.530    2.321    9.414
DecodeUtf16/mixed-256 (28)            6.337    2.469    2.628    2.959    3.792    2.964    2.827    0.520    6.316
DecodeUtf16/nonascii-16 (28)          2.107    1.010    0.984    1.652    1.735    1.647    1.547    0.884    2.077
DecodeUtf16/nonascii-4096 (28)        7.289    1.579    1.475    3.332    4.247    3.352    3.025    2.438    7.347
DecodeUtf16/web-16 (28)               2.537    2.581    2.571    2.268    2.348    2.400    2.351    1.723    2.467
DecodeUtf16/web-65536 (28)            8.678    4.427    4.399    4.995    6.302    4.968    4.781    1.343    8.693
DecodeUtf8/csv-4096 (28)              4.641    3.327    3.299    2.956    3.352    2.416    2.203    1.579    4.730
DecodeUtf8/mixed-256 (28)             3.960    2.037    2.178    2.206    2.595    2.237    2.072    0.418    4.003
DecodeUtf8/nonascii-16 (28)           0.701    0.556    0.583    0.610    0.653    0.643    0.654    0.421    0.702
DecodeUtf8/nonascii-4096 (28)         4.306    1.178    1.185    2.157    2.459    2.187    2.015    0.673    4.359
DecodeUtf8/web-16 (28)                2.520    2.388    2.573    2.294    2.141    2.343    2.401    1.764    2.418
DecodeUtf8/web-65536 (28)             4.566    2.600    2.814    3.160    3.540    2.384    2.266    0.983    4.599
foldv3/basev3: 360 rows, geomean 1.317, <0.95: 117, <0.90: 101, >1.05: 231
  0.501 DecodeUtf8/windows-1254/csv-4096 2.984 5.960
  0.554 DecodeUtf16/windows-1254/csv-4096 5.592 10.100
  0.575 DecodeUtf16/windows-1257/csv-4096 8.127 14.123
  0.586 DecodeUtf16/ISO-8859-13/csv-4096 5.956 10.170
```

Dense text doubles, but Latin text with sparse accents (`csv`, `web`
in the Latin encodings) falls to half: there, a block with one byte from
0x80 cost the patch a load and a store, and costs the shuffles thirty
instructions. Third run: the patch where a block has at most two (`h2`)
or four (`h4`) bytes from 0x80, on x86-64-v3 and -v2 and, as `h2n` and
`h4n`, on AVX-512 too; and `pv3`, `h2` with the chunks not XORed, each
lookup made exact with a saturating add (`vpaddusb` of 0x70) and the
lookups ORed, one instruction more a chunk:

```
group                                  base   basev2   basev3   foldv2   foldv3      h2n     h2v2     h2v3      h4n     h4v2     h4v3      pv3     rust      zig
DecodeUtf16 (168)                     5.022    2.423    2.430    3.020    3.592    4.920    3.122    3.509    4.953    3.097    3.503    3.190    1.328    5.036
DecodeUtf8 (168)                      2.873    1.704    1.776    1.945    2.126    2.869    2.050    2.216    2.837    2.093    2.211    2.090    0.813    2.874
group                                  base   basev2   basev3   foldv2   foldv3      h2n     h2v2     h2v3      h4n     h4v2     h4v3      pv3     rust      zig
DecodeUtf16/csv-4096 (28)             8.925    5.159    5.306    4.726    5.974    9.176    5.374    6.403    8.941    5.445    6.468    5.785    2.284    9.113
DecodeUtf16/mixed-256 (28)            6.089    2.424    2.569    2.913    3.686    5.732    2.837    3.497    5.820    2.787    3.472    3.006    0.521    6.200
DecodeUtf16/nonascii-16 (28)          2.061    0.971    0.973    1.598    1.699    1.935    1.583    1.521    1.991    1.568    1.495    1.428    0.883    2.038
DecodeUtf16/nonascii-4096 (28)        7.345    1.495    1.461    3.175    4.201    6.523    3.110    4.038    6.742    3.097    4.067    3.289    2.428    7.285
DecodeUtf16/web-16 (28)               2.396    2.511    2.510    2.196    2.276    2.222    2.230    2.002    2.269    2.266    1.991    1.986    1.662    2.374
DecodeUtf16/web-65536 (28)            8.135    4.439    4.230    4.947    5.999    9.612    5.530    6.779    9.316    5.288    6.800    6.504    1.295    8.193
DecodeUtf8/csv-4096 (28)              4.602    3.250    3.251    2.883    3.239    4.880    3.366    3.817    4.723    3.553    3.881    3.580    1.543    4.619
DecodeUtf8/mixed-256 (28)             3.821    1.992    2.109    2.146    2.525    3.549    2.142    2.496    3.538    2.146    2.461    2.230    0.407    3.817
DecodeUtf8/nonascii-16 (28)           0.710    0.543    0.583    0.606    0.644    0.704    0.632    0.643    0.701    0.640    0.638    0.630    0.417    0.696
DecodeUtf8/nonascii-4096 (28)         4.188    1.192    1.185    2.114    2.463    3.837    2.076    2.461    3.822    2.100    2.448    2.201    0.665    4.279
DecodeUtf8/web-16 (28)                2.465    2.311    2.482    2.217    2.087    2.383    2.277    2.019    2.396    2.289    2.006    2.027    1.733    2.405
DecodeUtf8/web-65536 (28)             4.360    2.533    2.668    3.080    3.413    5.006    3.444    3.893    4.863    3.584    3.898    3.717    0.956    4.466
h2v3/basev3: 360 rows, geomean 1.330, <0.95: 101, <0.90: 85, >1.05: 240
pv3/h2v3: 360 rows, geomean 0.928, <0.95: 212, <0.90: 148, >1.05: 35
h2v2/basev2: 360 rows, geomean 1.235, <0.95: 86, <0.90: 70, >1.05: 236
h2n/base: 360 rows, geomean 0.992, <0.95: 149, <0.90: 79, >1.05: 107
h4n/base: 360 rows, geomean 0.990, <0.95: 147, <0.90: 71, >1.05: 96
zig/base: 360 rows, geomean 1.000, <0.95: 46, <0.90: 17, >1.05: 52
```

Taken: the XORed chunks, with the patch at two bytes or fewer, on
SSSE3, AVX2, and NEON (`h2`). The patch gives back the sparse rows
(`csv-4096` to UTF-16 6.40 GB/s against `basev3`'s 5.31 and `foldv3`'s
5.97) and keeps the dense ones; two and four measured the same. Not
taken:

- The patch on AVX-512 (`h2n`, `h4n`): 0.99x `base` geomean,
  `web-65536` faster and `nonascii` slower; the AVX-512 build stays as
  it was.
- The chunks not XORed (`pv3`): 0.93x geomean against `h2v3`, but
  plain low and high bytes could replace the table itself on these
  targets, the encoder searching them and the last bytes of a call
  reading two bytes for one, so the split would cost no bytes at all.
  This is a decision for the owner (section 8).
- The tree of selects: two micro-ops a select on AVX2.

## 3. Placement

The method of single-byte-20261102.md section 1: four placements of each
build, `bench-<arm>` built with a never-executed `jmp 1f; .skip N, 0xcc;
1:` at the top of `arm.row` in a scratch copy of bench/zig/arm.zig, N =
0, 16, 32, 48, which moves `single_byte.Decoder.decode` and
`single_byte.Encoder.encode` through the four 16-byte offsets in a
64-byte line (checked with `nm` on each binary). `bv3_N` is origin/main
built for x86-64-v3, `nv3_N` this branch for x86-64-v3, `nn_N` this
branch native (AVX-512), and `nv3_0dup` a copy of `nv3_0`. The 30
encodings, the four operations, and `web-65536`, `csv-4096`,
`mixed-256`, `nonascii-16`, 480 rows, 5 rounds, nothing else running:

```
BENCHTIME_MS=20 just arms="rust zig bv3_0 bv3_16 bv3_32 bv3_48 nv3_0 nv3_16 nv3_32 nv3_48 nv3_0dup nn_0 nn_16 nn_32 nn_48" bench-compare 5 '^(DecodeUtf8|DecodeUtf16|EncodeUtf8|EncodeUtf16)/(<the 30>)/(web-65536|csv-4096|mixed-256|nonascii-16)$'
```

A row's spread is its fastest placement's median over its slowest's;
per operation and shape, the 30 encodings' geomean at each placement
(0, 16, 32, 48), its spread, and placement 0 over encoding_rs:

```
arms                          median     p90     max  >1.10  >1.20
base v3 (bv3_0..48)            1.064   1.226    2.01    156     62
new v3 (nv3_0..48)             1.043   1.151    1.35     90     26
new AVX-512 (nn_0..48)         1.050   1.164    1.38    119     31
noise (nv3_0 nv3_0dup)         1.025   1.094    1.32     44     12
480 rows

base v3 (bv3_0..48)
  DecodeUtf16/csv-4096         4.561   5.011   5.628   5.579  spread 1.234  /rust 1.90
  DecodeUtf16/mixed-256        2.691   2.634   2.713   2.512  spread 1.080  /rust 5.30
  DecodeUtf16/nonascii-16      0.923   0.956   0.951   0.949  spread 1.036  /rust 1.07
  DecodeUtf16/web-65536        3.489   4.161   4.452   4.632  spread 1.327  /rust 2.45
  DecodeUtf8/csv-4096          3.492   3.385   3.322   3.327  spread 1.051  /rust 2.18
  DecodeUtf8/mixed-256         1.979   2.032   2.105   2.113  spread 1.068  /rust 4.93
  DecodeUtf8/nonascii-16       0.568   0.557   0.559   0.569  spread 1.021  /rust 1.39
  DecodeUtf8/web-65536         3.003   2.875   2.585   2.733  spread 1.161  /rust 3.02
  EncodeUtf16/csv-4096         5.378   5.433   5.472   5.449  spread 1.018  /rust 3.30
  EncodeUtf16/mixed-256        1.866   1.865   1.871   1.856  spread 1.008  /rust 4.86
  EncodeUtf16/nonascii-16      0.849   0.859   0.856   0.855  spread 1.011  /rust 2.97
  EncodeUtf16/web-65536        5.914   5.975   5.917   5.894  spread 1.014  /rust 5.74
  EncodeUtf8/csv-4096          1.945   1.913   1.910   1.925  spread 1.018  /rust 2.81
  EncodeUtf8/mixed-256         0.797   0.786   0.776   0.783  spread 1.026  /rust 2.46
  EncodeUtf8/nonascii-16       0.374   0.379   0.373   0.378  spread 1.018  /rust 2.01
  EncodeUtf8/web-65536         1.928   1.886   1.930   1.915  spread 1.023  /rust 3.70
new v3 (nv3_0..48)
  DecodeUtf16/csv-4096         6.556   6.536   6.543   6.588  spread 1.008  /rust 2.78
  DecodeUtf16/mixed-256        3.390   3.372   3.421   3.384  spread 1.014  /rust 6.69
  DecodeUtf16/nonascii-16      1.483   1.458   1.459   1.487  spread 1.020  /rust 1.73
  DecodeUtf16/web-65536        7.264   7.068   7.053   7.185  spread 1.030  /rust 5.30
  DecodeUtf8/csv-4096          3.739   3.835   3.830   3.848  spread 1.029  /rust 2.38
  DecodeUtf8/mixed-256         2.472   2.411   2.435   2.466  spread 1.025  /rust 6.15
  DecodeUtf8/nonascii-16       0.618   0.624   0.617   0.621  spread 1.010  /rust 1.51
  DecodeUtf8/web-65536         3.680   3.789   3.788   3.789  spread 1.030  /rust 3.81
  EncodeUtf16/csv-4096         6.892   6.959   6.880   6.833  spread 1.018  /rust 4.21
  EncodeUtf16/mixed-256        2.538   2.574   2.581   2.568  spread 1.017  /rust 6.49
  EncodeUtf16/nonascii-16      1.165   1.170   1.170   1.176  spread 1.009  /rust 4.00
  EncodeUtf16/web-65536        7.284   6.984   7.293   7.006  spread 1.044  /rust 7.03
  EncodeUtf8/csv-4096          2.297   2.297   2.266   2.304  spread 1.017  /rust 3.31
  EncodeUtf8/mixed-256         1.018   1.020   1.014   1.007  spread 1.013  /rust 3.09
  EncodeUtf8/nonascii-16       0.484   0.497   0.483   0.483  spread 1.030  /rust 2.61
  EncodeUtf8/web-65536         2.210   2.223   2.202   2.225  spread 1.010  /rust 4.23
new AVX-512 (nn_0..48)
  DecodeUtf16/csv-4096         9.039   9.092   9.027   9.106  spread 1.009  /rust 3.94
  DecodeUtf16/mixed-256        5.996   6.018   5.903   6.039  spread 1.023  /rust 11.81
  DecodeUtf16/nonascii-16      1.976   2.001   1.977   1.975  spread 1.013  /rust 2.30
  DecodeUtf16/web-65536        8.504   8.531   8.510   8.659  spread 1.018  /rust 6.31
  DecodeUtf8/csv-4096          4.499   4.494   4.507   4.472  spread 1.008  /rust 2.94
  DecodeUtf8/mixed-256         3.725   3.719   3.793   3.757  spread 1.020  /rust 9.26
  DecodeUtf8/nonascii-16       0.685   0.684   0.685   0.693  spread 1.014  /rust 1.67
  DecodeUtf8/web-65536         4.428   4.382   4.425   4.406  spread 1.010  /rust 4.69
  EncodeUtf16/csv-4096        10.150  10.020  10.142  10.083  spread 1.013  /rust 6.17
  EncodeUtf16/mixed-256        3.813   3.798   3.902   3.865  spread 1.027  /rust 9.72
  EncodeUtf16/nonascii-16      1.604   1.591   1.588   1.606  spread 1.011  /rust 5.45
  EncodeUtf16/web-65536        9.663  10.475   9.776  10.513  spread 1.088  /rust 9.22
  EncodeUtf8/csv-4096          2.907   2.904   2.866   2.875  spread 1.014  /rust 4.21
  EncodeUtf8/mixed-256         1.394   1.403   1.391   1.413  spread 1.016  /rust 4.21
  EncodeUtf8/nonascii-16       0.618   0.590   0.579   0.595  spread 1.067  /rust 3.30
  EncodeUtf8/web-65536         2.739   2.811   2.739   2.792  spread 1.026  /rust 5.26
  EncodeUtf16/windows-1250/web-65536           1.350 noise 1.142  3.357 2.838 3.005 2.487
  EncodeUtf8/windows-1255/nonascii-16          1.318 noise 1.035  0.616 0.657 0.651 0.498
  EncodeUtf16/windows-1252/web-65536           1.299 noise 1.317  20.858 26.682 26.467 27.087
  DecodeUtf8/IBM850/web-65536                  1.286 noise 1.172  5.585 6.992 7.182 5.638
  DecodeUtf16/ISO-8859-8/nonascii-16           1.274 noise 1.220  1.629 1.340 1.339 1.705
  DecodeUtf16/ISO-8859-8/mixed-256             1.273 noise 1.010  3.891 3.062 3.898 3.891
  DecodeUtf8/ISO-8859-8/web-65536              1.260 noise 1.217  2.458 2.499 2.750 3.096
  EncodeUtf8/windows-874/nonascii-16           1.255 noise 1.006  0.691 0.852 0.867 0.752
  EncodeUtf16/windows-1254/web-65536           1.249 noise 1.041  4.560 3.851 4.357 3.650
  EncodeUtf16/ISO-8859-5/nonascii-16           1.249 noise 1.228  4.077 4.114 4.051 3.295
```

The new x86-64-v3 build's operation and shape geomeans move by 0.8% to
4.4% across placements, the AVX-512 build's by 0.8% to 8.8% (`EncodeUtf16/web-65536`; single
rows differ by up to 1.32x between the two copies of one binary); origin/main's x86-64-v3 build moved by up to 33%
(`DecodeUtf16/web-65536`), its `vpermi2w`-less decode loop being
sensitive to where it lands. Over all four placements, `nv3` against
`bv3`: decode 1.47x (to UTF-16) and 1.20x (to UTF-8), encode 1.29x and
1.23x; to UTF-16 at 0.70x the AVX-512 build and 3.59x encoding_rs on
these rows.

An earlier placement run, with the gates running on the other core, had
a noise line (`nv3_0` against its copy) of 1.048 median and 2.16 max,
too noisy to read; it is not used.

## 4. The full run

Every single-byte row: the 30 encodings, both directions to and from
UTF-8 and UTF-16, 8 shapes, sizes 16 bytes to 64 KiB (and 1 MiB for 4
shapes), 5,280 rows, 3 rounds, nine arms (`rust` and the eight builds
above). Gates ran on CPUs 0 and 1 during part of the run, the arms on
CPU 3; the rows are interleaved, so this costs every arm alike but widens
single rows: `zig`/`base` has 417 rows below 0.90 although their
decoders are the same code. Read the geomeans. GB/s geomean over the
4,928 rows encoding_rs has (1,232 an operation); `v3/bv3` is `newv3` over
`basev3`, `v3/512` over `zig`, `v3/rust` over `rust`:

```
group                           rows    rust    base     zig  basev3   newv3  basev2   newv2  basev1   newv1  v3/bv3 v3/512 v3/rust  v2/bv2 v1/bv1 v1/rust 512/b
DecodeUtf16                     1232   1.445   5.473   5.521   3.134   3.942   3.082   3.608   2.776   3.062    1.26   0.71    2.73    1.17   1.10    2.12  1.01
DecodeUtf8                      1232   1.085   3.503   3.511   2.379   2.833   2.329   2.585   2.335   2.365    1.19   0.81    2.61    1.11   1.01    2.18  1.00
EncodeUtf16                     1232   1.093   4.336   5.547   3.463   4.128   2.779   3.125   2.545   3.026    1.19   0.74    3.78    1.12   1.19    2.77  1.28
EncodeUtf8                      1232   0.598   1.851   2.177   1.567   1.843   1.460   1.600   1.339   1.570    1.18   0.85    3.08    1.10   1.17    2.63  1.18
```

- x86-64-v3 decode: 1.26x (to UTF-16) and 1.19x (to UTF-8) `basev3`,
  now 71% and 81% of the AVX-512 build, from 57% and 68% in this run,
  and 2.73x and 2.61x encoding_rs. Dense text gains most: `nonascii`
  2.39x and 1.82x, and by size 1.64x and 1.45x at 64 KiB.
- x86-64-v2 (SSSE3): 1.17x and 1.11x.
- Baseline decode takes the lane-by-lane patch as before, so its 1.10x
  to UTF-16 (1.03-1.16x in every shape, 1.01x to UTF-8) is not the
  lookup; it is not isolated here, between placement and the code LLVM
  now emits around the same loop.
- Encode, from the search alone: 1.19x and 1.18x on x86-64-v3, 1.28x
  and 1.18x with AVX-512, 1.12x and 1.10x on -v2, 1.19x and 1.17x on the
  baseline. `ascii` is unchanged (0.98-1.03x): it never searches.
- Rows below encoding_rs, of 4,928: `basev3` 217, `newv3` 58; `basev2`
  262, `newv2` 74; `basev1` 389, `newv1` 197; `base` 44, `zig` 30.

What it costs: short all-ASCII decode on x86-64-v3 and -v2 (section
4.1). The per-shape and per-size groups:

```
group                           rows    rust    base     zig  basev3   newv3  basev2   newv2  basev1   newv1  v3/bv3 v3/512 v3/rust  v2/bv2 v1/bv1 v1/rust 512/b
DecodeUtf16/ascii                168   5.236  10.582  10.737  10.640   9.623  10.096   9.429   9.650   9.923    0.90   0.90    1.84    0.93   1.03    1.90  1.01
DecodeUtf16/csv                  140   1.758   5.053   5.059   3.556   3.884   3.507   3.679   3.037   3.466    1.09   0.77    2.21    1.05   1.14    1.97  1.00
DecodeUtf16/invalid              140   0.463   3.922   3.923   1.720   2.405   1.654   2.120   1.451   1.682    1.40   0.61    5.20    1.28   1.16    3.63  1.00
DecodeUtf16/mail                 140   2.125   6.369   6.559   4.640   4.890   4.488   4.612   3.988   4.470    1.05   0.75    2.30    1.03   1.12    2.10  1.03
DecodeUtf16/mixed                168   0.426   4.344   4.320   1.984   2.569   1.924   2.196   1.721   1.931    1.29   0.59    6.03    1.14   1.12    4.54  0.99
DecodeUtf16/nonascii             168   1.468   4.327   4.247   1.095   2.613   1.142   2.212   1.075   1.139    2.39   0.62    1.78    1.94   1.06    0.78  0.98
DecodeUtf16/subtitles            140   1.674   5.216   5.412   3.549   4.198   3.565   3.962   3.089   3.495    1.18   0.78    2.51    1.11   1.13    2.09  1.04
DecodeUtf16/web                  168   1.872   5.839   5.942   4.024   4.527   3.977   4.277   3.577   3.906    1.12   0.76    2.42    1.08   1.09    2.09  1.02
DecodeUtf8/ascii                 168   5.889  13.294  13.294  13.484  12.876  13.151  12.605  13.279  13.390    0.95   0.97    2.19    0.96   1.01    2.27  1.00
DecodeUtf8/csv                   140   1.413   3.220   3.254   2.488   2.804   2.453   2.529   2.388   2.438    1.13   0.86    1.98    1.03   1.02    1.73  1.01
DecodeUtf8/invalid               140   0.377   1.785   1.787   1.015   1.251   0.979   1.147   0.996   1.005    1.23   0.70    3.32    1.17   1.01    2.66  1.00
DecodeUtf8/mail                  140   1.835   4.089   4.219   3.502   3.845   3.377   3.467   3.401   3.467    1.10   0.91    2.10    1.03   1.02    1.89  1.03
DecodeUtf8/mixed                 168   0.324   2.277   2.244   1.315   1.533   1.299   1.355   1.312   1.319    1.17   0.68    4.73    1.04   1.01    4.07  0.99
DecodeUtf8/nonascii              168   0.484   2.256   2.232   0.832   1.515   0.835   1.324   0.841   0.844    1.82   0.68    3.13    1.59   1.00    1.74  0.99
DecodeUtf8/subtitles             140   1.297   3.213   3.203   2.509   2.852   2.421   2.628   2.434   2.472    1.14   0.89    2.20    1.09   1.02    1.91  1.00
DecodeUtf8/web                   168   1.611   3.920   3.953   2.951   3.307   2.886   3.051   2.856   2.925    1.12   0.84    2.05    1.06   1.02    1.82  1.01
EncodeUtf16/ascii                168   9.214  20.222  20.585  18.934  18.561  16.734  16.434  15.246  14.992    0.98   0.90    2.01    0.98   0.98    1.63  1.02
EncodeUtf16/csv                  140   1.729   5.919   7.200   4.702   5.341   3.718   4.088   3.465   3.893    1.14   0.74    3.09    1.10   1.12    2.25  1.22
EncodeUtf16/invalid              140   0.148   0.832   1.348   0.603   0.880   0.482   0.611   0.418   0.617    1.46   0.65    5.96    1.27   1.48    4.18  1.62
EncodeUtf16/mail                 140   2.407   7.944   9.389   6.680   7.315   5.345   5.773   5.028   5.560    1.10   0.78    3.04    1.08   1.11    2.31  1.18
EncodeUtf16/mixed                168   0.317   2.171   3.074   1.590   2.133   1.240   1.481   1.120   1.458    1.34   0.69    6.73    1.19   1.30    4.60  1.42
EncodeUtf16/nonascii             168   0.316   1.546   2.364   1.118   1.572   0.857   1.075   0.772   1.066    1.41   0.67    4.97    1.25   1.38    3.37  1.53
EncodeUtf16/subtitles            140   1.626   6.101   7.403   4.940   5.568   3.962   4.275   3.646   4.132    1.13   0.75    3.43    1.08   1.13    2.54  1.21
EncodeUtf16/web                  168   2.086   7.220   8.399   6.112   6.600   4.893   5.244   4.662   5.101    1.08   0.79    3.16    1.07   1.09    2.45  1.16
EncodeUtf8/ascii                 168   5.845  11.110  11.094  11.038  11.378  11.329  11.125  11.080  11.524    1.03   1.03    1.95    0.98   1.04    1.97  1.00
EncodeUtf8/csv                   140   0.759   2.062   2.295   1.764   2.020   1.692   1.802   1.545   1.755    1.15   0.88    2.66    1.07   1.14    2.31  1.11
EncodeUtf8/invalid               140   0.122   0.523   0.739   0.397   0.539   0.342   0.417   0.309   0.412    1.36   0.73    4.41    1.22   1.33    3.37  1.41
EncodeUtf8/mail                  140   1.122   2.956   3.184   2.625   2.988   2.530   2.632   2.351   2.627    1.14   0.94    2.66    1.04   1.12    2.34  1.08
EncodeUtf8/mixed                 168   0.234   0.789   1.001   0.618   0.759   0.545   0.637   0.486   0.609    1.23   0.76    3.24    1.17   1.25    2.60  1.27
EncodeUtf8/nonascii              168   0.145   0.783   1.111   0.617   0.807   0.535   0.642   0.464   0.614    1.31   0.73    5.59    1.20   1.32    4.25  1.42
EncodeUtf8/subtitles             140   0.729   2.084   2.307   1.769   1.979   1.666   1.765   1.535   1.719    1.12   0.86    2.71    1.06   1.12    2.36  1.11
EncodeUtf8/web                   168   0.994   2.745   2.971   2.403   2.693   2.309   2.430   2.171   2.372    1.12   0.91    2.71    1.05   1.09    2.39  1.08
DecodeUtf16/16                   224   1.019   1.905   1.914   1.608   1.502   1.653   1.630   1.470   1.656    0.93   0.78    1.47    0.99   1.13    1.63  1.00
DecodeUtf16/64                   224   1.700   4.941   4.996   3.367   3.609   3.351   3.567   2.940   3.361    1.07   0.72    2.12    1.06   1.14    1.98  1.01
DecodeUtf16/256                  224   1.866   7.653   7.757   4.361   5.520   4.289   4.952   3.864   4.201    1.27   0.71    2.96    1.15   1.09    2.25  1.01
DecodeUtf16/4096                 224   1.750   8.460   8.503   4.248   5.828   4.013   4.797   3.601   3.983    1.37   0.69    3.33    1.20   1.11    2.28  1.01
DecodeUtf16/65536                224   1.115   7.767   7.853   3.370   5.531   3.236   4.567   2.950   3.184    1.64   0.70    4.96    1.41   1.08    2.86  1.01
DecodeUtf16/1048576              112   1.438   5.892   5.927   2.506   3.835   2.508   3.395   2.394   2.518    1.53   0.65    2.67    1.35   1.05    1.75  1.01
DecodeUtf8/16                    224   0.861   1.230   1.234   1.201   1.158   1.127   1.129   1.188   1.168    0.96   0.94    1.35    1.00   0.98    1.36  1.00
DecodeUtf8/64                    224   1.460   3.415   3.468   2.778   2.940   2.621   2.640   2.595   2.626    1.06   0.85    2.01    1.01   1.01    1.80  1.02
DecodeUtf8/256                   224   1.355   4.804   4.852   3.268   3.906   3.208   3.568   3.173   3.242    1.20   0.81    2.88    1.11   1.02    2.39  1.01
DecodeUtf8/4096                  224   1.170   4.865   4.853   2.959   3.724   2.968   3.248   2.912   2.961    1.26   0.77    3.18    1.09   1.02    2.53  1.00
DecodeUtf8/65536                 224   0.770   4.528   4.509   2.351   3.399   2.370   3.070   2.357   2.432    1.45   0.75    4.41    1.30   1.03    3.16  1.00
DecodeUtf8/1048576               112   1.040   4.928   4.841   2.404   3.325   2.457   3.055   2.495   2.527    1.38   0.69    3.20    1.24   1.01    2.43  0.98
EncodeUtf16/16                   224   1.048   2.490   2.775   2.136   2.264   1.849   1.926   1.843   1.948    1.06   0.82    2.16    1.04   1.06    1.86  1.11
EncodeUtf16/64                   224   1.543   4.627   5.759   3.916   4.474   3.232   3.540   3.026   3.488    1.14   0.78    2.90    1.10   1.15    2.26  1.24
EncodeUtf16/256                  224   1.401   5.794   7.791   4.495   5.528   3.512   4.069   3.138   3.887    1.23   0.71    3.94    1.16   1.24    2.77  1.34
EncodeUtf16/4096                 224   1.019   5.136   7.062   3.821   4.895   2.912   3.410   2.555   3.227    1.28   0.69    4.81    1.17   1.26    3.17  1.38
EncodeUtf16/65536                224   0.744   4.758   6.400   3.673   4.584   2.863   3.327   2.527   3.151    1.25   0.72    6.16    1.16   1.25    4.23  1.35
EncodeUtf16/1048576              112   0.904   3.825   4.834   3.082   3.756   2.493   2.802   2.273   2.705    1.22   0.78    4.16    1.12   1.19    2.99  1.26
EncodeUtf8/16                    224   0.611   1.188   1.243   1.060   1.184   1.078   1.105   1.031   1.162    1.12   0.95    1.94    1.03   1.13    1.90  1.05
EncodeUtf8/64                    224   0.885   2.143   2.418   1.864   2.177   1.796   1.849   1.622   1.931    1.17   0.90    2.46    1.03   1.19    2.18  1.13
EncodeUtf8/256                   224   0.693   2.302   2.793   1.880   2.287   1.707   1.941   1.570   1.864    1.22   0.82    3.30    1.14   1.19    2.69  1.21
EncodeUtf8/4096                  224   0.513   1.969   2.446   1.602   1.947   1.441   1.638   1.287   1.545    1.22   0.80    3.79    1.14   1.20    3.01  1.24
EncodeUtf8/65536                 224   0.413   1.790   2.230   1.502   1.765   1.336   1.534   1.220   1.433    1.17   0.79    4.27    1.15   1.17    3.47  1.25
EncodeUtf8/1048576               112   0.550   2.047   2.476   1.754   2.034   1.587   1.766   1.467   1.672    1.16   0.82    3.70    1.11   1.14    3.04  1.21
```

### 4.1 Short all-ASCII decode

`DecodeUtf16` at 16 bytes is 0.93x `basev3` and `ascii` 0.90x. All-ASCII
input to UTF-16, `newv3` over `basev3` (and `newv2` over `basev2`), the
30 encodings' geomean in the full run:

```
bytes        16     64    256   4096  65536    1 MiB
to UTF-16  0.79   0.77   0.91   0.98   1.00   1.00     (-v2: 0.86 0.85 0.92 0.96 1.03 1.00)
to UTF-8   0.89   0.91   0.89   1.01   1.01   1.02     (-v2: 1.00 0.86 0.97 0.95 1.01 0.97)
```

That is 2 to 3 ns more a call (`ascii-64` to UTF-16 12.1 ns against
9.3), paid once a call and gone by 4 KiB. Three variants, 360 and 120
rows of 16- and 64-byte inputs, 5 rounds:

- `e1v3`: this branch with the block lookup taken out (the search
  change kept): `ascii-16` the same as `basev3`. So the cost is in the
  decoder, not the encoder or the bench.
- `e4v3`: `basev3` with 8 bytes of padding in `Decoder`, the size this
  branch's planes pointer adds: 0.97x. Not the struct's size.
- `e5v3` and `fv3`: the decoder split into an ASCII and a non-ASCII loop
  with the lookup kept but never reached, and two inline loops: as slow
  as `newv3`.

So the decode function's shape costs it, the lookup's eight table
registers and the code around the loop, not work done on ASCII. It is
the same at every placement (section 3). `newv3` `ascii-16` is still
1.16x encoding_rs (2.19 against 1.88 GB/s in the 120-row run). Not
fixed here; a follow-up could put the lookup out of line behind a
pointer to the whole remainder of the call, which `dv3` tried with a
`noinline` call and lost `nonascii-16` to a stalled store forward.

```
group                        rows    rust  basev3    e1v3    e4v3   newv3
DecodeUtf16/ascii-16           28   1.567   2.305   2.320   2.235   1.838
DecodeUtf16/mixed-64           28   0.511   2.178   2.175   2.085   2.731
DecodeUtf16/nonascii-16        28   0.824   0.907   0.891   0.849   1.391
DecodeUtf16/web-16             28   1.592   2.305   2.337   2.231   1.832
DecodeUtf8/ascii-16            28   1.574   2.298   2.273   2.251   2.133
DecodeUtf8/mixed-64            28   0.396   1.567   1.515   1.551   1.632
DecodeUtf8/nonascii-16         28   0.385   0.526   0.519   0.516   0.604
DecodeUtf8/web-16              28   1.628   2.331   2.287   2.302   2.155
EncodeUtf16/ascii-16           28   2.722   4.394   3.956   4.377   3.974
EncodeUtf16/mixed-64           28   0.404   1.710   2.275   1.697   2.287
EncodeUtf16/nonascii-16        28   0.299   0.872   1.169   0.876   1.172
EncodeUtf16/web-16             28   2.709   4.420   3.974   4.404   3.992
group                        rows    rust  basev3    e1v3    e5v3     fv3   newv3
DecodeUtf16/ascii-16           28   1.880   2.751   2.751   2.296   2.298   2.192
DecodeUtf16/web-16             28   1.862   2.738   2.746   2.277   2.268   2.176
DecodeUtf8/ascii-16            28   1.901   2.735   2.699   2.353   2.343   2.531
DecodeUtf8/web-16              28   1.929   2.768   2.719   2.363   2.336   2.529
```

The first run also shows `EncodeUtf16` `ascii-16` at 0.90x with the new
search (`e1v3` and `newv3` alike), where the full run has the 16-byte
`ascii` encode rows at 0.98x: a call that searches nothing pays for the
search's code around it, by a nanosecond at most.

## 5. The six encode rows

The six rows that fell below encoding_rs on x86-64-v3 in
single-byte-20261102.md section 9, from the full run (GB/s, median of 3):

```
row                                       rust  basev3   newv3    base     zig  basev2   newv2  basev1   newv1  bv3/rs  nv3/rs
EncodeUtf16/ISO-8859-10/nonascii-16      0.252   0.243   0.383   0.356   0.694   0.184   0.264   0.159   0.294    0.97    1.52
EncodeUtf16/ISO-8859-13/nonascii-16      0.176   0.246   0.435   0.360   0.674   0.193   0.287   0.165   0.286    1.40    2.47
EncodeUtf16/ISO-8859-14/nonascii-16      0.518   0.293   0.494   0.398   0.841   0.231   0.323   0.211   0.392    0.57    0.95
EncodeUtf8/ISO-8859-13/csv-4096          0.854   1.213   1.310   1.401   1.286   0.925   0.803   0.594   0.751    1.42    1.53
EncodeUtf8/ISO-8859-13/mixed-256         0.369   0.319   0.495   0.494   0.855   0.257   0.409   0.252   0.385    0.86    1.34
EncodeUtf8/windows-1254/csv-4096         1.037   0.946   1.239   1.284   1.729   0.834   0.975   0.728   0.904    0.91    1.19
```

Five are now above encoding_rs on x86-64-v3, from 1.19x to 2.47x.
ISO-8859-14 `nonascii-16` is 0.95x, from 0.57x in this run (0.66x in
the earlier one): encoding_rs encodes that row at twice the speed it
encodes the other Latin encodings' (0.52 against 0.18-0.25 GB/s), and
the AVX-512 build is 1.62x it.

## 6. Size

`size -A` of each `bench-zig`, which links every encoding, and the
single-byte functions' code (`single_byte.*` and `codec.encodeStaged`,
`nm -S`):

```
build              .text    .rodata   single-byte code   single-byte tables
base-native        555673   420582    7764               7424
new-native         555049   419998    7151               7424
base-x86_64_v3     569977   496528    8939               7424
new-x86_64_v3      570505   504336    9233               14848
base-x86_64_v2     575081   542276    11275              7424
new-x86_64_v2      574953   550004    11171              14848
base-x86_64        587321   542122    11908              7424
new-x86_64         585769   541994    10356              7424
```

On x86-64-v3 the decoder's two copies (to UTF-8 and UTF-16) grew from
2,099 to 2,965 bytes and the encoder's from 3,691 to 3,322, with
`encodeStaged` 3,149 to 2,946: the search is shorter. The split tables
are named `single_byte.planesOf__struct_N.p`; `just bench-rodata`
counts the generated tables by their bytes and does not see them.

The programs of bench/comptime/size.zig (`zig build sizes`), each net
of the program that links no encoding, in bytes: `ct_1252` is
`DecoderFor(&.{.windows_1252})`, `rt_1252` and `rt_label` the whole
`Decoder`, `rt_enc_label` the whole `Encoder`, `ct_enc_1252`
`EncoderFor(&.{.windows_1252})`:

```
== ReleaseSmall: .rodata and .text of each program net of size-none (bench/comptime/size.zig)
cpu                    program      base-ro    new-ro base-text  new-text
native                 ct_1252         1049      1049      5781      5781
native                 rt_1252       178639    178639     34896     34896
native                 rt_label      186250    186250     35245     35245
native                 rt_enc_label    168472    167960     19965     19618
native                 ct_enc_1252      2095      1775      6036      5711
x86_64_v3              ct_1252        50700     51012     11740     12250
x86_64_v3              rt_1252       227082    234882     47371     48015
x86_64_v3              rt_label      234677    242477     47725     48376
x86_64_v3              rt_enc_label    219919    219823     30937     30580
x86_64_v3              ct_enc_1252     54434     54338     13922     13565
x86_64_v2              ct_1252        72340     72788     16312     16834
x86_64_v2              rt_1252       248898    256746     62461     63067
x86_64_v2              rt_label      256493    264341     62754     63286
x86_64_v2              rt_enc_label    245275    245147     43323     42501
x86_64_v2              ct_enc_1252     79690     79562     20774     19952
x86_64                 ct_1252        72550     72550     17350     17350
x86_64                 rt_1252       249140    249140     66413     66413
x86_64                 rt_label      256735    256735     66706     66706
x86_64                 rt_enc_label    245541    245413     47637     46680
x86_64                 ct_enc_1252     79932     79804     22460     21503
```

```
== ReleaseFast: .rodata and .text of each program net of size-none (bench/comptime/size.zig)
cpu                    program      base-ro    new-ro base-text  new-text
native                 ct_1252         1545      1545      8160      8160
native                 rt_1252       180279    180279     42896     42896
native                 rt_label      187898    187898     43600     43600
native                 rt_enc_label    169400    169016     27008     26688
native                 ct_enc_1252      2543      2223      8400      8096
x86_64_v3              ct_1252        58523     58875     17312     18000
x86_64_v3              rt_1252       235481    243321     58800     59200
x86_64_v3              rt_label      243092    250932     59568     60000
x86_64_v3              rt_enc_label    228426    228330     42384     41968
x86_64_v3              ct_enc_1252     62289     62193     19792     19376
x86_64_v2              ct_1252        79611     80043     20528     21152
x86_64_v2              rt_1252       256633    264489     72592     73328
x86_64_v2              rt_label      264254    272110     73456     74048
x86_64_v2              rt_enc_label    252940    252812     55376     54576
x86_64_v2              ct_enc_1252     86801     86673     26928     26128
x86_64                 rt_1252       256663    256663     77136     77136
x86_64                 rt_label      264284    264284     77744     77744
x86_64                 rt_enc_label    252946    252818     60576     59616
x86_64                 ct_enc_1252     86815     86687     28992     28032
```

(The base x86-64 ReleaseFast `ct_1252` did not build in the scratch
tree and is left out; its ReleaseSmall row is unchanged.) A windows-1252
decoder grows by 312 bytes of `.rodata` (its 256-byte split table) and
510 bytes of code on x86-64-v3, 448 and 522 on -v2, ReleaseSmall; the
whole `Decoder` by 7.8 KB of tables and 0.6 KB of code. Every encoder
shrinks, by 0.3 to 1 KB of code and 96 to 512 bytes of `.rodata` (the
search's lane numbers). The AVX-512 and baseline decoders are the same
size as before, to the byte.

## 7. NEON

There is no aarch64 machine here, so the NEON path is checked for
correctness only: `just test-aarch64` runs the unit, table, and
streaming tests for `aarch64-linux-musl` under qemu, ReleaseSafe, where
the default CPU has NEON, and `just ci` and CI now run it. The decode
loop's aarch64 assembly (a `DecoderFor(&.{.windows_1251})` built
ReleaseFast with `-femit-asm`) loads the split table with eight `ldp`
and looks a block up with two `tbl` and two `tbx` of four registers,
then `zip1` and `zip2` into units. Whether two lanes is the right point
to patch instead on ARM, where `tbl` is cheap, is not measured.

## 8. Decisions for the owner

- **The split table's bytes.** The XORed low and high bytes cost 256
  bytes per encoding linked, beside its 256-byte table, on SSSE3, AVX2,
  and NEON builds: 7,424 bytes in a `Decoder` with every encoding, 256 in
  a `DecoderFor(&.{.windows_1252})`, none with AVX-512 or on the
  baseline. Plain low and high bytes could replace the `u16` table on
  those targets and cost nothing, for 0.93x decode on x86-64-v3
  (section 2) and a search over two byte planes in the encoder, not
  measured. Recommendation: keep the XORed split; it is 2.4% of the
  package's 307,099 bytes of tables, and only where it is used.
- **NEON's patch point.** The two-lane patch is measured on x86 only;
  on ARM, `tbl` is cheap and looking every non-ASCII block up may win.
  Recommendation: keep one rule until an aarch64 machine can measure it.

## Raw output

The full run's `bench-compare` summary (`zig`, this branch native, against encoding_rs, per encoding and operation; measured at the code of this branch before a commit that only rewrapped lines):

```
zig/arm, geomean              rows  zig GB/s     rust     ±   <1    ~   slowest vs rust
DecodeUtf8/IBM866               44      3.37     3.94    1%    0    0   1.22 [1.21, 1.31] invalid-16
DecodeUtf16/IBM866              44      4.27     3.89    2%    0    0   1.47 [1.27, 2.60] csv-16
EncodeUtf8/IBM866               44      1.83     8.22    7%    0    0   1.62 [1.60, 1.85] ascii-1048576
EncodeUtf16/IBM866              44      7.64    21.96    1%    0    0   1.57 [1.33, 1.85] ascii-1048576
DecodeUtf8/ISO-8859-2           44      3.14     2.84    2%    1    1   0.93 [0.81, 0.95] web-256
DecodeUtf16/ISO-8859-2          44      4.89     3.36    4%    0    0   1.10 [1.05, 1.57] ascii-1048576
EncodeUtf8/ISO-8859-2           44      2.05     3.73    3%    0    0   1.50 [1.03, 1.72] subtitles-16
EncodeUtf16/ISO-8859-2          44      3.77     5.64    3%    0    1   1.47 [1.37, 2.09] ascii-1048576
DecodeUtf8/ISO-8859-3           44      3.40     2.40    0%    1    9   0.93 [0.91, 0.93] csv-64
DecodeUtf16/ISO-8859-3          44      5.16     3.33    5%    0    0   1.39 [1.28, 1.47] subtitles-16
EncodeUtf8/ISO-8859-3           44      1.95     3.75    2%    0    0   1.42 [1.28, 1.61] ascii-1048576
EncodeUtf16/ISO-8859-3          44      3.98     5.35    3%    0    0   1.32 [1.15, 2.15] ascii-1048576
DecodeUtf8/ISO-8859-4           44      3.62     2.99    1%    0    3   1.17 [0.99, 1.34] mail-256
DecodeUtf16/ISO-8859-4          44      5.51     3.53    2%    0    0   1.09 [1.05, 1.61] ascii-1048576
EncodeUtf8/ISO-8859-4           44      1.96     3.60    9%    0    0   1.53 [1.31, 1.86] mail-256
EncodeUtf16/ISO-8859-4          44      3.70     4.91    1%    0    0   1.15 [1.11, 1.85] csv-64
DecodeUtf8/ISO-8859-5           44      3.28     3.97    4%    0    0   1.30 [1.04, 1.72] mixed-16
DecodeUtf16/ISO-8859-5          44      5.28     4.04    4%    0    0   1.25 [1.06, 1.44] ascii-1048576
EncodeUtf8/ISO-8859-5           44      2.35     3.87   10%    0    1   1.23 [0.98, 1.60] mixed-16
EncodeUtf16/ISO-8859-5          44      9.04     4.95    4%    0    0   1.50 [1.47, 1.73] subtitles-16
DecodeUtf8/ISO-8859-6           44      3.20     3.97    5%    0    0   1.26 [1.22, 1.53] csv-16
DecodeUtf16/ISO-8859-6          44      4.33     4.11    4%    0    0   1.25 [1.15, 1.46] ascii-1048576
EncodeUtf8/ISO-8859-6           44      1.82     4.68    8%    0    0   1.48 [1.19, 2.52] csv-64
EncodeUtf16/ISO-8859-6          44      5.51     7.80    4%    0    0   1.68 [1.67, 2.99] ascii-16
DecodeUtf8/ISO-8859-7           44      2.83     3.88    4%    0    2   1.21 [1.15, 1.49] invalid-16
DecodeUtf16/ISO-8859-7          44      4.29     3.83    3%    0    1   1.10 [1.09, 1.47] ascii-1048576
EncodeUtf8/ISO-8859-7           44      2.02     3.70   11%    0    0   1.52 [1.44, 1.68] mixed-16
EncodeUtf16/ISO-8859-7          44      5.87     4.90    8%    0    0   1.60 [1.02, 1.96] web-64
DecodeUtf8/ISO-8859-8           44      2.92     4.07    2%    0    1   1.35 [1.05, 1.55] ascii-16
DecodeUtf16/ISO-8859-8          44      4.46     4.18    4%    0    1   1.18 [1.04, 1.33] ascii-1048576
EncodeUtf8/ISO-8859-8           44      2.15     3.99    6%    0    3   1.44 [0.85, 1.97] mixed-16
EncodeUtf16/ISO-8859-8          44      6.98     5.04    4%    0    0   1.59 [1.36, 1.75] mail-16
DecodeUtf8/ISO-8859-8-I         44      3.23     3.93    1%    0    3   1.29 [1.04, 1.58] web-16
DecodeUtf16/ISO-8859-8-I        44      5.06     4.16    2%    0    0   1.17 [1.04, 1.57] ascii-1048576
EncodeUtf8/ISO-8859-8-I         44      2.36     3.93    5%    0    1   1.24 [0.98, 1.35] mixed-16
EncodeUtf16/ISO-8859-8-I        44      8.77     5.17    3%    0    1   1.50 [1.40, 1.72] web-16
DecodeUtf8/ISO-8859-10          44      3.34     3.03    3%    0    2   0.98 [0.90, 1.09] csv-64
DecodeUtf16/ISO-8859-10         44      5.14     3.66    1%    0    0   1.08 [1.06, 1.10] ascii-1048576
EncodeUtf8/ISO-8859-10          44      1.73     2.83    3%    0    4   1.42 [1.27, 1.73] csv-16
EncodeUtf16/ISO-8859-10         44      3.41     3.90    2%    0    0   1.27 [1.18, 1.27] ascii-1048576
DecodeUtf8/ISO-8859-13          44      3.41     2.80    1%    1    5   0.79 [0.63, 0.83] subtitles-64
DecodeUtf16/ISO-8859-13         44      5.49     3.42    5%    0    0   1.27 [1.14, 1.29] ascii-1048576
EncodeUtf8/ISO-8859-13          44      1.96     2.50    3%    0    2   1.04 [1.03, 1.08] web-4096
EncodeUtf16/ISO-8859-13         44      3.93     3.25    4%    0    1   1.40 [1.30, 2.18] ascii-1048576
DecodeUtf8/ISO-8859-14          44      4.82     2.59    3%    0    1   1.03 [1.00, 1.20] subtitles-65536
DecodeUtf16/ISO-8859-14         44      7.32     3.31    6%    0    1   1.13 [1.02, 1.25] web-1048576
EncodeUtf8/ISO-8859-14          44      3.27     2.40    2%    0    3   1.20 [0.92, 2.15] ascii-65536
EncodeUtf16/ISO-8859-14         44      6.47     2.93    7%    0    0   1.43 [1.21, 2.64] nonascii-65536
DecodeUtf8/ISO-8859-15          44      4.16     2.75    1%    0    3   1.15 [1.08, 1.15] csv-4096
DecodeUtf16/ISO-8859-15         44      6.37     3.47    3%    0    3   1.07 [0.94, 1.52] ascii-1048576
EncodeUtf8/ISO-8859-15          44      3.61     2.64    3%    0    1   1.08 [0.85, 1.09] csv-256
EncodeUtf16/ISO-8859-15         44     11.93     4.11    3%    0    0   1.40 [1.33, 1.93] ascii-1048576
DecodeUtf8/ISO-8859-16          44      3.51     2.51    2%    1    5   0.91 [0.65, 0.96] csv-64
DecodeUtf16/ISO-8859-16         44      6.25     3.54    2%    0    0   1.24 [1.06, 1.38] ascii-1048576
EncodeUtf8/ISO-8859-16          44      2.21     2.96    2%    0    1   1.32 [1.14, 1.40] subtitles-64
EncodeUtf16/ISO-8859-16         44      4.50     4.12    2%    0    1   1.34 [1.26, 1.52] ascii-1048576
DecodeUtf8/KOI8-R               44      3.29     4.06    3%    0    3   1.23 [1.08, 1.57] invalid-16
DecodeUtf16/KOI8-R              44      5.47     4.14    1%    0    0   1.12 [1.02, 1.58] ascii-1048576
EncodeUtf8/KOI8-R               44      1.30     3.64    1%    0    1   1.49 [1.39, 1.82] mail-64
EncodeUtf16/KOI8-R              44      2.37     4.29    1%    0    0   1.39 [1.29, 1.44] ascii-1048576
DecodeUtf8/KOI8-U               44      3.62     3.85    2%    0    1   1.29 [1.01, 1.82] web-64
DecodeUtf16/KOI8-U              44      5.47     4.01    3%    0    1   1.07 [1.06, 1.30] ascii-1048576
EncodeUtf8/KOI8-U               44      1.51     4.41    1%    0    0   1.55 [1.36, 1.71] subtitles-16
EncodeUtf16/KOI8-U              44      2.96     5.54    3%    0    1   1.37 [1.32, 1.47] ascii-1048576
DecodeUtf8/macintosh            44      4.17     2.42    1%    1    8   0.78 [0.56, 1.03] subtitles-65536
DecodeUtf16/macintosh           44      7.02     3.43    0%    0    0   1.06 [1.02, 1.08] ascii-1048576
EncodeUtf8/macintosh            44      2.95     4.52    3%    0    0   1.57 [1.57, 2.47] ascii-1048576
EncodeUtf16/macintosh           44      5.70     6.04    2%    0    0   1.23 [1.20, 1.52] ascii-1048576
DecodeUtf8/windows-874          44      3.01     3.36    1%    0    2   1.01 [0.95, 1.02] invalid-16
DecodeUtf16/windows-874         44      5.81     3.88    3%    0    0   1.15 [1.08, 1.17] ascii-1048576
EncodeUtf8/windows-874          44      2.89     4.27    1%    0    0   1.26 [1.06, 1.34] mixed-16
EncodeUtf16/windows-874         44      8.47     5.91    2%    0    1   1.37 [0.89, 1.78] ascii-1048576
DecodeUtf8/windows-1250         44      3.52     3.09    1%    0    2   0.90 [0.62, 1.38] mail-16
DecodeUtf16/windows-1250        44      5.70     3.98    2%    0    0   1.10 [1.06, 1.28] ascii-1048576
EncodeUtf8/windows-1250         44      1.78     3.26    3%    0    0   1.49 [1.39, 1.76] csv-16
EncodeUtf16/windows-1250        44      3.82     4.46    2%    0    0   1.43 [1.23, 1.51] ascii-1048576
DecodeUtf8/windows-1251         44      3.57     3.70    3%    0    3   1.01 [0.98, 1.55] invalid-16
DecodeUtf16/windows-1251        44      5.46     4.03    2%    0    0   1.14 [1.05, 1.24] ascii-1048576
EncodeUtf8/windows-1251         44      2.59     3.96    1%    0    0   1.15 [1.06, 1.42] mixed-16
EncodeUtf16/windows-1251        44      9.87     4.67    6%    0    1   1.23 [0.75, 1.35] ascii-1048576
DecodeUtf8/windows-1252         44      3.84     2.38    2%    2    2   0.66 [0.47, 0.81] web-256
DecodeUtf16/windows-1252        44      6.76     3.41    2%    0    0   1.08 [1.05, 1.56] ascii-1048576
EncodeUtf8/windows-1252         44      3.85     2.62    1%    0    2   1.16 [0.93, 1.17] mixed-16
EncodeUtf16/windows-1252        44     12.69     3.61    1%    0    0   1.20 [1.12, 1.36] ascii-1048576
DecodeUtf8/windows-1253         44      3.74     3.83    3%    0    1   1.12 [1.06, 1.23] invalid-16
DecodeUtf16/windows-1253        44      5.58     4.11    1%    0    1   1.05 [1.04, 1.17] ascii-1048576
EncodeUtf8/windows-1253         44      2.55     4.10    2%    0    0   1.50 [1.08, 1.71] mail-16
EncodeUtf16/windows-1253        44      9.41     5.27    4%    0    0   1.36 [1.34, 2.07] ascii-1048576
DecodeUtf8/windows-1254         44      3.59     2.96    2%    0    1   1.14 [1.13, 1.15] web-256
DecodeUtf16/windows-1254        44      5.82     3.77    2%    0    1   1.06 [1.04, 1.12] ascii-1048576
EncodeUtf8/windows-1254         44      1.86     2.60    1%    0    1   1.37 [1.33, 1.79] ascii-64
EncodeUtf16/windows-1254        44      4.22     3.80    0%    0    0   1.44 [1.32, 1.66] ascii-1048576
DecodeUtf8/windows-1255         44      3.60     3.84    1%    0    1   1.38 [1.32, 1.44] ascii-16
DecodeUtf16/windows-1255        44      5.69     4.22    0%    0    0   1.07 [1.05, 1.51] ascii-1048576
EncodeUtf8/windows-1255         44      2.62     4.32    2%    0    0   1.53 [1.45, 1.62] ascii-16
EncodeUtf16/windows-1255        44      9.00     5.97    1%    0    0   1.38 [1.18, 2.23] ascii-1048576
DecodeUtf8/windows-1256         44      3.62     3.84    1%    0    0   1.11 [1.08, 1.40] invalid-16
DecodeUtf16/windows-1256        44      5.65     4.15    2%    0    0   1.10 [1.10, 1.21] ascii-1048576
EncodeUtf8/windows-1256         44      1.61     3.70    0%    0    0   1.60 [1.41, 1.73] web-64
EncodeUtf16/windows-1256        44      3.29     4.38    1%    0    0   1.40 [1.26, 1.57] ascii-1048576
DecodeUtf8/windows-1257         44      3.88     2.79    1%    0    0   1.06 [1.04, 1.07] invalid-16
DecodeUtf16/windows-1257        44      6.40     3.62    2%    0    0   1.08 [1.08, 1.13] ascii-1048576
EncodeUtf8/windows-1257         44      2.33     3.23    2%    0    0   1.66 [1.48, 1.71] mail-16
EncodeUtf16/windows-1257        44      4.57     4.37    2%    0    1   1.27 [1.24, 1.35] ascii-1048576
DecodeUtf8/windows-1258         44      3.78     3.57    1%    0    0   1.17 [1.14, 1.18] csv-64
DecodeUtf16/windows-1258        44      5.84     4.39    0%    0    0   1.09 [1.08, 1.13] ascii-1048576
EncodeUtf8/windows-1258         44      1.66     3.25    2%    0    0   1.51 [1.35, 1.76] web-64
EncodeUtf16/windows-1258        44      3.21     4.24    2%    0    0   1.36 [1.04, 1.72] mail-16
DecodeUtf8/x-mac-cyrillic       44      3.44     3.71    1%    0    0   1.11 [1.07, 1.16] invalid-16
DecodeUtf16/x-mac-cyrillic      44      5.54     4.10    2%    0    0   1.14 [1.11, 1.37] ascii-1048576
EncodeUtf8/x-mac-cyrillic       44      2.23     4.17    5%    0    0   1.50 [1.45, 1.66] ascii-1048576
EncodeUtf16/x-mac-cyrillic      44      6.93     6.95    3%    0    0   1.43 [1.20, 1.60] ascii-1048576
DecodeUtf8/IBM437               44      4.57        -     -    0    0   -
DecodeUtf16/IBM437              44      7.14        -     -    0    0   -
EncodeUtf8/IBM437               44      2.83        -     -    0    0   -
EncodeUtf16/IBM437              44      5.70        -     -    0    0   -
DecodeUtf8/IBM850               44      3.73        -     -    0    0   -
DecodeUtf16/IBM850              44      6.07        -     -    0    0   -
EncodeUtf8/IBM850               44      2.33        -     -    0    0   -
EncodeUtf16/IBM850              44      4.82        -     -    0    0   -
all                           5280      3.94     3.88          7   96

ns/call, median      bytes       zig      rust  zig/rust
DecodeUtf8              16       9.0      13.0      1.40
DecodeUtf8              64      25.1      38.2      1.90
DecodeUtf8             256      65.4     248.0      4.07
DecodeUtf16             16       7.6      12.0      1.56
DecodeUtf16             64      13.7      31.2      2.31
DecodeUtf16            256      38.9     133.9      3.39
EncodeUtf8              16       8.5      14.2      1.75
EncodeUtf8              64      43.0     110.6      2.10
EncodeUtf8             256     152.1     716.4      3.91
EncodeUtf16             16       8.2      15.0      1.86
EncodeUtf16             64      14.4      59.8      2.75
EncodeUtf16            256      42.6     282.0      4.81
```

benchstat of the full run, a few rows (arms: rust zig base basev3 newv3 basev2 newv2 basev1 newv1; n = 3, so no row reaches p < 0.05):

```
                                            │     rust      │                    zig                    │                   base                    │                  basev3                  │                  newv3                   │                  basev2                  │                  newv2                   │                  basev1                  │                  newv1                   │
                                            │     GB/s      │      GB/s        vs base                  │      GB/s        vs base                  │      GB/s       vs base                  │      GB/s       vs base                  │      GB/s       vs base                  │      GB/s       vs base                  │      GB/s       vs base                  │      GB/s       vs base                  │
EncodeUtf16/ISO-8859-10/nonascii-16            252.2m ± ∞ ¹      693.8m ± ∞ ¹         ~ (p=0.100 n=3) ²      356.4m ± ∞ ¹         ~ (p=0.200 n=3) ²     243.4m ± ∞ ¹         ~ (p=0.100 n=3) ²     383.1m ± ∞ ¹         ~ (p=0.100 n=3) ²     183.7m ± ∞ ¹         ~ (p=0.100 n=3) ²     264.5m ± ∞ ¹         ~ (p=1.000 n=3) ²     158.8m ± ∞ ¹         ~ (p=0.100 n=3) ²     294.4m ± ∞ ¹         ~ (p=0.300 n=3) ²
EncodeUtf8/ISO-8859-13/mixed-256               368.9m ± ∞ ¹      854.9m ± ∞ ¹         ~ (p=0.100 n=3) ²      493.8m ± ∞ ¹         ~ (p=0.100 n=3) ²     319.1m ± ∞ ¹         ~ (p=0.700 n=3) ²     495.1m ± ∞ ¹         ~ (p=0.200 n=3) ²     256.9m ± ∞ ¹         ~ (p=0.200 n=3) ²     408.8m ± ∞ ¹         ~ (p=0.700 n=3) ²     251.6m ± ∞ ¹         ~ (p=0.100 n=3) ²     384.8m ± ∞ ¹         ~ (p=0.700 n=3) ²
EncodeUtf8/ISO-8859-13/csv-4096                854.2m ± ∞ ¹     1285.6m ± ∞ ¹         ~ (p=0.200 n=3) ²     1400.5m ± ∞ ¹         ~ (p=0.700 n=3) ²    1212.7m ± ∞ ¹         ~ (p=0.400 n=3) ²    1309.5m ± ∞ ¹         ~ (p=0.700 n=3) ²     924.8m ± ∞ ¹         ~ (p=1.000 n=3) ²     803.1m ± ∞ ¹         ~ (p=1.000 n=3) ²     593.7m ± ∞ ¹         ~ (p=0.400 n=3) ²     751.4m ± ∞ ¹         ~ (p=0.400 n=3) ²
EncodeUtf16/ISO-8859-13/nonascii-16            176.2m ± ∞ ¹      673.7m ± ∞ ¹         ~ (p=0.100 n=3) ²      359.8m ± ∞ ¹         ~ (p=0.200 n=3) ²     246.4m ± ∞ ¹         ~ (p=1.000 n=3) ²     435.3m ± ∞ ¹         ~ (p=0.200 n=3) ²     192.9m ± ∞ ¹         ~ (p=1.000 n=3) ²     286.7m ± ∞ ¹         ~ (p=0.700 n=3) ²     165.1m ± ∞ ¹         ~ (p=0.200 n=3) ²     286.1m ± ∞ ¹         ~ (p=0.700 n=3) ²
EncodeUtf16/ISO-8859-14/nonascii-16            517.6m ± ∞ ¹      840.9m ± ∞ ¹         ~ (p=0.400 n=3) ²      397.8m ± ∞ ¹         ~ (p=0.400 n=3) ²     293.4m ± ∞ ¹         ~ (p=0.100 n=3) ²     494.2m ± ∞ ¹         ~ (p=1.000 n=3) ²     231.0m ± ∞ ¹         ~ (p=0.100 n=3) ²     322.9m ± ∞ ¹         ~ (p=0.200 n=3) ²     210.7m ± ∞ ¹         ~ (p=0.100 n=3) ²     392.0m ± ∞ ¹         ~ (p=0.400 n=3) ²
DecodeUtf16/windows-1251/nonascii-65536         2.258 ± ∞ ¹       6.420 ± ∞ ¹         ~ (p=0.100 n=3) ²       6.164 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.111 ± ∞ ¹         ~ (p=0.100 n=3) ²      3.682 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.454 ± ∞ ¹         ~ (p=0.100 n=3) ²      2.797 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.279 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.433 ± ∞ ¹         ~ (p=0.100 n=3) ²
DecodeUtf8/windows-1252/web-65536               3.517 ± ∞ ¹       4.240 ± ∞ ¹         ~ (p=0.200 n=3) ²       4.599 ± ∞ ¹         ~ (p=0.100 n=3) ²      6.076 ± ∞ ¹         ~ (p=0.100 n=3) ²      5.218 ± ∞ ¹         ~ (p=0.100 n=3) ²      6.272 ± ∞ ¹         ~ (p=0.100 n=3) ²      4.283 ± ∞ ¹         ~ (p=0.100 n=3) ²      5.707 ± ∞ ¹         ~ (p=0.100 n=3) ²      5.769 ± ∞ ¹         ~ (p=0.100 n=3) ²
DecodeUtf16/windows-1252/ascii-16               1.469 ± ∞ ¹       2.188 ± ∞ ¹         ~ (p=0.400 n=3) ²       2.077 ± ∞ ¹         ~ (p=0.400 n=3) ²      2.210 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.717 ± ∞ ¹         ~ (p=0.100 n=3) ²      2.178 ± ∞ ¹         ~ (p=0.400 n=3) ²      1.898 ± ∞ ¹         ~ (p=0.100 n=3) ²      1.991 ± ∞ ¹         ~ (p=0.100 n=3) ²      2.123 ± ∞ ¹         ~ (p=0.400 n=3) ²
DecodeUtf16/windows-1252/csv-4096               4.398 ± ∞ ¹      14.892 ± ∞ ¹         ~ (p=0.100 n=3) ²      13.903 ± ∞ ¹         ~ (p=0.100 n=3) ²     15.494 ± ∞ ¹         ~ (p=0.100 n=3) ²     13.779 ± ∞ ¹         ~ (p=0.100 n=3) ²     14.291 ± ∞ ¹         ~ (p=0.100 n=3) ²     10.279 ± ∞ ¹         ~ (p=0.100 n=3) ²     11.592 ± ∞ ¹         ~ (p=0.100 n=3) ²     13.175 ± ∞ ¹         ~ (p=0.100 n=3) ²
EncodeUtf8/windows-1254/csv-4096              1036.8m ± ∞ ¹     1729.2m ± ∞ ¹         ~ (p=0.100 n=3) ²     1284.5m ± ∞ ¹         ~ (p=0.100 n=3) ²     946.4m ± ∞ ¹         ~ (p=0.700 n=3) ²    1239.0m ± ∞ ¹         ~ (p=0.100 n=3) ²     833.8m ± ∞ ¹         ~ (p=0.100 n=3) ²     974.8m ± ∞ ¹         ~ (p=0.400 n=3) ²     727.8m ± ∞ ¹         ~ (p=0.100 n=3) ²     903.7m ± ∞ ¹         ~ (p=0.100 n=3) ²
```

benchstat of the placement run, `windows-1252` rows (arms: rust zig bv3_0 bv3_16 bv3_32 bv3_48 nv3_0 nv3_16 nv3_32 nv3_48 nv3_0dup nn_0 nn_16 nn_32 nn_48):

```
                                       │     rust     │                    zig                    │                  bv3_0                  │                 bv3_16                  │                 bv3_32                  │                 bv3_48                  │                  nv3_0                  │                 nv3_16                  │                 nv3_32                  │                 nv3_48                  │                nv3_0dup                 │                   nn_0                    │                   nn_16                   │                   nn_32                   │                   nn_48                   │
                                       │     GB/s     │      GB/s        vs base                  │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s       vs base                 │      GB/s        vs base                  │      GB/s        vs base                  │      GB/s        vs base                  │      GB/s        vs base                  │
DecodeUtf8/windows-1252/nonascii-16      371.1m ± ∞ ¹      635.3m ± ∞ ¹     +71.19% (p=0.008 n=5)     518.5m ± ∞ ¹    +39.72% (p=0.008 n=5)     515.4m ± ∞ ¹    +38.88% (p=0.008 n=5)     516.2m ± ∞ ¹    +39.10% (p=0.008 n=5)     515.4m ± ∞ ¹    +38.88% (p=0.008 n=5)     575.0m ± ∞ ¹    +54.94% (p=0.008 n=5)     577.1m ± ∞ ¹    +55.51% (p=0.008 n=5)     702.9m ± ∞ ¹    +89.41% (p=0.008 n=5)     647.8m ± ∞ ¹    +74.56% (p=0.008 n=5)     573.0m ± ∞ ¹    +54.41% (p=0.008 n=5)      638.8m ± ∞ ¹     +72.14% (p=0.008 n=5)      648.3m ± ∞ ¹     +74.70% (p=0.008 n=5)      649.5m ± ∞ ¹     +75.02% (p=0.008 n=5)      665.3m ± ∞ ¹     +79.28% (p=0.008 n=5)
DecodeUtf8/windows-1252/mixed-256        358.4m ± ∞ ¹     3528.2m ± ∞ ¹    +884.43% (p=0.008 n=5)    1824.3m ± ∞ ¹   +409.01% (p=0.008 n=5)    1869.3m ± ∞ ¹   +421.57% (p=0.008 n=5)    1947.5m ± ∞ ¹   +443.39% (p=0.008 n=5)    1945.5m ± ∞ ¹   +442.83% (p=0.008 n=5)    2558.9m ± ∞ ¹   +613.98% (p=0.008 n=5)    2426.0m ± ∞ ¹   +576.90% (p=0.008 n=5)    2503.8m ± ∞ ¹   +598.60% (p=0.008 n=5)    2300.6m ± ∞ ¹   +541.91% (p=0.008 n=5)    2297.0m ± ∞ ¹   +540.90% (p=0.008 n=5)     3536.8m ± ∞ ¹    +886.83% (p=0.008 n=5)     3448.5m ± ∞ ¹    +862.19% (p=0.008 n=5)     3532.1m ± ∞ ¹    +885.52% (p=0.008 n=5)     3538.6m ± ∞ ¹    +887.33% (p=0.008 n=5)
DecodeUtf8/windows-1252/csv-4096          4.711 ± ∞ ¹       5.041 ± ∞ ¹           ~ (p=0.151 n=5)      7.023 ± ∞ ¹    +49.08% (p=0.008 n=5)      6.573 ± ∞ ¹    +39.53% (p=0.008 n=5)      5.891 ± ∞ ¹    +25.06% (p=0.008 n=5)      5.901 ± ∞ ¹    +25.27% (p=0.008 n=5)      5.330 ± ∞ ¹          ~ (p=0.056 n=5)      5.933 ± ∞ ¹    +25.95% (p=0.008 n=5)      5.739 ± ∞ ¹    +21.83% (p=0.032 n=5)      5.745 ± ∞ ¹    +21.96% (p=0.008 n=5)      5.162 ± ∞ ¹          ~ (p=0.056 n=5)       4.929 ± ∞ ¹           ~ (p=0.151 n=5)       5.565 ± ∞ ¹           ~ (p=0.222 n=5)       5.086 ± ∞ ¹           ~ (p=0.056 n=5)       5.059 ± ∞ ¹           ~ (p=0.056 n=5)
DecodeUtf8/windows-1252/web-65536         3.611 ± ∞ ¹       4.359 ± ∞ ¹     +20.73% (p=0.016 n=5)      6.251 ± ∞ ¹    +73.12% (p=0.008 n=5)      5.984 ± ∞ ¹    +65.73% (p=0.008 n=5)      5.248 ± ∞ ¹    +45.35% (p=0.008 n=5)      6.431 ± ∞ ¹    +78.12% (p=0.008 n=5)      5.789 ± ∞ ¹    +60.32% (p=0.008 n=5)      6.365 ± ∞ ¹    +76.28% (p=0.008 n=5)      5.917 ± ∞ ¹    +63.87% (p=0.008 n=5)      5.175 ± ∞ ¹    +43.33% (p=0.008 n=5)      4.886 ± ∞ ¹    +35.32% (p=0.008 n=5)       4.269 ± ∞ ¹     +18.23% (p=0.016 n=5)       4.443 ± ∞ ¹     +23.05% (p=0.032 n=5)       4.249 ± ∞ ¹     +17.67% (p=0.032 n=5)       4.316 ± ∞ ¹     +19.54% (p=0.008 n=5)
DecodeUtf16/windows-1252/nonascii-16     910.1m ± ∞ ¹     2177.6m ± ∞ ¹    +139.27% (p=0.008 n=5)     989.7m ± ∞ ¹          ~ (p=0.222 n=5)    1024.3m ± ∞ ¹          ~ (p=0.222 n=5)    1031.5m ± ∞ ¹          ~ (p=0.222 n=5)    1026.2m ± ∞ ¹          ~ (p=0.222 n=5)    1609.2m ± ∞ ¹    +76.82% (p=0.008 n=5)    1615.0m ± ∞ ¹    +77.45% (p=0.008 n=5)    1612.4m ± ∞ ¹    +77.17% (p=0.008 n=5)    1596.7m ± ∞ ¹    +75.44% (p=0.008 n=5)    1555.3m ± ∞ ¹    +70.89% (p=0.008 n=5)     2109.6m ± ∞ ¹    +131.80% (p=0.008 n=5)     2162.7m ± ∞ ¹    +137.63% (p=0.008 n=5)     2177.2m ± ∞ ¹    +139.23% (p=0.008 n=5)     2188.7m ± ∞ ¹    +140.49% (p=0.008 n=5)
DecodeUtf16/windows-1252/mixed-256       502.5m ± ∞ ¹     5976.7m ± ∞ ¹   +1089.39% (p=0.008 n=5)    2660.1m ± ∞ ¹   +429.37% (p=0.008 n=5)    2552.2m ± ∞ ¹   +407.90% (p=0.008 n=5)    2580.8m ± ∞ ¹   +413.59% (p=0.008 n=5)    2390.4m ± ∞ ¹   +375.70% (p=0.008 n=5)    3243.5m ± ∞ ¹   +545.47% (p=0.008 n=5)    3171.5m ± ∞ ¹   +531.14% (p=0.008 n=5)    3093.5m ± ∞ ¹   +515.62% (p=0.008 n=5)    3049.5m ± ∞ ¹   +506.87% (p=0.008 n=5)    3053.4m ± ∞ ¹   +507.64% (p=0.008 n=5)     5121.0m ± ∞ ¹    +919.10% (p=0.008 n=5)     5252.1m ± ∞ ¹    +945.19% (p=0.008 n=5)     5049.5m ± ∞ ¹    +904.88% (p=0.008 n=5)     6168.7m ± ∞ ¹   +1127.60% (p=0.008 n=5)
DecodeUtf16/windows-1252/csv-4096         4.395 ± ∞ ¹      12.492 ± ∞ ¹    +184.21% (p=0.008 n=5)     10.357 ± ∞ ¹   +135.65% (p=0.008 n=5)     11.299 ± ∞ ¹   +157.07% (p=0.008 n=5)     14.990 ± ∞ ¹   +241.05% (p=0.008 n=5)     14.203 ± ∞ ¹   +223.14% (p=0.008 n=5)     12.265 ± ∞ ¹   +179.05% (p=0.008 n=5)     11.663 ± ∞ ¹   +165.34% (p=0.008 n=5)     11.268 ± ∞ ¹   +156.36% (p=0.008 n=5)     12.442 ± ∞ ¹   +183.07% (p=0.008 n=5)     11.960 ± ∞ ¹   +172.12% (p=0.008 n=5)      11.291 ± ∞ ¹    +156.89% (p=0.008 n=5)      11.856 ± ∞ ¹    +169.74% (p=0.008 n=5)      11.574 ± ∞ ¹    +163.34% (p=0.008 n=5)      12.444 ± ∞ ¹    +183.12% (p=0.008 n=5)
DecodeUtf16/windows-1252/web-65536        3.884 ± ∞ ¹      12.175 ± ∞ ¹    +213.49% (p=0.008 n=5)     10.568 ± ∞ ¹   +172.11% (p=0.008 n=5)     12.408 ± ∞ ¹   +219.47% (p=0.008 n=5)     14.336 ± ∞ ¹   +269.11% (p=0.008 n=5)     14.226 ± ∞ ¹   +266.28% (p=0.008 n=5)     12.710 ± ∞ ¹   +227.26% (p=0.008 n=5)     11.690 ± ∞ ¹   +200.98% (p=0.008 n=5)     12.040 ± ∞ ¹   +210.00% (p=0.008 n=5)     12.493 ± ∞ ¹   +221.67% (p=0.008 n=5)     12.958 ± ∞ ¹   +233.64% (p=0.008 n=5)      12.421 ± ∞ ¹    +219.81% (p=0.008 n=5)      12.449 ± ∞ ¹    +220.54% (p=0.008 n=5)      12.509 ± ∞ ¹    +222.08% (p=0.008 n=5)      12.463 ± ∞ ¹    +220.90% (p=0.008 n=5)
EncodeUtf8/windows-1252/nonascii-16      228.2m ± ∞ ¹      660.8m ± ∞ ¹    +189.57% (p=0.008 n=5)     622.2m ± ∞ ¹   +172.66% (p=0.008 n=5)     649.6m ± ∞ ¹   +184.66% (p=0.008 n=5)     620.8m ± ∞ ¹   +172.04% (p=0.008 n=5)     670.9m ± ∞ ¹   +194.00% (p=0.008 n=5)     669.9m ± ∞ ¹   +193.56% (p=0.008 n=5)     670.7m ± ∞ ¹   +193.91% (p=0.008 n=5)     643.4m ± ∞ ¹   +181.95% (p=0.008 n=5)     640.8m ± ∞ ¹   +180.81% (p=0.008 n=5)     651.2m ± ∞ ¹   +185.36% (p=0.008 n=5)      660.7m ± ∞ ¹    +189.53% (p=0.008 n=5)      622.5m ± ∞ ¹    +172.79% (p=0.008 n=5)      637.6m ± ∞ ¹    +179.40% (p=0.008 n=5)      641.2m ± ∞ ¹    +180.98% (p=0.008 n=5)
EncodeUtf8/windows-1252/mixed-256        612.5m ± ∞ ¹     2272.3m ± ∞ ¹    +270.99% (p=0.008 n=5)    2056.3m ± ∞ ¹   +235.72% (p=0.008 n=5)    2144.7m ± ∞ ¹   +250.16% (p=0.008 n=5)    1946.9m ± ∞ ¹   +217.86% (p=0.008 n=5)    2095.1m ± ∞ ¹   +242.06% (p=0.008 n=5)    2117.9m ± ∞ ¹   +245.78% (p=0.008 n=5)    2048.0m ± ∞ ¹   +234.37% (p=0.008 n=5)    2033.6m ± ∞ ¹   +232.02% (p=0.008 n=5)    2043.4m ± ∞ ¹   +233.62% (p=0.008 n=5)    2065.5m ± ∞ ¹   +237.22% (p=0.008 n=5)     2316.7m ± ∞ ¹    +278.24% (p=0.008 n=5)     2301.2m ± ∞ ¹    +275.71% (p=0.008 n=5)     2571.0m ± ∞ ¹    +319.76% (p=0.008 n=5)     2485.6m ± ∞ ¹    +305.81% (p=0.008 n=5)
EncodeUtf8/windows-1252/csv-4096          4.792 ± ∞ ¹       6.427 ± ∞ ¹     +34.13% (p=0.008 n=5)      7.024 ± ∞ ¹          ~ (p=0.056 n=5)      6.392 ± ∞ ¹    +33.39% (p=0.008 n=5)      6.466 ± ∞ ¹    +34.94% (p=0.008 n=5)      6.976 ± ∞ ¹    +45.59% (p=0.008 n=5)      6.529 ± ∞ ¹    +36.26% (p=0.016 n=5)      6.392 ± ∞ ¹    +33.41% (p=0.032 n=5)      6.528 ± ∞ ¹    +36.24% (p=0.008 n=5)      6.507 ± ∞ ¹    +35.80% (p=0.008 n=5)      6.905 ± ∞ ¹    +44.11% (p=0.008 n=5)       6.664 ± ∞ ¹     +39.07% (p=0.008 n=5)       6.691 ± ∞ ¹     +39.65% (p=0.008 n=5)       6.585 ± ∞ ¹     +37.43% (p=0.008 n=5)       6.505 ± ∞ ¹     +35.76% (p=0.008 n=5)
EncodeUtf8/windows-1252/web-65536         4.148 ± ∞ ¹       7.011 ± ∞ ¹     +69.05% (p=0.008 n=5)      7.019 ± ∞ ¹    +69.23% (p=0.008 n=5)      6.875 ± ∞ ¹    +65.75% (p=0.008 n=5)      6.897 ± ∞ ¹    +66.28% (p=0.008 n=5)      6.487 ± ∞ ¹    +56.39% (p=0.008 n=5)      7.682 ± ∞ ¹    +85.21% (p=0.008 n=5)      7.424 ± ∞ ¹    +78.99% (p=0.008 n=5)      6.949 ± ∞ ¹    +67.55% (p=0.032 n=5)      7.061 ± ∞ ¹    +70.24% (p=0.008 n=5)      6.909 ± ∞ ¹    +66.58% (p=0.008 n=5)       7.561 ± ∞ ¹     +82.29% (p=0.008 n=5)       7.523 ± ∞ ¹     +81.37% (p=0.008 n=5)       7.706 ± ∞ ¹     +85.78% (p=0.008 n=5)       7.594 ± ∞ ¹     +83.09% (p=0.008 n=5)
EncodeUtf16/windows-1252/nonascii-16      1.030 ± ∞ ¹       4.596 ± ∞ ¹    +346.00% (p=0.008 n=5)      4.261 ± ∞ ¹   +313.48% (p=0.008 n=5)      4.278 ± ∞ ¹   +315.16% (p=0.008 n=5)      4.289 ± ∞ ¹   +316.21% (p=0.008 n=5)      4.280 ± ∞ ¹   +315.38% (p=0.008 n=5)      3.871 ± ∞ ¹   +275.66% (p=0.008 n=5)      3.890 ± ∞ ¹   +277.50% (p=0.008 n=5)      3.844 ± ∞ ¹   +273.02% (p=0.008 n=5)      4.030 ± ∞ ¹   +291.11% (p=0.008 n=5)      3.992 ± ∞ ¹   +287.39% (p=0.008 n=5)       4.487 ± ∞ ¹    +335.43% (p=0.008 n=5)       4.504 ± ∞ ¹    +337.15% (p=0.008 n=5)       4.566 ± ∞ ¹    +343.15% (p=0.008 n=5)       4.905 ± ∞ ¹    +376.03% (p=0.008 n=5)
EncodeUtf16/windows-1252/mixed-256        1.030 ± ∞ ¹      17.813 ± ∞ ¹   +1628.58% (p=0.008 n=5)     14.097 ± ∞ ¹  +1267.99% (p=0.008 n=5)     12.351 ± ∞ ¹  +1098.51% (p=0.008 n=5)     13.554 ± ∞ ¹  +1215.31% (p=0.008 n=5)     12.625 ± ∞ ¹  +1125.13% (p=0.008 n=5)     11.091 ± ∞ ¹   +976.27% (p=0.008 n=5)     13.024 ± ∞ ¹  +1163.81% (p=0.008 n=5)     12.365 ± ∞ ¹  +1099.90% (p=0.008 n=5)     12.115 ± ∞ ¹  +1075.64% (p=0.008 n=5)     11.981 ± ∞ ¹  +1062.65% (p=0.008 n=5)      15.377 ± ∞ ¹   +1392.18% (p=0.008 n=5)      14.944 ± ∞ ¹   +1350.18% (p=0.008 n=5)      18.119 ± ∞ ¹   +1658.26% (p=0.008 n=5)      18.263 ± ∞ ¹   +1672.24% (p=0.008 n=5)
EncodeUtf16/windows-1252/csv-4096         8.539 ± ∞ ¹      26.773 ± ∞ ¹    +213.56% (p=0.008 n=5)     23.346 ± ∞ ¹   +173.42% (p=0.008 n=5)     26.159 ± ∞ ¹   +206.37% (p=0.008 n=5)     27.055 ± ∞ ¹   +216.85% (p=0.008 n=5)     25.947 ± ∞ ¹   +203.88% (p=0.008 n=5)     25.276 ± ∞ ¹   +196.03% (p=0.008 n=5)     27.312 ± ∞ ¹   +219.87% (p=0.008 n=5)     27.423 ± ∞ ¹   +221.17% (p=0.008 n=5)     27.681 ± ∞ ¹   +224.19% (p=0.008 n=5)     25.026 ± ∞ ¹   +193.10% (p=0.008 n=5)      26.573 ± ∞ ¹    +211.21% (p=0.008 n=5)      24.649 ± ∞ ¹    +188.68% (p=0.008 n=5)      26.929 ± ∞ ¹    +215.38% (p=0.008 n=5)      26.931 ± ∞ ¹    +215.41% (p=0.008 n=5)
EncodeUtf16/windows-1252/web-65536        5.832 ± ∞ ¹      26.593 ± ∞ ¹    +355.95% (p=0.008 n=5)     21.458 ± ∞ ¹   +267.91% (p=0.008 n=5)     21.500 ± ∞ ¹   +268.62% (p=0.008 n=5)     21.495 ± ∞ ¹   +268.55% (p=0.008 n=5)     21.631 ± ∞ ¹   +270.87% (p=0.008 n=5)     20.858 ± ∞ ¹   +257.62% (p=0.008 n=5)     26.682 ± ∞ ¹   +357.47% (p=0.008 n=5)     26.467 ± ∞ ¹   +353.79% (p=0.008 n=5)     27.087 ± ∞ ¹   +364.41% (p=0.008 n=5)     27.465 ± ∞ ¹   +370.89% (p=0.008 n=5)      31.465 ± ∞ ¹    +439.48% (p=0.008 n=5)      31.876 ± ∞ ¹    +446.53% (p=0.008 n=5)      34.635 ± ∞ ¹    +493.83% (p=0.008 n=5)      34.453 ± ∞ ¹    +490.71% (p=0.008 n=5)
```
