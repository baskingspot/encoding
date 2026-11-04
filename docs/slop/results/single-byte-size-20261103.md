# Single-byte staging without utf, and the baseline lookup, 2026-11-03

Wave 5. Two problems readme-numbers-20261103.md found:

1. A one-encoding single-byte `DecoderFor(&.{.windows_1252})` linked
   51,012 + 12,250 bytes (`.rodata` + `.text`, ReleaseSmall, net of a
   stdin copy) for x86-64-v3, 72,550 + 17,350 for baseline x86-64, and
   21,168 + 4,800 on aarch64, against 1,049 + 5,781 for the AVX-512 host:
   the single-byte and x-user-defined staging transcoded through
   baskingspot/utf, whose kernels below AVX-512 carry lookup tables and
   whose x86-64 dispatch links the higher levels' kernels too.
2. Built for baseline x86-64 (SSE2), single-byte decode to UTF-16 of text
   with no ASCII was 0.61-0.63x encoding_rs at 64 KiB, and windows-874's
   realistic rows 0.78-0.89x: the block lookup patched lane by lane.

Headlines (the machine and method follow):

1. **Size.** The staging now converts with a BMP-only transcoder of
   `codec.zig`'s own, so the single-byte programs link no utf. A
   one-encoding `DecoderFor(&.{.windows_1252})` is 3,052 bytes on the
   AVX-512 host (from 6,830), 12,952 for x86-64-v3 (from 63,262, 4.9x),
   13,869 for -v2 (from 89,622, 6.5x), 6,435 for baseline (from 89,900,
   14x) and 12,580 on aarch64 (from 25,968, 2.1x); the encoder 9,275 on -v3
   (from 67,903) and 7,713 at baseline (from 101,307). Against utf built
   without dispatch, 2.0x smaller on -v3 and -v2 and 1.9x larger at baseline
   (section 2).
2. **Speed against utf at the same level** (utf without dispatch; final
   run, 5,456 single-byte rows, geomean): decode to UTF-8 and encode from
   UTF-8 0.95x and 0.98x on -v3, 1.03x and 1.00x on -v2, 1.53x and 1.17x at
   baseline; the host 1.10x and 1.00x origin/main. Slower: 3-byte text on
   -v3 and -v2 (0.69-0.86x on the microbenchmark, section 3), the host's
   non-ASCII encode of 64 bytes (0.65x origin/main), and **a baseline
   build on a newer CPU, which loses utf's run-time dispatch: 0.65x and
   0.79x origin/main on this CPU** (section 4, decision 1).
3. **Baseline lookup.** x86-64-v2 has no gap (origin/main's `nonascii`
   decode to UTF-16 1.64-1.85x encoding_rs). For the baseline, blocks with
   more than 12 bytes from 0x80 are looked up a load a lane: `nonascii`
   at 64 KiB 0.84x → 1.07x encoding_rs, windows-874's realistic rows
   0.93-1.27x → 1.22-1.69x, and half the placement spread; realistic text
   pays 5-20% against origin/main, still 1.8x encoding_rs or more (section
   5).
4. Gates on the final code: `just ci`, `just oracle 20000`, `just fuzz
600`, a fuzz of the 31 single-byte encodings and x-user-defined on
   `-Dcpu=x86_64_v3` and `-Dcpu=x86_64` builds, all exit 0; `rg
setRuntimeSafety src` empty (section 7).

## Machine

Intel(R) Xeon(R) Processor @ 2.60GHz (family 6 model 106, Ice Lake
server), 4 vCPUs (2 cores of 2 threads: CPUs 0 and 1, 2 and 3 are
siblings) in a KVM orb, AVX-512 with BW, VL, VBMI and VBMI2, Linux 6.1.
Zig 0.16.0, ReleaseFast for speed and ReleaseSmall for sizes; encoding_rs
0.8.44 (`rust`) for Rust's default x86-64 target (SSE2), release with
LTO, as the harness builds it. A shared host: read ratios, not absolute
GB/s. Every build runs on this one CPU, so the x86-64-v3, -v2 and
baseline builds are those levels' code on a CPU that also has AVX-512,
not older CPUs. aarch64 speed is not measured (no hardware; `just
test-aarch64` runs the NEON paths under qemu), only its sizes.

## Commands

- Sizes: `bench/comptime`, `zig build sizes -Doptimize=ReleaseSmall`
  with no `-Dcpu` (host), `-Dcpu=x86_64_v3`, `-Dcpu=x86_64_v2`,
  `-Dcpu=baseline`, and `-Dtarget=aarch64-linux-musl`; each program's
  `.rodata` and `.text` from `size -A`, less `size-none`'s (as
  `bench/comptime/sizes.sh` does). The utf no-dispatch column is origin/main
  with `build.zig` passing `.dispatch = false` to utf's
  `dispatch_options` (a local edit, not committed).
- Speed: `bench/` built with `zig build -Dcpu=<level>` into one
  `bench-<arm>` per arm, then `BENCHTIME_MS=20 just arms='...'
bench-compare 3 '^[A-Za-z0-9]+/(<the 31 single-byte encodings and
x-user-defined>)/'`: 5,456 rows (the four operations, eight shapes,
  and sizes 16 to 65,536), 3 rounds after a sizing round, each arm a
  `bench-<arm> serve` pinned to core 3 (`taskset`), every arm timing a row
  back to back in an order that rotates from row to row and round to
  round, then benchstat. The arms:
  - `zig`, `newv3`, `newv2`, `newv1`: this branch built for the host
    (AVX-512), x86-64-v3, x86-64-v2 and baseline x86-64.
  - `main`, `mainv3`, `mainv2`, `mainv1`: origin/main `0bc8ec4`, the same
    four builds. On this CPU utf's run-time dispatch picks its AVX-512
    kernels in `mainv3`, `mainv2` and `mainv1`, so their UTF-8 staging runs
    at the host's speed, which a real x86-64-v3 or older CPU would not.
  - `mainndv3`, `mainndv2`, `mainndv1`: origin/main with utf's dispatch
    off, so each level runs its own utf kernel: what an older CPU gets.
    The fair comparison for the staging off the host.
  - `rust`: encoding_rs.
    The gates ran on CPUs 0 and 1 during the final run (disclosed: they
    share the L3 and memory with core 3; every arm saw the same load, rows
    interleaved).
- Placement of the baseline lookup: `bench-<arm>_<n>` with `jmp 1f;
.skip n, 0xcc; 1:` at the start of the harness's row function for n =
  0, 16, 32, 48 (the method of single-byte-20261102.md), 372 rows
  (DecodeUtf16, `csv`, `mixed`, `web`, `nonascii`, 256 to 65,536 bytes),
  3 rounds.
- Placement of the -v3 build: the same with `-Dcpu=x86_64_v3`, this
  branch against origin/main without dispatch, 186 rows (DecodeUtf8,
  `ascii`, `web`, `nonascii`, 16 and 256 bytes), 3 rounds.
- The rejected padded last window: `EncodeUtf8` rows only (1,364), 3
  rounds, the same arms plus that variant's four builds.
- Microbenchmark (section 3): the staging functions alone on 64 KiB of
  Russian, Thai, x-user-defined (U+F780 to U+F7FF) and German text, in
  calls of 256 units or bytes, best of 200, against utf's
  `utf16leToUtf8` and `utf8ToUtf16le` built for the same level without
  dispatch, pinned to core 3.

## 1. Change

Two commits on origin/main `0bc8ec4`.

### `codec: transcode the single-byte staging without utf`

`codec.zig` no longer imports utf (UTF-8 and UTF-16 decoding still use
it). The staging holds code points below U+10000 that are not surrogates,
so neither direction has a surrogate path. A comptime `pack` picks how
characters of different lengths are packed together:

- `.compress`: AVX-512 VBMI2's `vpcompressb` and `vpcompressw` (with BW
  and VL), through the LLVM intrinsics. The host.
- `.shuffle`: SSSE3's `pshufb` (with AVX2, `vpshufb` on two 16-byte groups
  at once) or NEON's `tbl`, indexed by 256-entry tables of shuffles built
  at compile time: `pack_narrow` (eight code points below U+0800 by which
  are ASCII) and `pack_quads` (four code points of one to three bytes, by
  two bits each, with a 256-byte length table) for decode, `pack_units`
  (eight units by which start a character) for encode. 8,448 bytes for
  decode, 4,096 for encode. x86-64-v2, -v3 and aarch64.
- `.store`: one store per character, the next overwriting the previous
  one's spare bytes, and eight ASCII characters as one store. Baseline
  x86-64, big-endian targets, other architectures, and the self-hosted
  backend (Debug tests take it; ReleaseSafe tests take the SIMD paths).

Decode (`bmpToUtf8`) keeps the staging as it was: up to 256 bytes go to
UTF-16 a block at a time, then 32 units a step: narrowed and stored when
all are ASCII (but with `vpcompressb`, which is as fast), packed two bytes
a code point when all are below U+0800, and otherwise both blocks of 16
through `bmpBlockToUtf8`, then a scalar tail that stops where a character
does not fit. `bmpBlockToUtf8` builds each code point's bytes in 16-bit
lanes on the shuffle targets (its first two bytes in one vector, its third
in another, interleaved into four bytes a code point) and in 32-bit lanes
for `vpcompressb` and the stores; the table index for four code points is
one byte of a single `pmovmskb`.

Encode (`utf8ToBmp`, called by `encodeStaged`) reads a window of 64 bytes
(`.compress`) or 32, computes each byte's unit as a low and a high byte
from it and the two bytes after it on every lane at once, and keeps the
units of the bytes that start a well-formed one-, two- or three-byte
character. It stops at the first byte that does not (a four-byte
sequence, which the stage does not hold, or ill-formed UTF-8, which the
caller reads a character at a time). Windows start every `window` bytes;
the one or two bytes that end the last character of a window are skipped
at the start of the next, counted from that character's lead byte, so a
window's loads do not wait on the masks of the one before. It stops with
fewer than `window + 2` bytes left, which the caller reads a character at
a time. `staged_min = @max(64, window + 2)`, the input below which the
encoders do not stage, is 64 bytes but on the host, 66.

Two tests in `codec.zig`: every BMP code point through `bmpToUtf8`, at
every offset and with characters of every length among them, gives what
`put` gives, and with a random output length writes exactly the whole
characters that fit; `utf8ToBmp` on every two-byte sequence from a byte
from 0x80 (and with E0 a set of third bytes), at every offset of a window
and across into the next, gives what `utf8Step` reads up to where it
stops, and stops only at a four-byte or ill-formed sequence or within
`window + 2` bytes of the end. Both fail on planted mutations in
ReleaseSafe, and the second caught an operator-precedence slip during this
work (`a << 6 | b & 0x3F` groups as `(a << 6 | b) & 0x3F` in Zig). `just
ci`'s s390x tests caught the encoder's byte interleave putting the high
byte last on a big-endian target; it follows the machine's byte order now.

### `single_byte: look dense blocks up a load a lane without SSSE3`

With no byte shuffle (`block_lookup == .none`: baseline x86-64, other
architectures, other backends), a block with more than 12 bytes from 0x80
is looked up whole by `gatherBlock`: 16 table loads, four units put
together in a 64-bit register, two registers to a vector, then the same
select as the shuffle paths. LLVM does not emit `pinsrw` for such loads (it
uses `movd` and `punpck`), so four units in a u64 cost fewer vector
shuffles than inserting units one by one. Blocks with 12 or fewer keep
the lane-by-lane patch. "More than 12" is tested as "`~m` with its three
lowest set bits cleared is zero" (`dense`), not with `@popCount`: the
baseline has no `popcnt`, and its software popcount cost 4-8% on every
non-ASCII block (section 5). Other targets keep `@popCount(m) > 2`.

## 2. Size

Net of `size-none`, ReleaseSmall, bytes of `.rodata` + `.text`. `main` is
origin/main `0bc8ec4`; `utf no-dispatch` is main with utf's dispatch off
(the alternative the owner could ask utf for); `this branch` is the head.
aarch64 has no dispatch, so its no-dispatch column is main's.

`DecoderFor(&.{.windows_1252})` (`ct_1252`):

| target         | main            | utf no-dispatch | this branch   | total: main → this branch |
| -------------- | --------------- | --------------- | ------------- | ------------------------- |
| host (AVX-512) | 1,049 + 5,781   | (= main)        | 354 + 2,698   | 6,830 → 3,052             |
| x86-64-v3      | 51,012 + 12,250 | 21,381 + 5,050  | 9,352 + 3,600 | 63,262 → 12,952           |
| x86-64-v2      | 72,788 + 16,834 | 21,728 + 6,986  | 9,536 + 4,333 | 89,622 → 13,869           |
| baseline       | 72,550 + 17,350 | 320 + 3,102     | 544 + 5,891   | 89,900 → 6,435            |
| aarch64        | 21,168 + 4,800  | (= main)        | 9,264 + 3,316 | 25,968 → 12,580           |

`EncoderFor(&.{.windows_1252})` (`ct_enc_1252`):

| target         | main            | utf no-dispatch | this branch   | total: main → this branch |
| -------------- | --------------- | --------------- | ------------- | ------------------------- |
| host (AVX-512) | 1,775 + 5,711   | (= main)        | 1,912 + 4,476 | 7,486 → 6,388             |
| x86-64-v3      | 54,338 + 13,565 | 24,739 + 7,615  | 4,456 + 4,819 | 67,903 → 9,275            |
| x86-64-v2      | 79,562 + 19,952 | 24,912 + 10,272 | 4,576 + 5,989 | 99,514 → 10,565           |
| baseline       | 79,804 + 21,503 | 352 + 6,322     | 608 + 7,105   | 101,307 → 7,713           |
| aarch64        | 24,608 + 8,384  | (= main)        | 4,432 + 5,740 | 32,992 → 10,172           |

The rest, which link utf for UTF-8 or UTF-16 anyway (`rt_label` is
`Decoder` for any label, `rt_enc_label` `Encoder`, `ct_utf8_1252` a
`DecoderFor` UTF-8 and windows-1252):

| program        | target    | main             | utf no-dispatch  | this branch      |
| -------------- | --------- | ---------------- | ---------------- | ---------------- |
| `rt_label`     | host      | 186,250 + 35,245 | (= main)         | 185,626 + 35,544 |
| `rt_label`     | x86-64-v3 | 242,477 + 48,376 | 212,790 + 34,917 | 250,957 + 49,459 |
| `rt_label`     | x86-64-v2 | 264,341 + 63,286 | 213,104 + 40,626 | 272,821 + 64,881 |
| `rt_label`     | baseline  | 256,735 + 66,706 | 184,144 + 29,214 | 256,863 + 70,499 |
| `rt_label`     | aarch64   | 212,224 + 33,364 | (= main)         | 220,672 + 34,224 |
| `rt_enc_label` | host      | 167,960 + 19,618 | (= main)         | 169,560 + 18,739 |
| `rt_enc_label` | x86-64-v3 | 219,823 + 30,580 | 190,212 + 22,434 | 199,608 + 25,230 |
| `rt_enc_label` | x86-64-v2 | 245,147 + 42,501 | 190,448 + 27,125 | 200,656 + 32,520 |
| `rt_enc_label` | baseline  | 245,413 + 46,680 | 165,840 + 19,891 | 196,884 + 37,262 |
| `rt_enc_label` | aarch64   | 189,888 + 23,288 | (= main)         | 169,760 + 21,684 |
| `ct_utf8_1252` | host      | 10,178 + 10,616  | (= main)         | 9,498 + 7,489    |
| `ct_utf8_1252` | x86-64-v3 | 59,933 + 20,333  | 30,242 + 10,948  | 47,792 + 14,492  |
| `ct_utf8_1252` | x86-64-v2 | 81,669 + 30,574  | 30,448 + 15,084  | 48,776 + 20,943  |
| `ct_utf8_1252` | baseline  | 81,191 + 32,854  | 8,672 + 7,013    | 39,692 + 24,268  |
| `ct_utf8_1252` | aarch64   | 29,952 + 10,720  | (= main)         | 18,048 + 9,236   |

The CJK programs (`ct_sjis`, `ct_gb18030`, `ct_euc_kr`) are byte for byte
the same on every target: they call neither utf nor the staging.

- A one-encoding single-byte decoder is 4.9x smaller on x86-64-v3, 6.5x
  on -v2, 14x on the baseline, 2.1x on aarch64 and 2.2x on the host.
  Against utf without dispatch it is 2.0x smaller on -v3 and -v2, and 1.9x
  larger on the baseline (6,435 against 3,422), where utf's scalar code is
  smaller than the per-character stores and the lane loads of the gather.
- Most of what is left on -v3, -v2 and aarch64 is the shuffle tables,
  8,448 bytes for decode and 4,096 for encode. A one-encoding encoder is
  7.3x smaller on -v3, 9.4x on -v2, 13x on the baseline, 3.2x on aarch64
  and 1.2x on the host; against utf without dispatch 3.3-3.5x smaller on
  -v3 and -v2, and 1.2x larger on the baseline. On the host it is 137
  bytes more `.rodata` (index vectors LLVM builds for the byte interleave
  of 128 lanes) and 1,235 bytes less `.text`.
- A program that links utf anyway pays both: `Decoder` grows 8.5 KB of
  tables on -v3, -v2 and aarch64 (and 3.8 KB of code on the baseline),
  because utf's transcoders stay for UTF-8 and UTF-16 and the staging's
  tables come on top. `Encoder` shrinks 20 to 58 KB, because utf's
  UTF-8-to-UTF-16 kernels were only linked for the staging. utf without
  dispatch is smaller than either for the programs that link utf anyway:
  it takes 43 to 110 KB off `Decoder` off the host.

## 3. How the transcoder got here

The first full run (raw output not kept here, the same arms and rows as
section 4) measured an earlier form of this branch: 3-byte code points
packed two at a time with eight-byte stores, units built in 16-bit lanes
from widened bytes, and a window's carry taken from its masks. Against utf
without dispatch it was 0.86x decoding to UTF-8 and 0.98x encoding from it
on x86-64-v3, and 0.92x and 0.83x on -v2. Two cases were far worse:

- Decoding text of 3-byte code points: x-user-defined `nonascii-65536`
  0.81 GB/s on -v3 against utf's 3.18 (0.25x, and below encoding_rs's
  0.97) and windows-874 0.66 against 1.81 (0.36x).
- Encoding on -v2: 0.75 GB/s against 1.27 for windows-1252 `nonascii`.
  LLVM built the carry's bit masks a lane at a time with `pextrb` and
  `pinsrb` on SSE (about 100 instructions a window).

The microbenchmark of section "Commands" (Gunits/s decoding UTF-16 to
UTF-8, GB/s encoding UTF-8 to UTF-16), that form and then the head, each
against utf for the same level without dispatch:

```text
                     decode own/utf (Gunits/s)          encode own/utf (GB/s)
level  text      first form       head              first form       head
v3     Russian   5.195 / 5.892    5.173 / 5.705     2.059 / 2.131    2.022 / 2.163
v3     Thai      0.888 / 3.310    2.843 / 3.293     1.942 / 2.654    2.010 / 2.649
v3     x-u-d     0.886 / 4.001    2.837 / 3.995     1.936 / 2.720    2.014 / 2.735
v3     German    5.015 / 5.717    5.343 / 5.715     1.938 / 1.790    2.079 / 1.798
v2     Russian   4.347 / 3.939    4.571 / 4.209     0.877 / 1.919    1.931 / 1.951
v2     Thai      0.786 / 1.926    1.953 / 2.036     0.882 / 2.322    1.889 / 2.325
v2     x-u-d     0.783 / 2.808    1.882 / 2.718     0.880 / 2.510    1.951 / 2.526
v2     German    4.499 / 4.076    4.728 / 4.209     0.906 / 1.635    1.946 / 1.710
base   Russian   1.414 / 0.557    1.413 / 0.530     0.708 / 0.817    0.959 / 0.783
base   Thai      0.769 / 0.442    0.760 / 0.419     0.716 / 0.867    0.965 / 0.838
base   x-u-d     0.767 / 0.514    0.758 / 0.497     0.714 / 0.807    0.934 / 0.781
base   German    1.502 / 0.967    1.551 / 0.827     0.712 / 0.967    0.963 / 0.916
host   Russian   9.361 / 6.913   11.793 / 7.436     3.696 / 5.048    4.960 / 5.253
host   Thai      3.041 / 4.528    4.548 / 4.571     3.822 / 5.293    4.986 / 5.137
host   x-u-d     3.134 / 4.669    4.382 / 4.404     3.856 / 4.296    4.798 / 4.317
host   German    9.694 / 7.164   11.401 / 7.415     3.794 / 5.005    4.960 / 5.026
```

What changed, each measured on the microbenchmark before it was kept:

- 3-byte decode on the shuffle targets: a 256-entry table of four-code-
  point shuffles with a separate length table, instead of two-code-point
  shuffles assembled from u64 entries and stored eight bytes at a time
  (0.89 to 1.30 Gunits/s on -v3); bytes built in 16-bit lanes instead of
  32-bit ones (to 1.73); AVX2's `vpshufb` on two groups at once, whose
  index vector is two 16-byte table loads, and both 16-unit blocks after
  one failed 32-unit test (to 2.2); and the four table indexes as bytes of
  one `pmovmskb` instead of two masks shifted apart (to 2.9). An
  all-three-byte path with a constant shuffle was slower (1.45): LLVM
  merged its four overlapping stores at known offsets into `pextrb` and
  `pinsrb` sequences.
- 3-byte decode with `vpcompressb`: which bytes to keep from the bytes
  themselves (every lane's first byte, and every nonzero byte, since only
  ASCII has zero bytes) instead of from a length per lane multiplied out
  with `vpmulld`, and the length as a `popcnt` of that mask (Thai 3.0 to
  4.5).
- Encode: units built as a low and a high byte vector and interleaved,
  instead of from bytes widened to 16-bit lanes, and the carry counted
  from the window's last two bytes instead of from its masks: together
  host 3.7-3.9 to 4.8-5.0 GB/s, -v3 unchanged at 2.0, -v2 0.9 to 1.9,
  baseline 0.71 to 0.96. The -v2 and baseline gains are the carry's (the
  `pextrb`/`pinsrb` sequences above are gone from the loop).

Rejected earlier in this wave (each measured, numbers from the runs of
that version): a 4-byte store per lane on decode (0.44x main); 16-entry
shuffle tables of four lanes (-v3 0.62x); decoding block by block straight
to UTF-8 without the stage (0.84x host, 0.73x -v3); in `utf8ToBmp`, a
window starting where the last one's characters ended (1.16 GB/s against
3.68 with the fixed stride, host); in the gather, stores and a reload
(no gain); and, after the final run, a last window of what is left of
the input padded with zeros, so that short input and the end of long input
stay vectorized and `staged_min` is 64 everywhere ("Raw output", the
EncodeUtf8 run): the host's `nonascii-64` 1.46x the head, but EncodeUtf8
over all 1,364 rows 1.01x on the host, 0.98x on -v3, 0.97x on -v2 and
0.95x on the baseline, with the host's long `nonascii` rows at 0.88-0.90x
(LLVM kept more of the loop's state in memory). Not kept: the host's
64-byte non-ASCII encode stays at 0.65x origin/main (section 4).

Where the head is still slower than utf at the same level, on the
microbenchmark: -v3 decodes Russian and German at 0.91-0.94x, Thai at
0.86x and x-user-defined at 0.71x (utf has a path for blocks of only
3-byte code points), and encodes Thai and x-user-defined at 0.74-0.76x;
-v2 decodes x-user-defined at 0.69x and Thai at 0.96x, and encodes them
at 0.77-0.81x. The host and baseline are at or above utf everywhere but
the host's encode of Russian, Thai and German (0.94-0.99x).

## 4. Speed

The final run, every single-byte row (section "Commands"). Geomean over
each operation's 1,364 rows of the per-row median paired ratio (the full
tables, by shape and by size, with each arm's geomean GB/s, are in "Raw
output"):

```text
operation     host       x86-64-v3          x86-64-v2          baseline
              /main      /nd      /main     /nd      /main     /nd      /main
DecodeUtf8    1.096      0.946    0.970     1.031    0.965     1.531    0.647
DecodeUtf16   1.001      0.979    1.003     0.999    0.998     0.984    0.888
EncodeUtf8    0.998      0.979    0.879     1.002    0.900     1.168    0.787
EncodeUtf16   0.997      1.000    0.999     1.008    1.000     0.998    1.000
```

`/nd` is against origin/main with utf's dispatch off, the speed an older
CPU of that level gets from main; `/main` against origin/main as built,
which on this AVX-512 CPU runs utf's AVX-512 kernels whatever the build
level. EncodeUtf16 runs no changed code at any level, and DecodeUtf16
none but the baseline's: their spread around 1.000 is this run's noise
and placement.

- **Host**: decode to UTF-8 1.10x main (`mixed` and `nonascii` 1.19-1.20x,
  16-byte non-ASCII rows 1.77-1.83x), encode from UTF-8 1.00x with
  `nonascii` 0.90x: 0.65x at 64 bytes and 0.86x at 256, because the host's
  64-byte window leaves input under 66 bytes, and the last 64 of a 256-byte
  call, to the character-at-a-time path; 0.99-1.00x at 4 KiB and above.
- **x86-64-v3** against utf AVX2 (`nd`): decode to UTF-8 0.95x, encode
  from UTF-8 0.98x. The decode loss is concentrated in 16-byte rows (0.87x,
  154 rows below 0.90), which are all ASCII (`ascii`, `csv`, `mail`,
  `subtitles`, `web` at 16 bytes start with ASCII) and run no changed code:
  a placement run of those rows (`ascii`, `web` and `nonascii` at 16 and
  256 bytes, four placements of each build) puts this branch's -v3 build
  at 0.83x to 1.16x origin/main's on `ascii` depending on placement, and
  `nonascii` at 0.985-1.000x. At 4 KiB and above, 0.95-0.98x by shape.
- **x86-64-v2** against utf SSE4 (`nd`): decode 1.03x, encode 1.00x.
- **Baseline** against utf's scalar code (`nd`, what a CPU without SSSE3
  gets from main): decode to UTF-8 1.53x (2.4-2.6x at 64 KiB on realistic
  text), encode 1.17x. Against main as built on this CPU, where utf's
  dispatch reached its AVX-512 kernels: decode to UTF-8 0.65x and encode
  0.79x. **A baseline build running on a newer CPU loses utf's run-time
  dispatch**: that is the cost of this change, and the decision of
  section 6.

Against encoding_rs on the rows it has (geomean ratio; rows with the
median paired ratio below 1, all sizes / 65,536 bytes):

```text
arm        DecodeUtf8          DecodeUtf16         EncodeUtf8          EncodeUtf16
zig        3.853x   8 /  3     4.171x   0 /  0     3.609x   7 /  0     4.617x   0 /  0
main       3.517x   9 /  4     4.162x   0 /  0     3.619x   3 /  0     4.625x   0 /  0
newv3      2.751x   2 /  0     2.848x   2 /  0     2.738x  38 /  9     3.573x   0 /  0
mainv3     2.832x   4 /  0     2.843x   0 /  0     3.127x  10 /  1     3.574x   0 /  0
mainndv3   2.899x   6 /  0     2.909x   0 /  0     2.793x  18 /  2     3.568x   0 /  0
newv2      2.477x  17 /  2     2.563x   1 /  0     2.420x  61 / 13     2.789x   7 /  1
mainv2     2.570x  12 /  0     2.568x   3 /  0     2.703x  14 /  2     2.788x   8 /  1
mainndv2   2.402x   5 /  0     2.566x   2 /  0     2.415x  41 /  5     2.766x  10 /  2
newv1      1.516x 259 / 29     1.960x   5 /  0     2.052x 105 / 19     2.663x  10 /  1
mainv1     2.346x   1 /  0     2.196x 146 / 28     2.640x  25 /  4     2.664x  10 /  1
mainndv1   0.985x 727 /147     1.981x 173 / 30     1.743x 140 / 26     2.668x  10 /  2
```

- The baseline's DecodeUtf16 rows below encoding_rs go from 146 (28 at 64
  KiB) to 5 (none at 64 KiB): `nonascii` 0.90x → 1.14x geomean (section 5).
- Its DecodeUtf8 rows below encoding_rs go from 727 (utf without dispatch)
  or 1 (utf's AVX-512 kernels) to 259. They are Latin text in the
  realistic shapes: macintosh's `subtitles`, `mail`, `web`, `csv` at 64
  KiB 0.52-0.59x, windows-1252 0.63-0.69x, ISO-8859-3 0.64-0.71x,
  x-user-defined 0.65-0.72x; and 16-byte `mixed` and `invalid` rows.
  Sparse non-ASCII goes through the stage and the per-character stores.
- x86-64-v3 and -v2 encode from UTF-8: 38 and 61 rows below encoding_rs,
  against 18 and 41 for utf without dispatch, mostly `csv`, `mail`,
  `subtitles` and `web` at 64 to 256 bytes, where encoding_rs's ASCII
  loop and our staged path are close.

For the README's per-CPU table (single-byte rows, 28 encodings without
x-user-defined, geomean ratio to encoding_rs; this run, 3 rounds, so
read against the same run's `main` column, not against the README's
10-round numbers):

```text
                 64 KiB                          16 bytes
                 host    x86-64-v3  baseline     host    x86-64-v3  baseline
decode  main     7.31x   5.23x      3.41x        1.69x   1.42x      1.49x
decode  branch   7.51x   5.15x      2.50x        1.90x   1.45x      1.33x
decode  main nd  -       5.24x      1.68x        -       1.57x      1.25x
encode  main     6.91x   5.35x      3.95x        2.25x   1.98x      1.82x
encode  branch   6.98x   4.91x      3.30x        2.31x   2.01x      1.80x
encode  main nd  -       4.89x      2.71x        -       2.00x      1.81x
```

Rows below encoding_rs at 64 KiB, decode and encode: host 3 and 0 (main 4
and 0), x86-64-v3 0 and 6 (main 0 and 1), baseline 24 and 14 (main 28 and
5; main without dispatch 169 and 21).

## 5. The baseline lookup

### x86-64-v2 first

origin/main built for x86-64-v2 (`mainv2`, SSE4.2, so SSSE3's `pshufb`
lookup) against encoding_rs, DecodeUtf16 `nonascii` in the final run:
1.64-1.85x geomean at each size from 16 bytes to 1 MiB, the lowest row
1.04x, no row below. origin/main's baseline build (`mainv1`) in the same
run: 0.84-0.93x at 64 bytes and above, 27 or 28 of the 29 encodings
below encoding_rs at each size (the README run saw 0.61-0.63x at 64 KiB;
this lane loop moves with placement). So the gap is the
baseline's alone: Intel CPUs since Core 2 (2006) and AMD's since Bobcat
and Bulldozer (2011) have SSSE3, and a build for x86-64-v2 or above takes
the shuffle.

### The gather

A baseline build runs on every x86-64 CPU, and AGENTS.md makes
encoding_rs the bar on every row, so this branch adds `gatherBlock`
(section 1) rather than accepting the gap. Its placement run, 372 rows of
DecodeUtf16 at four placements (`pa` the gather tested with `@popCount`,
`pb` with the bit-clearing test of the head, `pm` origin/main), spread of
each row's GB/s across the four placements:

```text
arms        median     p90     max  >1.10  >1.20  rows
pa           1.039   1.096    1.58     34      6  372
pb           1.040   1.096    1.65     35      9  372
pm           1.179   1.250    1.36    240    134  372
```

The gather's arms move half as much with placement as origin/main's,
whose lane loop is placement-sensitive at baseline (single-byte-20261102.md
saw the same). Per placement, geomean ratio by shape (columns: `pa/pm`,
`pb/pm`, `pb/pa`, `pm/rust`, `pb/rust`):

```text
placement 0
  DecodeUtf16             348  0.956  1.023  1.069  2.008  2.055
  DecodeUtf16/csv          87  0.878  0.935  1.064  1.932  1.808
  DecodeUtf16/mixed        87  0.869  0.931  1.069  4.810  4.477
  DecodeUtf16/nonascii     87  1.253  1.354  1.082  0.814  1.105
  DecodeUtf16/web          87  0.875  0.929  1.060  2.146  1.993
placement 16
  DecodeUtf16             348  0.916  0.996  1.085  2.072  2.064
  DecodeUtf16/csv          87  0.845  0.916  1.083  2.000  1.829
  DecodeUtf16/mixed        87  0.790  0.891  1.123  5.050  4.503
  DecodeUtf16/nonascii     87  1.204  1.300  1.081  0.848  1.103
  DecodeUtf16/web          87  0.877  0.929  1.055  2.152  1.999
placement 32
  DecodeUtf16             348  0.925  0.966  1.045  2.094  2.022
  DecodeUtf16/csv          87  0.870  0.906  1.043  1.961  1.777
  DecodeUtf16/mixed        87  0.770  0.781  1.020  5.523  4.314
  DecodeUtf16/nonascii     87  1.200  1.299  1.079  0.849  1.102
  DecodeUtf16/web          87  0.910  0.946  1.040  2.089  1.978
placement 48
  DecodeUtf16             348  0.864  0.917  1.062  2.255  2.069
  DecodeUtf16/csv          87  0.779  0.828  1.065  2.214  1.842
  DecodeUtf16/mixed        87  0.747  0.787  1.056  5.724  4.501
  DecodeUtf16/nonascii     87  1.188  1.287  1.084  0.856  1.103
  DecodeUtf16/web          87  0.807  0.841  1.042  2.381  2.004
```

- `nonascii` goes from 0.81-0.86x encoding_rs to 1.10x, every placement.
  In the final run (section 4) the baseline's `nonascii` rows at 64 KiB
  went from 0.84x (0.76 to 1.07) to 1.07x (1.00 to 1.31), and windows-874's
  realistic rows from 0.93-1.27x to 1.22-1.69x.
- The bit-clearing test beats `@popCount` by 4.5-8.5% at every placement:
  the baseline has no `popcnt`, and LLVM's software popcount sits on every
  non-ASCII block.
- Realistic text pays: across placements `csv` 0.83-0.94x origin/main,
  `mixed` 0.79-0.93x, `web` 0.84-0.95x, still 1.8x, 4.3-4.5x and 2.0x
  encoding_rs. Part of it is the branch between the two paths, which
  `mixed` text takes both ways from block to block.

## 6. Decisions for the owner

1. **Take the transcoder (recommended), knowing what a baseline build on a
   newer CPU loses.** For the single-byte programs it is 4.9-14x smaller
   off the host and 2.2x on it, and against utf at the same level without
   dispatch it is as fast or faster everywhere but x86-64-v3's decode to
   UTF-8 (0.95x, mostly placement on all-ASCII 16-byte rows) and 3-byte
   text on -v3 and -v2 (0.7-0.9x on the microbenchmark); on the host,
   non-ASCII encode of 64 and 256 bytes is 0.65x and 0.86x origin/main
   (section 4). What it gives up
   is utf's run-time dispatch: a baseline x86-64 build, which is what a
   distribution ships, ran utf's AVX2 or AVX-512 kernels for the staging on
   a newer CPU and now runs our SSE2 stores: on this CPU 0.65x origin/main
   decoding to UTF-8 and 0.79x encoding from UTF-8, 259 decode rows
   below encoding_rs. On a CPU without SSSE3 it is 1.5x and 1.17x
   faster than origin/main. Alternatives:
   - Keep utf, with dispatch, for the staging in baseline builds only
     (`pack == .store` on x86-64), and this transcoder elsewhere: the
     baseline keeps origin/main's speed on new CPUs and its 90 KB, the other
     targets get this branch. About 20 lines in `codec.zig`.
   - A dispatch of our own at baseline: more code and tables, against the
     size goal; not recommended.
2. **Ask utf for a no-dispatch option anyway.** It is not better than this
   transcoder for the single-byte programs (2x larger on -v3 and -v2, and
   at baseline as small but 0.65x as fast decoding), but every program that
   decodes UTF-8 or UTF-16 links utf regardless, and without dispatch
   `Decoder` is 43 KB smaller on -v3, 74 KB on -v2 and 110 KB on the
   baseline. That is utf's change to make and the owner's to request; it
   is independent of this one.
3. **Keep the baseline gather (recommended).** It brings every
   single-byte encoding's `nonascii` decode to UTF-16 from 0.81-0.90x
   encoding_rs to 1.10-1.14x and halves the baseline's placement spread,
   and costs realistic text 5-20% (still 1.8x encoding_rs or more). The
   alternative is accepting the gap for baseline builds: an x86-64-v2 build
   (Intel since 2008, AMD since 2011) has no gap (section 5).
4. **The full `Decoder` grows 8.5 KB** on -v3, -v2 and aarch64 (the
   staging's shuffle tables beside utf's), and 3.8 KB of code on the
   baseline. `Encoder` shrinks 21-58 KB off the host.

## 7. Gates

On the head of `wave5-single-byte-size` before this file was added (the
same code), on CPUs 0 and 1 during the final run:

```text
=== ci: just ci (01:31:23)
=== ci exit=0 (01:51:03)
=== oracle: just oracle 20000 (01:51:03)
=== oracle exit=0 (01:53:13)
=== fuzz: just fuzz 600 (01:53:13)
=== fuzz exit=0 (02:03:13)
=== fuzzv3: fuzz of every single-byte encoding and x-user-defined, 20 s each, -Dcpu=x86_64_v3 (02:03:13)
=== fuzzv3 exit=0 (02:13:34)
=== fuzzbase: the same, -Dcpu=x86_64 (02:13:34)
=== fuzzbase exit=0 (02:23:55)
=== rg setRuntimeSafety src:
=== rg exit=1 (1 means no match)
oracle: 78777837 comparisons with encoding_rs, 0 mismatches
fuzz: 4691832 inputs in 600s, 0 findings
fuzz x86_64_v3 overall exit=0
fuzz x86_64 overall exit=0
```

An earlier `just ci` on the reworked encoder failed `test-big-endian`
(IBM866 from UTF-8 and from UTF-16 differed on s390x): the byte interleave
put the high byte second. Fixed, then every gate above re-run.

## Raw output

### Sizes (`size -A`, net of `size-none`, bytes: .rodata + .text)

origin/main `0bc8ec4`:

```text
host     ct_1252             1049 +    5781
host     ct_enc_1252         1775 +    5711
host     ct_sjis            16530 +    3298
host     ct_gb18030         48762 +    4892
host     ct_euc_kr          47562 +    2659
host     rt_label          186250 +   35245
host     rt_enc_label      167960 +   19618
host     ct_utf8_1252       10178 +   10616
v3       ct_1252            51012 +   12250
v3       ct_enc_1252        54338 +   13565
v3       ct_sjis            16552 +    3304
v3       ct_gb18030         48784 +    4900
v3       ct_euc_kr          47560 +    2666
v3       rt_label          242477 +   48376
v3       rt_enc_label      219823 +   30580
v3       ct_utf8_1252       59933 +   20333
v2       ct_1252            72788 +   16834
v2       ct_enc_1252        79562 +   19952
v2       ct_sjis            16528 +    3306
v2       ct_gb18030         48768 +    4904
v2       ct_euc_kr          47536 +    2645
v2       rt_label          264341 +   63286
v2       rt_enc_label      245147 +   42501
v2       ct_utf8_1252       81669 +   30574
base     ct_1252            72550 +   17350
base     ct_enc_1252        79804 +   21503
base     ct_sjis            16528 +    3255
base     ct_gb18030         48752 +    4823
base     ct_euc_kr          47552 +    2645
base     rt_label          256735 +   66706
base     rt_enc_label      245413 +   46680
base     ct_utf8_1252       81191 +   32854
a64      ct_1252            21168 +    4800
a64      ct_enc_1252        24608 +    8384
a64      ct_sjis            16528 +    3308
a64      ct_gb18030         48768 +    4832
a64      ct_euc_kr          47552 +    2920
a64      rt_label          212224 +   33364
a64      rt_enc_label      189888 +   23288
a64      ct_utf8_1252       29952 +   10720
```

origin/main with utf's dispatch off (aarch64 has none, so it is main's):

```text
nd-v3    ct_1252            21381 +    5050
nd-v3    ct_enc_1252        24739 +    7615
nd-v3    ct_sjis            16552 +    3304
nd-v3    ct_gb18030         48784 +    4900
nd-v3    ct_euc_kr          47560 +    2666
nd-v3    rt_label          212790 +   34917
nd-v3    rt_enc_label      190212 +   22434
nd-v3    ct_utf8_1252       30242 +   10948
nd-v2    ct_1252            21728 +    6986
nd-v2    ct_enc_1252        24912 +   10272
nd-v2    ct_sjis            16528 +    3306
nd-v2    ct_gb18030         48768 +    4904
nd-v2    ct_euc_kr          47536 +    2645
nd-v2    rt_label          213104 +   40626
nd-v2    rt_enc_label      190448 +   27125
nd-v2    ct_utf8_1252       30448 +   15084
nd-base  ct_1252              320 +    3102
nd-base  ct_enc_1252          352 +    6322
nd-base  ct_sjis            16528 +    3255
nd-base  ct_gb18030         48752 +    4823
nd-base  ct_euc_kr          47552 +    2645
nd-base  rt_label          184144 +   29214
nd-base  rt_enc_label      165840 +   19891
nd-base  ct_utf8_1252        8672 +    7013
nd-a64   ct_1252            21168 +    4800
nd-a64   ct_enc_1252        24608 +    8384
nd-a64   ct_sjis            16528 +    3308
nd-a64   ct_gb18030         48768 +    4832
nd-a64   ct_euc_kr          47552 +    2920
nd-a64   rt_label          212224 +   33364
nd-a64   rt_enc_label      189888 +   23288
nd-a64   ct_utf8_1252       29952 +   10720
```

This branch:

```text
host     ct_1252              354 +    2698
host     ct_enc_1252         1912 +    4476
host     ct_sjis            16530 +    3298
host     ct_gb18030         48762 +    4892
host     ct_euc_kr          47562 +    2659
host     rt_label          185626 +   35544
host     rt_enc_label      169560 +   18739
host     ct_utf8_1252        9498 +    7489
v3       ct_1252             9352 +    3600
v3       ct_enc_1252         4456 +    4819
v3       ct_sjis            16552 +    3304
v3       ct_gb18030         48784 +    4900
v3       ct_euc_kr          47560 +    2666
v3       rt_label          250957 +   49459
v3       rt_enc_label      199608 +   25230
v3       ct_utf8_1252       47792 +   14492
v2       ct_1252             9536 +    4333
v2       ct_enc_1252         4576 +    5989
v2       ct_sjis            16528 +    3306
v2       ct_gb18030         48768 +    4904
v2       ct_euc_kr          47536 +    2645
v2       rt_label          272821 +   64881
v2       rt_enc_label      200656 +   32520
v2       ct_utf8_1252       48776 +   20943
base     ct_1252              544 +    5891
base     ct_enc_1252          608 +    7105
base     ct_sjis            16528 +    3255
base     ct_gb18030         48752 +    4823
base     ct_euc_kr          47552 +    2645
base     rt_label          256863 +   70499
base     rt_enc_label      196884 +   37262
base     ct_utf8_1252       39692 +   24268
a64      ct_1252             9264 +    3316
a64      ct_enc_1252         4432 +    5740
a64      ct_sjis            16528 +    3308
a64      ct_gb18030         48768 +    4832
a64      ct_euc_kr          47552 +    2920
a64      rt_label          220672 +   34224
a64      rt_enc_label      169760 +   21684
a64      ct_utf8_1252       18048 +    9236
```

### The final run

Per pair: geomean of the per-row median paired ratio, rows below 0.95, rows below 0.90; per arm, geomean GB/s. Rows where every listed arm has the row (encoding_rs lacks IBM437 and IBM850).

#### against main, every row (geomean GB/s per arm; per pair: geomean ratio, rows < 0.95, rows < 0.90)

```text
group                           rows      zig     main    newv3   mainv3 mainndv3    newv2   mainv2 mainndv2    newv1   mainv1 mainndv1       zig/main   newv3/mainv3 newv3/mainndv3   newv2/mainv2 newv2/mainndv2   newv1/mainv1 newv1/mainndv1
DecodeUtf8                      1364    3.835    3.495    2.750    2.834    2.903    2.484    2.569    2.409    1.528    2.360    0.998 1.096 102  20 0.970 616 377 0.946 535 290 0.965 692 409 1.031 194  67 0.647 1047 960 1.531  37   5
DecodeUtf8/ascii                 186   13.051   12.747   11.631   12.565   12.653   12.772   12.057   12.131   13.359   12.948   12.755 1.024  14   7 0.928  95  52 0.922  92  62 1.057   5   1 1.055  37  11 1.034  24   3 1.048  13   1
DecodeUtf8/csv                   155    3.413    3.201    2.606    2.759    2.780    2.374    2.504    2.336    1.477    2.452    0.925 1.069  10   2 0.940  81  55 0.931  75  43 0.949  73  51 1.019  27   8 0.602 130 115 1.592   4   0
DecodeUtf8/invalid               155    2.067    1.813    1.311    1.299    1.350    1.021    1.169    0.990    0.481    1.037    0.295 1.138  18   0 1.010  88  40 0.971  50  10 0.874 119 110 1.035   9   2 0.464 154 154 1.632   0   0
DecodeUtf8/mail                  155    4.214    4.099    3.470    3.735    3.810    3.334    3.396    3.217    2.286    3.293    1.542 1.026  19   3 0.928  88  65 0.913  99  54 0.977  75  40 1.031  36  11 0.693 103  89 1.482   7   2
DecodeUtf8/mixed                 186    2.754    2.290    1.596    1.534    1.618    1.315    1.356    1.277    0.627    1.316    0.412 1.200   1   0 1.039  43  20 0.986  18   8 0.967 124  62 1.029   4   0 0.477 185 185 1.521   0   0
DecodeUtf8/nonascii              186    2.739    2.303    1.587    1.534    1.637    1.303    1.356    1.289    0.637    0.865    0.319 1.189   0   0 1.037  49  23 0.968  35  19 0.961 129  61 1.012  12  11 0.737 184 181 1.998   0   0
DecodeUtf8/subtitles             155    3.454    3.242    2.761    2.896    2.960    2.522    2.625    2.479    1.574    2.515    0.972 1.063   9   3 0.952  69  52 0.932  68  42 0.957  76  42 1.016  29   9 0.621 131 114 1.616   5   0
DecodeUtf8/web                   186    4.089    3.848    3.088    3.337    3.262    2.932    3.013    2.782    1.918    2.902    1.237 1.059  31   5 0.927 103  70 0.942  98  52 0.970  91  42 1.049  40  15 0.661 136 119 1.554   8   2
DecodeUtf16                     1364    5.777    5.773    3.969    3.959    4.047    3.570    3.576    3.572    2.741    3.086    2.786 1.001 119  23 1.003 167  17 0.979 287  36 0.998 249 106 0.999 252  96 0.888 953 879 0.984 592 410
DecodeUtf16/ascii                186   10.676   10.486    9.332    9.033    9.403    9.168    8.936    8.888    8.758    9.605    9.363 1.022   0   0 1.031   2   0 0.988  24   1 1.024  29   4 1.032  20   0 0.912  95  87 0.938  81  61
DecodeUtf16/csv                  155    5.433    5.459    3.960    3.916    4.032    3.563    3.641    3.615    2.879    3.511    3.073 0.995  22   6 1.013   5   1 0.980  24   4 0.981  48  23 0.985  51  22 0.823 122 108 0.940  72  63
DecodeUtf16/invalid              155    4.329    4.320    2.501    2.563    2.573    2.159    2.154    2.165    1.386    1.670    1.456 0.999   5   1 0.976  36   4 0.970  40   8 1.006   5   1 1.000   9   0 0.827 147 144 0.955  76  32
DecodeUtf16/mail                 155    6.616    6.631    4.944    4.810    5.010    4.524    4.589    4.549    3.764    4.460    4.055 1.003  24   2 1.026   8   1 0.983  30   3 0.983  52  24 0.991  49  24 0.845 122 107 0.930  80  78
DecodeUtf16/mixed                186    4.571    4.571    2.631    2.706    2.697    2.262    2.254    2.269    1.619    2.006    1.710 1.000   4   1 0.975  44   3 0.975  54   4 1.007   3   1 0.997   8   1 0.805 180 176 0.944 107  19
DecodeUtf16/nonascii             186    4.590    4.582    2.640    2.709    2.725    2.260    2.248    2.261    1.487    1.172    1.102 0.999   6   0 0.974  49   6 0.969  54   9 1.003   4   0 0.998   8   1 1.267   0   0 1.345   0   0
DecodeUtf16/subtitles            155    5.693    5.711    4.179    4.137    4.252    3.773    3.820    3.827    2.972    3.586    3.161 0.994  28   4 1.011  13   1 0.979  27   4 0.986  44  24 0.988  48  24 0.830 129 113 0.941  66  58
DecodeUtf16/web                  186    6.017    6.066    4.491    4.406    4.566    4.135    4.176    4.139    3.259    3.909    3.562 0.995  30   9 1.019  10   1 0.985  34   3 0.987  64  29 0.995  59  24 0.833 158 144 0.914 110  99
EncodeUtf8                      1364    2.074    2.080    1.580    1.798    1.613    1.394    1.549    1.394    1.193    1.514    1.020 0.998 304 141 0.879 816 641 0.979 435 177 0.900 759 529 1.002 272 119 0.787 814 765 1.168  95  48
EncodeUtf8/ascii                 186   10.652   10.540   11.040   11.240   11.369   10.491   10.607   10.844   11.268   10.699   11.292 1.011  55  10 0.980  39   6 0.968  61  13 0.991  60  36 0.973  72  23 1.047   3   0 0.995   9   0
EncodeUtf8/csv                   155    2.273    2.241    1.760    1.989    1.798    1.596    1.750    1.593    1.335    1.706    1.171 1.019  23  11 0.886  76  72 0.979  37  15 0.911  74  65 1.004  19   8 0.780  81  75 1.139  18   6
EncodeUtf8/invalid               155    0.678    0.690    0.475    0.518    0.450    0.382    0.411    0.362    0.327    0.395    0.244 0.984  40  18 0.917 103  70 1.054   7   1 0.932  90  44 1.059   2   0 0.825 130 117 1.335   0   0
EncodeUtf8/mail                  155    3.207    3.103    2.533    2.930    2.729    2.347    2.575    2.432    2.001    2.595    1.815 1.034  23   8 0.866  93  75 0.926  94  39 0.914  78  69 0.969  44  21 0.772  80  77 1.103  18  10
EncodeUtf8/mixed                 186    0.937    0.948    0.635    0.725    0.596    0.530    0.611    0.497    0.414    0.578    0.335 0.988  56  37 0.875 145 123 1.067   4   2 0.864 136  80 1.067   5   2 0.716 168 162 1.235   0   0
EncodeUtf8/nonascii              186    0.930    1.030    0.595    0.761    0.631    0.486    0.608    0.496    0.389    0.579    0.307 0.904  58  33 0.784 156 135 0.945  89  37 0.800 140  82 0.980  46  25 0.673 159 154 1.264   0   0
EncodeUtf8/subtitles             155    2.327    2.270    1.771    2.004    1.829    1.604    1.767    1.624    1.345    1.738    1.167 1.028  17   5 0.885  86  74 0.967  53  24 0.908  81  69 0.994  35  16 0.775  87  78 1.153  19  10
EncodeUtf8/web                   186    2.956    2.856    2.280    2.656    2.429    2.109    2.341    2.157    1.762    2.318    1.512 1.035  32  19 0.856 118  86 0.934  90  46 0.899 100  84 0.975  49  24 0.759 106 102 1.162  31  22
EncodeUtf16                     1364    5.087    5.100    3.929    3.931    3.924    3.067    3.064    3.042    2.930    2.930    2.931 0.997  80  21 0.999  39   0 1.000  49   0 1.000  37   2 1.008  40   3 1.000  49   4 0.998  61   4
EncodeUtf16/ascii                186   20.168   20.145   17.999   17.994   17.860   15.670   15.761   15.571   14.559   14.507   14.538 1.003   7   0 0.999   5   0 1.006   5   0 0.991  13   0 1.004  15   0 1.002   6   1 0.998   9   1
EncodeUtf16/csv                  155    6.643    6.665    5.167    5.179    5.153    4.050    4.060    4.009    3.847    3.848    3.869 0.995  10   3 0.998   4   0 1.002   3   0 1.000   4   1 1.010   4   1 1.000   3   1 0.995   4   0
EncodeUtf16/invalid              155    1.249    1.246    0.843    0.844    0.841    0.620    0.617    0.618    0.614    0.614    0.613 1.002   5   0 0.996   5   0 0.998   4   0 1.004   0   0 1.006   2   0 0.997   5   0 1.002   4   0
EncodeUtf16/mail                 155    8.841    8.862    7.103    7.114    7.098    5.735    5.746    5.666    5.440    5.435    5.438 0.997  11   4 1.000   3   0 0.998   5   0 1.000   4   0 1.012   3   0 1.002  10   1 1.002   6   1
EncodeUtf16/mixed                186    2.673    2.666    1.938    1.950    1.934    1.426    1.420    1.419    1.383    1.385    1.383 0.999   6   1 0.992   9   0 0.999  10   0 1.002   3   0 1.005   3   0 0.999   5   0 0.996   7   1
EncodeUtf16/nonascii             186    2.011    2.005    1.408    1.418    1.412    1.021    1.020    1.018    0.994    0.992    0.997 1.002   4   0 0.995   7   0 1.000   3   0 1.002   3   0 1.001   6   0 1.001   4   0 0.997  14   0
EncodeUtf16/subtitles            155    6.887    6.919    5.416    5.410    5.421    4.278    4.255    4.225    4.036    4.031    4.027 0.995   9   2 1.001   4   0 1.000  10   0 1.004   3   0 1.012   2   0 1.001   4   0 1.001   5   0
EncodeUtf16/web                  186    7.815    7.963    6.509    6.431    6.517    5.243    5.231    5.176    4.937    4.961    4.926 0.987  28  11 1.012   2   0 1.000   9   0 1.002   7   1 1.013   5   2 0.995  12   1 0.995  12   1
```

#### against main, by size

```text
group                           rows      zig     main    newv3   mainv3 mainndv3    newv2   mainv2 mainndv2    newv1   mainv1 mainndv1       zig/main   newv3/mainv3 newv3/mainndv3   newv2/mainv2 newv2/mainndv2   newv1/mainv1 newv1/mainndv1
DecodeUtf8/ascii                 186   13.051   12.747   11.631   12.565   12.653   12.772   12.057   12.131   13.359   12.948   12.755 1.024  14   7 0.928  95  52 0.922  92  62 1.057   5   1 1.055  37  11 1.034  24   3 1.048  13   1
DecodeUtf8/16                    248    1.491    1.225    1.179    1.157    1.345    1.276    1.113    1.243    1.013    1.160    0.931 1.214  37   8 1.017 154 153 0.873 156 154 1.146   4   1 1.029  10   2 0.872 176  92 1.087  23   0
DecodeUtf8/csv                   155    3.413    3.201    2.606    2.759    2.780    2.374    2.504    2.336    1.477    2.452    0.925 1.069  10   2 0.940  81  55 0.931  75  43 0.949  73  51 1.019  27   8 0.602 130 115 1.592   4   0
DecodeUtf8/invalid               155    2.067    1.813    1.311    1.299    1.350    1.021    1.169    0.990    0.481    1.037    0.295 1.138  18   0 1.010  88  40 0.971  50  10 0.874 119 110 1.035   9   2 0.464 154 154 1.632   0   0
DecodeUtf8/mail                  155    4.214    4.099    3.470    3.735    3.810    3.334    3.396    3.217    2.286    3.293    1.542 1.026  19   3 0.928  88  65 0.913  99  54 0.977  75  40 1.031  36  11 0.693 103  89 1.482   7   2
DecodeUtf8/mixed                 186    2.754    2.290    1.596    1.534    1.618    1.315    1.356    1.277    0.627    1.316    0.412 1.200   1   0 1.039  43  20 0.986  18   8 0.967 124  62 1.029   4   0 0.477 185 185 1.521   0   0
DecodeUtf8/nonascii              186    2.739    2.303    1.587    1.534    1.637    1.303    1.356    1.289    0.637    0.865    0.319 1.189   0   0 1.037  49  23 0.968  35  19 0.961 129  61 1.012  12  11 0.737 184 181 1.998   0   0
DecodeUtf8/subtitles             155    3.454    3.242    2.761    2.896    2.960    2.522    2.625    2.479    1.574    2.515    0.972 1.063   9   3 0.952  69  52 0.932  68  42 0.957  76  42 1.016  29   9 0.621 131 114 1.616   5   0
DecodeUtf8/web                   186    4.089    3.848    3.088    3.337    3.262    2.932    3.013    2.782    1.918    2.902    1.237 1.059  31   5 0.927 103  70 0.942  98  52 0.970  91  42 1.049  40  15 0.661 136 119 1.554   8   2
DecodeUtf8/64                    248    3.509    3.181    2.682    2.781    2.768    2.644    2.484    2.360    1.891    2.439    1.349 1.106   4   3 0.964 125  86 0.967 102  15 1.060  41  33 1.116  12   3 0.776 136 136 1.406   0   0
DecodeUtf8/256                   248    5.103    4.874    3.629    3.878    3.896    3.087    3.461    3.010    1.742    3.089    1.147 1.043  40   2 0.937 164  63 0.933 114  64 0.892 168 154 1.024  38  11 0.564 205 205 1.521   7   4
DecodeUtf8/4096                  248    5.168    4.887    3.596    3.736    3.755    2.845    3.223    2.896    1.590    2.988    0.970 1.056  13   4 0.963  77  38 0.957  94  34 0.880 202 106 0.982  79  35 0.531 218 217 1.635   2   0
DecodeUtf8/65536                 248    4.939    4.632    3.451    3.544    3.553    2.899    3.216    2.897    1.472    2.618    0.679 1.065   5   2 0.974  58  21 0.970  56  17 0.900 191  92 1.000  45  13 0.562 218 217 2.169   1   0
DecodeUtf8/1048576               124    5.688    5.140    3.350    3.470    3.291    3.015    3.271    2.882    1.734    2.700    1.084 1.105   3   1 0.965  38  16 1.019  13   6 0.920  86  23 1.053  10   3 0.643  94  93 1.594   4   1
DecodeUtf16/ascii                186   10.676   10.486    9.332    9.033    9.403    9.168    8.936    8.888    8.758    9.605    9.363 1.022   0   0 1.031   2   0 0.988  24   1 1.024  29   4 1.032  20   0 0.912  95  87 0.938  81  61
DecodeUtf16/16                   248    1.952    1.902    1.461    1.434    1.483    1.580    1.508    1.482    1.438    1.564    1.392 1.024   5   1 1.020   6   1 0.984  29   4 1.044   1   0 1.064   3   1 0.921 206 180 1.036   6   2
DecodeUtf16/csv                  155    5.433    5.459    3.960    3.916    4.032    3.563    3.641    3.615    2.879    3.511    3.073 0.995  22   6 1.013   5   1 0.980  24   4 0.981  48  23 0.985  51  22 0.823 122 108 0.940  72  63
DecodeUtf16/invalid              155    4.329    4.320    2.501    2.563    2.573    2.159    2.154    2.165    1.386    1.670    1.456 0.999   5   1 0.976  36   4 0.970  40   8 1.006   5   1 1.000   9   0 0.827 147 144 0.955  76  32
DecodeUtf16/mail                 155    6.616    6.631    4.944    4.810    5.010    4.524    4.589    4.549    3.764    4.460    4.055 1.003  24   2 1.026   8   1 0.983  30   3 0.983  52  24 0.991  49  24 0.845 122 107 0.930  80  78
DecodeUtf16/mixed                186    4.571    4.571    2.631    2.706    2.697    2.262    2.254    2.269    1.619    2.006    1.710 1.000   4   1 0.975  44   3 0.975  54   4 1.007   3   1 0.997   8   1 0.805 180 176 0.944 107  19
DecodeUtf16/nonascii             186    4.590    4.582    2.640    2.709    2.725    2.260    2.248    2.261    1.487    1.172    1.102 0.999   6   0 0.974  49   6 0.969  54   9 1.003   4   0 0.998   8   1 1.267   0   0 1.345   0   0
DecodeUtf16/subtitles            155    5.693    5.711    4.179    4.137    4.252    3.773    3.820    3.827    2.972    3.586    3.161 0.994  28   4 1.011  13   1 0.979  27   4 0.986  44  24 0.988  48  24 0.830 129 113 0.941  66  58
DecodeUtf16/web                  186    6.017    6.066    4.491    4.406    4.566    4.135    4.176    4.139    3.259    3.909    3.562 0.995  30   9 1.019  10   1 0.985  34   3 0.987  64  29 0.995  59  24 0.833 158 144 0.914 110  99
DecodeUtf16/64                   248    5.137    5.055    3.470    3.415    3.643    3.250    3.380    3.361    2.751    3.245    2.886 1.018   5   1 1.015  85   9 0.949 135  14 0.960 111  19 0.966  97   8 0.847 210 202 0.951 157 116
DecodeUtf16/256                  248    8.369    8.517    5.637    5.618    5.772    4.854    4.882    4.890    3.649    4.223    3.802 0.984  31   8 1.005  34   2 0.974  56  10 0.997  35  13 0.992  46  14 0.866 197 186 0.964 129  96
DecodeUtf16/4096                 248    9.129    9.189    6.001    6.049    6.047    4.817    4.877    4.918    3.495    4.097    3.646 0.994  39   7 0.991  19   4 0.989  27   5 0.989  58  45 0.979  62  45 0.850 159 136 0.958 126  73
DecodeUtf16/65536                248    8.073    8.187    5.621    5.686    5.664    4.745    4.779    4.807    3.142    3.390    3.150 0.987  35   6 0.989  16   1 0.992  28   3 0.994  44  29 0.989  44  28 0.926 124 122 0.994 123  95
DecodeUtf16/1048576              124    6.251    6.257    4.141    4.180    4.184    3.697    3.641    3.643    2.616    2.729    2.553 1.000   4   0 0.987   7   0 0.991  12   0 1.011   0   0 1.013   0   0 0.957  57  53 1.026  51  28
EncodeUtf8/ascii                 186   10.652   10.540   11.040   11.240   11.369   10.491   10.607   10.844   11.268   10.699   11.292 1.011  55  10 0.980  39   6 0.968  61  13 0.991  60  36 0.973  72  23 1.047   3   0 0.995   9   0
EncodeUtf8/16                    248    1.278    1.214    1.196    1.151    1.174    1.158    1.059    1.127    1.110    1.121    1.112 1.051  33  11 1.037   9   0 1.016  14   2 1.092   0   0 1.028   3   0 0.988  30  16 0.995  14   3
EncodeUtf8/csv                   155    2.273    2.241    1.760    1.989    1.798    1.596    1.750    1.593    1.335    1.706    1.171 1.019  23  11 0.886  76  72 0.979  37  15 0.911  74  65 1.004  19   8 0.780  81  75 1.139  18   6
EncodeUtf8/invalid               155    0.678    0.690    0.475    0.518    0.450    0.382    0.411    0.362    0.327    0.395    0.244 0.984  40  18 0.917 103  70 1.054   7   1 0.932  90  44 1.059   2   0 0.825 130 117 1.335   0   0
EncodeUtf8/mail                  155    3.207    3.103    2.533    2.930    2.729    2.347    2.575    2.432    2.001    2.595    1.815 1.034  23   8 0.866  93  75 0.926  94  39 0.914  78  69 0.969  44  21 0.772  80  77 1.103  18  10
EncodeUtf8/mixed                 186    0.937    0.948    0.635    0.725    0.596    0.530    0.611    0.497    0.414    0.578    0.335 0.988  56  37 0.875 145 123 1.067   4   2 0.864 136  80 1.067   5   2 0.716 168 162 1.235   0   0
EncodeUtf8/nonascii              186    0.930    1.030    0.595    0.761    0.631    0.486    0.608    0.496    0.389    0.579    0.307 0.904  58  33 0.784 156 135 0.945  89  37 0.800 140  82 0.980  46  25 0.673 159 154 1.264   0   0
EncodeUtf8/subtitles             155    2.327    2.270    1.771    2.004    1.829    1.604    1.767    1.624    1.345    1.738    1.167 1.028  17   5 0.885  86  74 0.967  53  24 0.908  81  69 0.994  35  16 0.775  87  78 1.153  19  10
EncodeUtf8/web                   186    2.956    2.856    2.280    2.656    2.429    2.109    2.341    2.157    1.762    2.318    1.512 1.035  32  19 0.856 118  86 0.934  90  46 0.899 100  84 0.975  49  24 0.759 106 102 1.162  31  22
EncodeUtf8/64                    248    2.123    2.196    1.873    2.069    1.941    1.705    1.724    1.677    1.607    1.820    1.477 0.968  81  57 0.906 125  65 0.963 127  50 0.988  67  43 1.020  22  16 0.884 104  85 1.089   7   2
EncodeUtf8/256                   248    2.438    2.596    1.772    2.184    1.911    1.522    1.837    1.605    1.272    1.749    1.134 0.943  86  50 0.811 208 162 0.926 128  66 0.827 167 117 0.949 105  56 0.726 171 170 1.123  21  18
EncodeUtf8/4096                  248    2.311    2.339    1.535    1.875    1.586    1.303    1.592    1.316    1.018    1.475    0.863 0.991  57  12 0.819 204 192 0.968  82  33 0.819 211 156 0.991  54  15 0.690 207 207 1.178  30  14
EncodeUtf8/65536                 248    2.246    2.201    1.501    1.781    1.496    1.268    1.538    1.254    1.002    1.419    0.691 1.018  38   8 0.844 187 156 1.004  57  20 0.825 212 154 1.013  59  21 0.704 210 200 1.447  22  11
EncodeUtf8/1048576               124    2.583    2.486    1.825    2.100    1.795    1.568    1.828    1.543    1.304    1.725    1.013 1.043   9   3 0.870  83  66 1.017  27   6 0.859 102  59 1.018  29  11 0.754  92  87 1.285   1   0
EncodeUtf16/ascii                186   20.168   20.145   17.999   17.994   17.860   15.670   15.761   15.571   14.559   14.507   14.538 1.003   7   0 0.999   5   0 1.006   5   0 0.991  13   0 1.004  15   0 1.002   6   1 0.998   9   1
EncodeUtf16/16                   248    2.634    2.635    2.154    2.160    2.159    1.964    1.960    1.942    1.873    1.878    1.876 0.998   8   0 0.997  12   0 0.998  10   0 1.000   8   0 1.010   6   1 1.000   7   1 1.000   3   0
EncodeUtf16/csv                  155    6.643    6.665    5.167    5.179    5.153    4.050    4.060    4.009    3.847    3.848    3.869 0.995  10   3 0.998   4   0 1.002   3   0 1.000   4   1 1.010   4   1 1.000   3   1 0.995   4   0
EncodeUtf16/invalid              155    1.249    1.246    0.843    0.844    0.841    0.620    0.617    0.618    0.614    0.614    0.613 1.002   5   0 0.996   5   0 0.998   4   0 1.004   0   0 1.006   2   0 0.997   5   0 1.002   4   0
EncodeUtf16/mail                 155    8.841    8.862    7.103    7.114    7.098    5.735    5.746    5.666    5.440    5.435    5.438 0.997  11   4 1.000   3   0 0.998   5   0 1.000   4   0 1.012   3   0 1.002  10   1 1.002   6   1
EncodeUtf16/mixed                186    2.673    2.666    1.938    1.950    1.934    1.426    1.420    1.419    1.383    1.385    1.383 0.999   6   1 0.992   9   0 0.999  10   0 1.002   3   0 1.005   3   0 0.999   5   0 0.996   7   1
EncodeUtf16/nonascii             186    2.011    2.005    1.408    1.418    1.412    1.021    1.020    1.018    0.994    0.992    0.997 1.002   4   0 0.995   7   0 1.000   3   0 1.002   3   0 1.001   6   0 1.001   4   0 0.997  14   0
EncodeUtf16/subtitles            155    6.887    6.919    5.416    5.410    5.421    4.278    4.255    4.225    4.036    4.031    4.027 0.995   9   2 1.001   4   0 1.000  10   0 1.004   3   0 1.012   2   0 1.001   4   0 1.001   5   0
EncodeUtf16/web                  186    7.815    7.963    6.509    6.431    6.517    5.243    5.231    5.176    4.937    4.961    4.926 0.987  28  11 1.012   2   0 1.000   9   0 1.002   7   1 1.013   5   2 0.995  12   1 0.995  12   1
EncodeUtf16/64                   248    5.391    5.437    4.362    4.336    4.347    3.492    3.500    3.413    3.390    3.359    3.408 0.992  15   1 1.004   6   0 1.001   7   0 1.001   6   0 1.026   2   0 1.008   8   1 0.995  12   3
EncodeUtf16/256                  248    6.934    6.921    5.081    5.096    5.072    3.743    3.747    3.744    3.598    3.596    3.594 1.001  10   1 0.996   5   0 1.000   2   0 1.002   3   0 1.002  10   0 0.999   9   0 0.997  13   0
EncodeUtf16/4096                 248    6.148    6.170    4.497    4.535    4.483    3.269    3.256    3.254    3.098    3.102    3.101 0.999  11   0 0.993   4   0 1.001  13   0 1.001   3   0 1.002   9   0 0.998   7   0 0.999  12   1
EncodeUtf16/65536                248    5.837    5.843    4.349    4.352    4.348    3.199    3.201    3.193    3.015    3.027    3.001 0.999  22  12 1.000   8   0 1.000  12   0 0.997  12   1 1.001  10   1 0.995  13   1 1.001  13   0
EncodeUtf16/1048576              124    4.730    4.752    3.952    3.909    3.945    3.134    3.114    3.111    3.003    3.010    2.994 0.992  14   7 1.011   4   0 1.005   5   0 1.003   5   1 1.004   3   1 0.996   5   1 0.997   8   0
```

#### against encoding_rs, the rows it has (geomean ratio, rows < 0.95, rows < 0.90)

```text
group                       rows zig/rust newv3/rust newv2/rust newv1/rust main/rust mainv3/rust mainv2/rust mainv1/rust mainndv3/rust mainndv2/rust mainndv1/rust
DecodeUtf8                  1276 3.853 5 0 2.751 1 0 2.477 5 0 1.516 237 198 3.517 4 0 2.832 2 0 2.570 3 0 2.346 0 0 2.899 5 2 2.402 2 2 0.985 715 701
DecodeUtf8/ascii             174 2.897 0 0 2.603 0 0 2.848 0 0 2.976 0 0 2.843 0 0 2.805 0 0 2.693 0 0 2.875 0 0 2.821 0 0 2.706 0 0 2.840 0 0
DecodeUtf8/csv               145 2.641 0 0 1.970 0 0 1.802 0 0 1.110 53 50 2.468 0 0 2.094 0 0 1.902 0 0 1.843 0 0 2.111 2 0 1.766 0 0 0.687 107 107
DecodeUtf8/invalid           145 6.019 0 0 3.825 0 0 2.979 0 0 1.401 26 22 5.276 0 0 3.767 0 0 3.395 0 0 3.009 0 0 3.913 0 0 2.887 0 0 0.855 105 95
DecodeUtf8/mail              145 2.496 1 0 2.038 0 0 1.950 1 0 1.331 34 31 2.436 1 0 2.202 0 0 1.995 1 0 1.922 0 0 2.236 0 0 1.892 0 0 0.890 82 82
DecodeUtf8/mixed             174 8.381 0 0 4.875 0 0 3.995 0 0 1.904 33 17 6.994 0 0 4.669 0 0 4.127 0 0 4.005 0 0 4.920 0 0 3.878 0 0 1.253 35 33
DecodeUtf8/nonascii          174 5.875 0 0 3.419 0 0 2.791 0 0 1.365 5 5 4.935 0 0 3.292 0 0 2.911 0 0 1.862 0 0 3.513 0 0 2.767 0 0 0.683 173 172
DecodeUtf8/subtitles         145 2.773 2 0 2.180 1 0 1.988 2 0 1.219 37 32 2.607 2 0 2.287 1 0 2.083 1 0 1.968 0 0 2.340 2 1 1.944 1 1 0.747 105 104
DecodeUtf8/web               174 2.758 2 0 2.064 0 0 1.945 2 0 1.265 49 41 2.606 1 0 2.230 1 0 2.021 1 0 1.919 0 0 2.184 1 1 1.852 1 1 0.808 108 108
DecodeUtf16                 1276 4.171 0 0 2.848 0 0 2.563 0 0 1.960 0 0 4.162 0 0 2.843 0 0 2.568 0 0 2.196 139 112 2.909 0 0 2.566 0 0 1.981 145 141
DecodeUtf16/ascii            174 2.370 0 0 2.064 0 0 2.032 0 0 1.939 0 0 2.324 0 0 2.009 0 0 1.983 0 0 2.123 0 0 2.079 0 0 1.970 0 0 2.068 0 0
DecodeUtf16/csv              145 3.115 0 0 2.236 0 0 2.011 0 0 1.617 0 0 3.116 0 0 2.212 0 0 2.057 0 0 1.945 1 0 2.280 0 0 2.046 0 0 1.703 2 1
DecodeUtf16/invalid          145 9.679 0 0 5.576 0 0 4.837 0 0 3.102 0 0 9.651 0 0 5.714 0 0 4.811 0 0 3.745 0 0 5.745 0 0 4.835 0 0 3.245 0 0
DecodeUtf16/mail             145 3.125 0 0 2.312 0 0 2.107 0 0 1.748 0 0 3.120 0 0 2.251 0 0 2.141 0 0 2.052 1 0 2.353 0 0 2.127 0 0 1.864 2 1
DecodeUtf16/mixed            174 10.702 0 0 6.159 0 0 5.286 0 0 3.775 0 0 10.700 0 0 6.304 0 0 5.265 0 0 4.672 0 0 6.312 0 0 5.295 0 0 3.996 0 0
DecodeUtf16/nonascii         174 3.537 0 0 2.033 0 0 1.743 0 0 1.142 0 0 3.532 0 0 2.084 0 0 1.731 0 0 0.902 137 112 2.099 0 0 1.743 0 0 0.851 139 137
DecodeUtf16/subtitles        145 3.321 0 0 2.422 0 0 2.187 0 0 1.706 0 0 3.352 0 0 2.399 0 0 2.218 0 0 2.033 0 0 2.470 0 0 2.220 0 0 1.784 1 1
DecodeUtf16/web              174 3.281 0 0 2.424 0 0 2.231 0 0 1.747 0 0 3.289 0 0 2.390 0 0 2.256 0 0 2.078 0 0 2.471 0 0 2.241 0 0 1.892 1 1
EncodeUtf8                  1276 3.609 4 4 2.738 28 20 2.420 49 40 2.052 95 85 3.619 2 2 3.127 4 3 2.703 9 5 2.640 17 10 2.793 13 11 2.415 34 26 1.743 109 100
EncodeUtf8/ascii             174 2.466 0 0 2.557 0 0 2.438 0 0 2.608 0 0 2.439 0 0 2.599 0 0 2.450 0 0 2.483 0 0 2.636 0 0 2.507 0 0 2.614 0 0
EncodeUtf8/csv               145 2.988 1 1 2.296 5 3 2.075 9 8 1.717 23 21 2.947 0 0 2.606 0 0 2.294 2 2 2.240 4 3 2.340 2 1 2.068 9 5 1.496 21 21
EncodeUtf8/invalid           145 5.239 1 1 3.663 4 3 2.963 4 3 2.520 4 4 5.314 1 1 3.993 1 1 3.178 1 1 3.051 1 1 3.469 3 3 2.791 4 4 1.883 5 5
EncodeUtf8/mail              145 2.887 0 0 2.256 6 3 2.095 9 8 1.759 20 17 2.794 0 0 2.621 0 0 2.308 2 0 2.327 3 1 2.433 0 0 2.163 3 3 1.585 16 15
EncodeUtf8/mixed             174 4.100 2 2 2.789 6 5 2.338 6 5 1.808 6 6 4.144 1 1 3.182 2 1 2.712 1 1 2.560 1 1 2.603 6 6 2.178 6 6 1.454 20 19
EncodeUtf8/nonascii          174 6.451 0 0 4.145 0 0 3.395 0 0 2.686 5 5 7.152 0 0 5.335 1 1 4.287 0 0 4.069 0 0 4.383 1 1 3.463 0 0 2.102 7 5
EncodeUtf8/subtitles         145 3.134 0 0 2.358 3 2 2.137 12 8 1.770 18 16 3.051 0 0 2.684 0 0 2.369 2 1 2.317 4 2 2.438 1 0 2.157 5 4 1.519 16 15
EncodeUtf8/web               174 3.022 0 0 2.300 4 4 2.131 9 8 1.759 19 16 2.922 0 0 2.706 0 0 2.393 1 0 2.361 4 2 2.461 0 0 2.184 7 4 1.496 24 20
EncodeUtf16                 1276 4.617 0 0 3.573 0 0 2.789 2 0 2.663 4 0 4.625 0 0 3.574 0 0 2.788 2 0 2.664 4 0 3.568 0 0 2.766 4 0 2.668 3 0
EncodeUtf16/ascii            174 2.286 0 0 2.039 0 0 1.769 0 0 1.641 0 0 2.275 0 0 2.037 0 0 1.779 0 0 1.641 0 0 2.021 0 0 1.759 0 0 1.647 0 0
EncodeUtf16/csv              145 3.755 0 0 2.925 0 0 2.294 0 0 2.178 2 0 3.781 0 0 2.936 0 0 2.297 0 0 2.172 2 0 2.916 0 0 2.275 1 0 2.188 1 0
EncodeUtf16/invalid          145 7.358 0 0 4.973 0 0 3.672 0 0 3.632 0 0 7.328 0 0 4.981 0 0 3.661 0 0 3.646 0 0 4.974 0 0 3.646 0 0 3.626 0 0
EncodeUtf16/mail             145 3.649 0 0 2.926 0 0 2.370 0 0 2.244 0 0 3.643 0 0 2.923 0 0 2.375 0 0 2.240 0 0 2.926 0 0 2.343 0 0 2.249 0 0
EncodeUtf16/mixed            174 8.476 0 0 6.183 0 0 4.562 0 0 4.414 0 0 8.477 0 0 6.214 0 0 4.545 0 0 4.425 0 0 6.185 0 0 4.527 0 0 4.427 0 0
EncodeUtf16/nonascii         174 6.878 0 0 4.877 0 0 3.525 2 0 3.434 2 0 6.873 0 0 4.893 0 0 3.521 2 0 3.430 2 0 4.863 0 0 3.522 3 0 3.438 2 0
EncodeUtf16/subtitles        145 4.071 0 0 3.194 0 0 2.518 0 0 2.383 0 0 4.089 0 0 3.195 0 0 2.514 0 0 2.375 0 0 3.200 0 0 2.487 0 0 2.379 0 0
EncodeUtf16/web              174 3.713 0 0 3.087 0 0 2.479 0 0 2.337 0 0 3.758 0 0 3.056 0 0 2.476 0 0 2.349 0 0 3.092 0 0 2.450 0 0 2.344 0 0
```

#### rows below encoding_rs (median paired ratio < 1), by arm and operation, all sizes / 65536

```text
zig:rust        DecodeUtf8    8 /  3  DecodeUtf16    0 /  0  EncodeUtf8    7 /  0  EncodeUtf16    0 /  0
newv3:rust      DecodeUtf8    2 /  0  DecodeUtf16    2 /  0  EncodeUtf8   38 /  9  EncodeUtf16    0 /  0
newv2:rust      DecodeUtf8   17 /  2  DecodeUtf16    1 /  0  EncodeUtf8   61 / 13  EncodeUtf16    7 /  1
newv1:rust      DecodeUtf8  259 / 29  DecodeUtf16    5 /  0  EncodeUtf8  105 / 19  EncodeUtf16   10 /  1
main:rust       DecodeUtf8    9 /  4  DecodeUtf16    0 /  0  EncodeUtf8    3 /  0  EncodeUtf16    0 /  0
mainv3:rust     DecodeUtf8    4 /  0  DecodeUtf16    0 /  0  EncodeUtf8   10 /  1  EncodeUtf16    0 /  0
mainv2:rust     DecodeUtf8   12 /  0  DecodeUtf16    3 /  0  EncodeUtf8   14 /  2  EncodeUtf16    8 /  1
mainv1:rust     DecodeUtf8    1 /  0  DecodeUtf16  146 / 28  EncodeUtf8   25 /  4  EncodeUtf16   10 /  1
mainndv3:rust   DecodeUtf8    6 /  0  DecodeUtf16    0 /  0  EncodeUtf8   18 /  2  EncodeUtf16    0 /  0
mainndv2:rust   DecodeUtf8    5 /  0  DecodeUtf16    2 /  0  EncodeUtf8   41 /  5  EncodeUtf16   10 /  2
mainndv1:rust   DecodeUtf8  727 /147  DecodeUtf16  173 / 30  EncodeUtf8  140 / 26  EncodeUtf16   10 /  2
```

benchstat's geomean over every row, GB/s (rust, zig, main, newv3, mainv3, mainndv3, newv2, mainv2, mainndv2, newv1, mainv1, mainndv1):

```text
geomean 964.3m 3.910 +304.16% 3.825 +295.39% 2.869 +195.73% 2.984 +208.04% 2.936 +202.62% 2.481 +155.80% 2.570 +165.51% 2.458 +153.37% 1.956 +100.85% 2.384 +145.41% 1.698 +73.63%
```

### Placement of the -v3 build on all-ASCII 16- and 256-byte decode

```text
arms        median     p90     max  >1.10  >1.20  rows
n3           1.156   1.337    1.63    108     68  186
m3           1.121   1.198    1.49    114     16  186
placement 0: n3/m3
  DecodeUtf8                186  0.912
  DecodeUtf8/ascii           62  0.854
  DecodeUtf8/nonascii        62  0.985
  DecodeUtf8/web             62  0.902
placement 16: n3/m3
  DecodeUtf8                186  1.076
  DecodeUtf8/ascii           62  1.159
  DecodeUtf8/nonascii        62  1.000
  DecodeUtf8/web             62  1.074
placement 32: n3/m3
  DecodeUtf8                186  0.978
  DecodeUtf8/ascii           62  0.962
  DecodeUtf8/nonascii        62  0.995
  DecodeUtf8/web             62  0.977
placement 48: n3/m3
  DecodeUtf8                186  0.893
  DecodeUtf8/ascii           62  0.827
  DecodeUtf8/nonascii        62  0.995
  DecodeUtf8/web             62  0.864
```

### EncodeUtf8 run of the padded last window (rejected, section 3)

`zig` and `tail*` the padded variant, `new*` the head; columns zig/new, zig/main, tailv3/newv3, tailv3/mainndv3, tailv2/newv2, tailv2/mainndv2, tailv1/newv1, tailv1/mainndv1, tailv1/mainv1 (geomean ratio only):

```text
EncodeUtf8                1364  1.007  1.005  0.984  0.967  0.967  0.970  0.953  1.110  0.748
EncodeUtf8/ascii           186  1.000  1.007  0.966  0.930  0.998  0.986  1.001  1.003  1.044
EncodeUtf8/16              248  1.001  1.046  0.990  0.997  0.997  1.024  1.002  0.999  0.990
EncodeUtf8/csv             155  1.002  1.020  0.996  0.976  0.971  0.968  0.965  1.096  0.751
EncodeUtf8/invalid         155  1.028  1.012  0.971  1.026  0.963  1.011  0.940  1.250  0.771
EncodeUtf8/mail            155  0.976  1.011  0.980  0.917  0.962  0.933  0.959  1.055  0.739
EncodeUtf8/mixed           186  1.032  1.022  0.979  1.046  0.949  1.019  0.922  1.130  0.658
EncodeUtf8/nonascii        186  1.004  0.911  0.997  0.947  0.965  0.939  0.927  1.164  0.624
EncodeUtf8/subtitles       155  1.010  1.034  0.995  0.970  0.970  0.966  0.958  1.103  0.744
EncodeUtf8/web             186  1.003  1.036  0.992  0.932  0.960  0.938  0.953  1.106  0.718
EncodeUtf8/64              248  1.079  1.036  0.972  0.938  0.989  1.006  0.967  1.052  0.850
EncodeUtf8/256             248  0.985  0.928  0.978  0.910  0.944  0.894  0.921  1.028  0.663
EncodeUtf8/4096            248  1.000  0.995  0.990  0.967  0.957  0.950  0.938  1.105  0.648
EncodeUtf8/65536           248  0.986  1.010  0.988  1.002  0.958  0.976  0.944  1.358  0.665
EncodeUtf8/1048576         124  0.982  1.029  0.987  1.012  0.953  0.977  0.942  1.201  0.707
```
