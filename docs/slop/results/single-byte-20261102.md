# Single-byte, x-user-defined, and UTF-16: loops that do not move with the linker, 2026-11-02

Wave 2, single-byte and UTF-16. Intel(R) Xeon(R) Processor @ 2.60GHz (Ice
Lake-SP, 4 vCPUs, AVX-512 with BW and VBMI), in an orb. Zig 0.16
ReleaseFast for the host CPU unless a section says otherwise; encoding_rs
0.8.44 (`rust`), built as the harness builds it. Every A/B is
`just bench-compare`: each arm a `bench-<arm> serve` process pinned to
core 3, every arm timing each row back to back in an order that rotates
from row to row and round to round, 20 ms samples, 5 rounds after a
sizing round, then benchstat. `base` is the bench arm built from
origin/main at `dde9394` (wave 2 CJK merged, testingx v0.4.0); `zig` is
this branch measured at `1cce347`, rebased on it, whose code the pushed
commits have.

Headlines:

1. Speed no longer depends on code placement. Over 480 single-byte rows
   at four placements of the codecs, the median row varies by 4.0%
   (14.5% for `base`, 0.9% between two copies of one binary), p90 15.0%
   (53.5%), and each operation-and-shape geomean by 0.7-3.9% (0.9-78%).
   The loops go a 16-byte block at a time, with no loop over single
   bytes but for a call's last few. No function alignment.
2. Encoding non-ASCII text to a single-byte encoding from UTF-16 is
   arithmetic on 16 lanes for ASCII and the table's two longest runs,
   trimmed of the C1 controls: `nonascii` 0.520 to 1.629 GB/s geomean
   (4.85x encoding_rs), and 2 single-byte UTF-16 encode rows below
   encoding_rs, from 189 (ISO-8859-14 `nonascii-16` at 0.97x, `-64` at
   1.00x).
3. x-user-defined is arithmetic on 16 lanes both ways: UTF-8 encode at
   16 bytes 125.6 to 7.3 ns (encoding_rs 16.7), decode to UTF-16 14.1 to
   5.3 ns (9.1).
4. UTF-16LE and UTF-16BE copy units in registers and check surrogate
   pairs there: decode to UTF-16 at 16 bytes 19.5 to 9.4 ns (LE) and
   20.8 to 10.2 (BE), against encoding_rs's 17.2; invalid UTF-16BE at
   64 KiB 0.016 to 2.46 GB/s (decoding it was quadratic).
5. Over this branch's 5,632 rows, 2.14x `base` geomean and 3.49x
   encoding_rs; 33 rows below encoding_rs, from 1,029 (section 8). 586
   rows are more than 5% slower than `base`, mostly encoding text the
   encoding lacks (section 7).
6. `codec.putBmp` replaces three private copies in the CJK decoders,
   with their rows unchanged (section 6).

## 1. Loops whose speed does not depend on where the linker puts them

### Cause

core-20261102.md section 8 found single-byte rows swinging between 0.57x
and 1.05x across commits that never touched single_byte.zig, with the
decode loop's alignment. The decoder and the UTF-16 encoder were three
loops in turn: a vector scan for whole ASCII blocks, a copy of them, and
then a scalar loop over the next 16 bytes, one byte and one branch per
iteration. On mostly-ASCII Latin text the scalar loop runs after nearly
every block; its body is a handful of instructions, and how many 32-byte
fetch windows it spans is what moved.

### Change

Every loop now goes a 16-byte block at a time, and only the last bytes of
a call, fewer than a block (or all that is left once the output is short
of room), go one at a time.

- Decode to UTF-16: an ASCII block is widened and stored, two blocks a
  step once one is ASCII (`codec.asciiBlocks`). Any other block is looked
  up whole: on AVX-512BW under the LLVM backend, two `vpermi2w` permutes
  of the 128-entry table, each over 64 entries, with bit 6 picking
  between them, and a select for the ASCII lanes, with no branch on the
  bytes; elsewhere the block is widened and the non-ASCII lanes are
  patched one by one from their bit mask. A zero entry is U+FFFD, or in
  fatal mode the error's lane.
- Decode to UTF-8: ASCII blocks are copied as above; at the first block
  with a byte from 0x80, up to 256 bytes of whole blocks go to UTF-16 as
  above, on the stack, and utf transcodes them (`codec.bmpToUtf8`) as far
  as they fit.
- Encode from UTF-16: ASCII blocks are narrowed two at a time
  (`codec.asciiBlocksOut`); any other block is arithmetic on all 16
  lanes for ASCII and the encoding's runs (section 2), and the other
  lanes are searched for one by one; the first the table lacks (or a
  surrogate) goes to the one-character path, which writes its numeric
  character reference or stops.
- Encode from UTF-8: ASCII runs go through `codec.asciiRunOut`; where the
  next 16 bytes hold six or more bytes from 0x80, three characters or
  more (`codec.denseUtf8`), and 64 bytes or more are left, up to 256
  bytes go to UTF-16 through utf and are encoded as above
  (`codec.encodeStaged`, which also writes the numeric character
  references, so that text the encoding lacks does not go back through
  utf one character at a time). Sparser text, as Latin with the odd
  accented letter, and short input go a character at a time between
  ASCII runs, which measured faster than staging them.

No function alignment: Zig rejects it for wasm, which the WPT harness
builds.

### Measurement

Four placements of each build: `bench-<arm>` built with a never-executed
`jmp 1f; .skip N, 0xcc; 1:` at the top of `arm.row` in a scratch copy of
bench/zig/arm.zig, which the linker places before every codec, N = 0,
16, 32, 48. That moves `single_byte.Decoder.decode` and
`single_byte.Encoder.encode` through 0, 16, 32, and 48 bytes past a
64-byte line (`nm` on each binary). `b0` to `b48` are `base`, `n0` to
`n48` this branch, and `n0dup` a copy of `n0`: the noise of one binary
against itself. Rows: all 30 single-byte encodings, the four operations,
and four shapes (`web-65536`, `csv-4096`, `mixed-256`, `nonascii-16`),
480 rows.

One interleaved run of all eleven arms:

```
BENCHTIME_MS=20 just arms="rust zig b0 b16 b32 b48 n0 n16 n32 n48 n0dup" bench-compare 5 '^[A-Za-z0-9]+/(<the 30>)/(web-65536|csv-4096|mixed-256|nonascii-16)$'
```

Each row's spread is its fastest placement's median GB/s over its
slowest's; the noise line is two copies of one binary:

```
arms                                median    p90    max  >1.10  >1.20
base dde9394 (b0 b16 b32 b48)        1.145  1.535   2.17    309    202
this branch (n0 n16 n32 n48)         1.040  1.150   1.39    104     27
noise, this run (n0 n0dup)           1.009  1.102   1.35     49      7
```

Per operation and shape, the geomean over the 30 encodings at each
placement, and its spread:

```
op/shape                   base GB/s geomean, b0 b16 b32 b48  spread     new GB/s geomean, n0 n16 n32 n48  spread new/base new/rust
DecodeUtf16/csv-4096        1.930    2.034    2.105    2.053   1.090     8.240    8.231    8.166    8.152   1.011     4.02     3.85
DecodeUtf16/mixed-256       1.350    1.374    1.427    1.275   1.119     5.369    5.366    5.433    5.461   1.018     3.99    11.90
DecodeUtf16/nonascii-16     0.844    0.810    0.845    0.803   1.052     1.822    1.818    1.832    1.825   1.007     2.21     2.30
DecodeUtf16/web-65536       1.019    1.155    1.089    1.160   1.138     7.724    7.599    7.711    7.891   1.038     6.97     6.27
DecodeUtf8/csv-4096         1.539    1.441    1.291    1.586   1.229     4.092    4.122    4.126    4.152   1.015     2.81     2.95
DecodeUtf8/mixed-256        0.942    0.654    0.539    0.961   1.782     3.404    3.452    3.427    3.495   1.027     4.45     9.35
DecodeUtf8/nonascii-16      0.565    0.427    0.430    0.588   1.375     0.632    0.625    0.631    0.629   1.011     1.25     1.66
DecodeUtf8/web-65536        0.973    0.769    0.894    0.805   1.266     4.056    4.011    4.036    4.057   1.012     4.69     4.59
EncodeUtf16/csv-4096        2.322    2.223    2.557    2.656   1.195     6.973    6.950    6.895    6.985   1.013     2.85     4.52
EncodeUtf16/mixed-256       0.944    0.911    1.000    1.009   1.108     2.398    2.409    2.345    2.346   1.027     2.45     6.64
EncodeUtf16/nonascii-16     0.479    0.469    0.484    0.488   1.040     1.048    1.031    1.030    1.043   1.018     2.16     3.80
EncodeUtf16/web-65536       1.555    1.606    1.632    1.707   1.098     7.032    7.032    6.926    7.198   1.039     4.33     7.41
EncodeUtf8/csv-4096         1.414    1.297    1.317    1.396   1.090     2.197    2.207    2.234    2.226   1.017     1.63     3.54
EncodeUtf8/mixed-256        0.642    0.639    0.643    0.644   1.009     0.917    0.915    0.919    0.922   1.009     1.43     3.17
EncodeUtf8/nonascii-16      0.449    0.448    0.451    0.441   1.022     0.433    0.430    0.422    0.437   1.036     0.96     2.51
EncodeUtf8/web-65536        0.915    0.979    0.880    1.066   1.211     2.203    2.178    2.176    2.149   1.025     2.26     4.46
```

Placement moved `base`'s groups by up to 78% (`DecodeUtf8/mixed-256`,
0.539 to 0.961 GB/s) and moves this branch's by 0.7-3.9%. The median
row varies by 4.0% against 0.9% between two copies of one binary, and
p90 1.150 against noise's 1.102. The rows that still vary most:

```
worst ten rows by spread, this branch:
  DecodeUtf16/windows-1256/web-65536       1.389  noise 1.003  5.337 6.431 5.257 7.301
  DecodeUtf16/IBM866/mixed-256             1.373  noise 1.338  5.204 5.010 6.310 6.880
  EncodeUtf16/ISO-8859-5/nonascii-16       1.355  noise 1.348  3.608 3.769 3.818 4.887
  EncodeUtf16/ISO-8859-14/web-65536        1.349  noise 1.094  35.999 34.010 34.709 45.875
  EncodeUtf16/IBM866/nonascii-16           1.343  noise 1.336  4.581 3.761 3.427 3.411
  DecodeUtf8/ISO-8859-5/mixed-256          1.312  noise 1.306  3.423 3.537 3.537 4.489
  DecodeUtf8/windows-1258/mixed-256        1.310  noise 1.010  3.451 3.565 4.522 4.507
  DecodeUtf16/windows-1252/mixed-256       1.295  noise 1.193  5.929 5.711 5.394 6.982
  DecodeUtf16/IBM850/web-65536             1.290  noise 1.145  17.188 13.370 13.323 14.889
  EncodeUtf16/IBM437/csv-4096              1.287  noise 1.041  12.793 16.464 12.825 12.928
```

Half of them vary as much between the two copies of one binary
("noise"), so those are measurement; the others (windows-1256
`web-65536`, ISO-8859-14 `web-65536`, windows-1258 `mixed-256`,
IBM437 `csv-4096`) are rows of 4 KiB and more to UTF-16, all above 5
GB/s.

## 2. Single-byte encode from UTF-16 on non-ASCII text

### Change

core-20261102.md left 21 of its 144 single-byte rows below encoding_rs,
all encoding non-ASCII text from UTF-16, worst windows-1252 `nonascii` at
0.37x: the encoder looked up one character at a time. Now a block of 16
units is arithmetic on all lanes for ASCII and for the table's longest
run of consecutive code points; only the lanes in neither are searched
for, one by one, with the 128-entry vector compare the encoder already
had. Two changes to the run made it cover the text:

- The run no longer counts the C1 controls. Every ISO-8859 table maps
  0x80 to 0x9F to U+0080 to U+009F, a run of 32 that text never uses and
  that was the longest run of most of them, so ISO-8859-7's Greek, -8's
  Hebrew, and -6's Arabic letters were searched for one at a time. Runs
  are now trimmed of U+0080 to U+009F, and the script's letters win.
- A second run, the table's second longest, is tried on a block's lanes
  that ASCII and the first run leave over, only when there are some.
  x-mac-cyrillic's capitals and small letters are two runs (0x80 to 0x9F
  and 0xE0 to 0xFE), and windows-874's Thai is two (0xA1 to 0xDA and 0xE0 to 0xFB); both were
  searched for a letter at a time. Computed after the first run's miss
  mask is nonzero, it costs encodings with one run a branch; computed on
  every block, it cost windows-1251, -1253, and ISO-8859-7 6-8% against
  that.

The same block function serves UTF-8 input once utf has transcoded a
dense stretch of it to UTF-16 (`codec.encodeStaged`).

### Result

Full run (section 7), GB/s geomeans; "< rust" counts rows below
encoding_rs:

```
rows                                   n   rust   base    zig  zig/base  zig/rust  <rust base  <rust zig
single-byte EncodeUtf16, all shapes 1232  1.162  2.281  4.582      2.01      3.94         189          2
single-byte EncodeUtf16, nonascii    168  0.336  0.520  1.629      3.13      4.85          56          2
single-byte EncodeUtf16, mixed       168  0.336  0.975  2.292      2.35      6.83           8          0
single-byte EncodeUtf16, web         168  2.229  3.527  7.689      2.18      3.45          28          0
single-byte EncodeUtf8, all shapes  1232  0.629  1.390  1.982      1.43      3.15          38          0
single-byte EncodeUtf8, nonascii     168  0.151  0.459  0.846      1.84      5.61           6          0
```

windows-1252 `nonascii`, core-20261102.md's worst row at 0.37x, is now
4.0x encoding_rs over its six sizes (8.86 against 2.21 GB/s). The two
rows still below are ISO-8859-14 `nonascii-16` (0.97x) and
`nonascii-64` (1.00x): Welsh's accented vowels are spread over the
table with no run, so each is a 128-entry search, and at 16 and 64
bytes the search is the whole call.

Per encoding, `nonascii` from UTF-16, geomean of its six sizes, GB/s:

```
IBM866           rust  0.075 base  0.711 zig  6.977  zig/rust 93.63  base/rust  9.54
ISO-8859-10      rust  0.150 base  0.367 zig  0.375  zig/rust  2.49  base/rust  2.44
ISO-8859-13      rust  0.240 base  0.368 zig  0.394  zig/rust  1.64  base/rust  1.54
ISO-8859-14      rust  0.494 base  0.371 zig  0.554  zig/rust  1.12  base/rust  0.75
ISO-8859-15      rust  1.802 base  1.055 zig  9.466  zig/rust  5.25  base/rust  0.59
ISO-8859-16      rust  0.131 base  0.366 zig  0.438  zig/rust  3.34  base/rust  2.79
ISO-8859-2       rust  0.055 base  0.369 zig  0.368  zig/rust  6.70  base/rust  6.71
ISO-8859-3       rust  0.065 base  0.374 zig  0.377  zig/rust  5.80  base/rust  5.76
ISO-8859-4       rust  0.077 base  0.367 zig  0.371  zig/rust  4.85  base/rust  4.79
ISO-8859-5       rust  2.129 base  1.095 zig  9.490  zig/rust  4.46  base/rust  0.51
ISO-8859-6       rust  0.264 base  0.367 zig  5.501  zig/rust 20.80  base/rust  1.39
ISO-8859-7       rust  1.365 base  1.061 zig  8.639  zig/rust  6.33  base/rust  0.78
ISO-8859-8       rust  2.221 base  0.368 zig 10.971  zig/rust  4.94  base/rust  0.17
ISO-8859-8-I     rust  2.205 base  0.367 zig 10.954  zig/rust  4.97  base/rust  0.17
KOI8-R           rust  0.150 base  0.366 zig  0.369  zig/rust  2.46  base/rust  2.44
KOI8-U           rust  0.128 base  0.434 zig  0.521  zig/rust  4.08  base/rust  3.39
macintosh        rust  0.045 base  0.372 zig  0.374  zig/rust  8.37  base/rust  8.34
windows-1250     rust  0.118 base  0.381 zig  0.390  zig/rust  3.30  base/rust  3.23
windows-1251     rust  1.745 base  1.087 zig  7.496  zig/rust  4.30  base/rust  0.62
windows-1252     rust  2.209 base  1.110 zig  8.856  zig/rust  4.01  base/rust  0.50
windows-1253     rust  1.332 base  1.066 zig  7.665  zig/rust  5.75  base/rust  0.80
windows-1254     rust  0.189 base  0.374 zig  0.400  zig/rust  2.12  base/rust  1.98
windows-1255     rust  1.517 base  1.058 zig  9.147  zig/rust  6.03  base/rust  0.70
windows-1256     rust  0.211 base  0.470 zig  0.619  zig/rust  2.93  base/rust  2.23
windows-1257     rust  0.106 base  0.378 zig  0.378  zig/rust  3.57  base/rust  3.57
windows-1258     rust  0.142 base  0.368 zig  0.375  zig/rust  2.63  base/rust  2.58
windows-874      rust  0.782 base  0.962 zig  7.466  zig/rust  9.55  base/rust  1.23
x-mac-cyrillic   rust  0.449 base  0.388 zig  3.831  zig/rust  8.53  base/rust  0.86
```

The encodings whose letters sit in no run of more than a few (the
Latin-2 family, KOI8, macintosh, windows-1250/1254/1257/1258) stay at
the search's speed, 0.37-0.40 GB/s, as before; they were and are 1.6x
to 8x encoding_rs. A reverse table would make them arithmetic too, at
up to 64 KiB per encoding against the 256-byte table each has now; the
owner's memory bar says no.

## 3. x-user-defined

### Change

x-user-defined maps byte 0x80 + n to U+F780 + n, so a byte from 0x80 is
its code point's low byte. Both directions are now that arithmetic on 16
lanes:

- Decode to UTF-16: each block widened, with 0xF700 added to the lanes
  from 0x80. To UTF-8, an ASCII block is copied; a block with a byte from
  0x80, in input of 64 bytes or more, goes to UTF-16 on the stack, up to
  256 units, which utf transcodes; in shorter input, each byte becomes
  its UTF-8 (itself, or EF 9E/9F and a continuation byte) in a `u32`
  lane, stored four bytes at a time, with no call.
- Encode from UTF-16: each block truncated to bytes; the lanes that are
  neither ASCII nor U+F780 to U+F7FF end the block, and the one-character
  path writes their reference or stops. From UTF-8: ASCII runs through
  `codec.asciiRunOut`; EF 9E/9F and a continuation byte, the only
  three-byte characters the encoding maps, inline; dense text through
  `codec.encodeStaged` and the block function; anything else through
  `codec.read`.

The old encoder read every character, ASCII included, with
`codec.readScalar`, the general reader that returns a `u21` struct
(the codegen rule in plan.md), one character at a time: that was the
122.9 ns at 16 bytes.

### Result

```
op                           GB/s rust   base    zig  zig/rust  <rust base  <rust zig   ns@16 rust   base    zig
x-user-defined/DecodeUtf16       6.586  1.684 11.713      1.78          44          2         9.1   14.1    5.3
x-user-defined/DecodeUtf8        1.085  0.774  3.732      3.44          44          0        16.2   18.9    7.1
x-user-defined/EncodeUtf16       2.099  1.095  5.481      2.61          43          0        18.7   47.6    7.6
x-user-defined/EncodeUtf8        1.330  0.202  2.745      2.06          44          2        16.7  125.6    7.3
```

UTF-8 encode at 16 bytes: 125.6 to 7.3 ns (encoding_rs 16.7); decode to
UTF-16 at 16 bytes: 14.1 to 5.3 ns (encoding_rs 9.1). The rows below
encoding_rs: `EncodeUtf8` `mixed-16` (0.62x) and `invalid-16` (0.80x),
where nearly every character is one the encoding lacks and the call is
16 bytes of numeric character references, and `DecodeUtf16` at 1 MiB
(0.98-0.99x, memory-bound).

## 4. UTF-16LE and UTF-16BE

### Change

The decoder handed every run of units to baskingspot/utf: to UTF-16 a
`@memcpy` of all the units that fit, a byte swap for the other byte
order, and utf's validation; to UTF-8 a copy of up to 256 units into an
aligned buffer and utf's transcoder. At 16 bytes the calls were most of
the 19 ns; and since validation stops at the first unpaired surrogate
and the copy was of everything that fit, each unpaired surrogate copied
the rest of the input again: decoding `invalid` UTF-16 was quadratic
(0.017 GB/s at 64 KiB for UTF-16BE before).

- To UTF-16, units are copied in registers, byte-swapped with a vector
  `@byteSwap` for the other byte order: 32 at a time while they hold no
  surrogate, and otherwise 8 at a time with their pairs checked in
  registers: every trailing surrogate must follow a leading one, and
  every leading one precede a trailing one, but in the last lane, whose
  pair the next block checks (the block then advances 7). A block with
  an unpaired surrogate goes to the standard's algorithm a unit at a
  time. No call into utf, and each unpaired surrogate costs a block.
  (A first version handed a block with a surrogate to utf's validation
  a window of 256 units at a time; that fixed the quadratic case but
  left each unpaired surrogate costing up to a window, plus a scalar
  byte swap for UTF-16BE: 0.44x encoding_rs on `invalid` at 4 KiB and
  more.)
- To UTF-8, ASCII units are narrowed 32 and then 8 at a time; the rest
  go to utf a window of 256 units at a time, as before, but fewer than
  16 units are converted here, one at a time, rather than through a
  call.

### Result

```
op                           GB/s rust   base    zig  zig/rust  <rust base  <rust zig   ns@16 rust   base    zig
UTF-16BE/DecodeUtf16             2.037  3.082 11.368      5.58          11          1        17.2   20.8   10.2
UTF-16BE/DecodeUtf8              1.440  3.975  4.851      3.37           9          4        13.9   21.3   11.0
UTF-16LE/DecodeUtf16             2.505  7.673 11.736      4.68          10          2        17.2   19.5    9.4
UTF-16LE/DecodeUtf8              1.448  3.284  4.174      2.88           9          2        15.0   22.2   11.0
```

At 16 bytes, decode to UTF-16 is 9.4 (LE) and 10.2 ns (BE) against
encoding_rs's 17.2, from 19.5 and 20.8. `invalid` input, GB/s:

```
DecodeUtf16/UTF-16LE/invalid-16      rust  0.949 base  0.821 zig  1.699
DecodeUtf16/UTF-16LE/invalid-64      rust  1.268 base  1.097 zig  0.931
DecodeUtf16/UTF-16LE/invalid-256     rust  2.150 base  3.953 zig  2.363
DecodeUtf16/UTF-16LE/invalid-4096    rust  2.236 base  2.758 zig  2.894
DecodeUtf16/UTF-16LE/invalid-65536   rust  1.915 base  0.087 zig  1.764
DecodeUtf8/UTF-16LE/invalid-16       rust  0.655 base  0.451 zig  0.622
DecodeUtf8/UTF-16LE/invalid-64       rust  0.704 base  0.556 zig  0.588
DecodeUtf8/UTF-16LE/invalid-256      rust  0.915 base  1.691 zig  1.551
DecodeUtf8/UTF-16LE/invalid-4096     rust  0.928 base  1.446 zig  1.257
DecodeUtf8/UTF-16LE/invalid-65536    rust  0.764 base  0.900 zig  0.896
DecodeUtf16/UTF-16BE/invalid-16      rust  0.938 base  0.770 zig  1.582
DecodeUtf16/UTF-16BE/invalid-64      rust  1.239 base  1.316 zig  1.239
DecodeUtf16/UTF-16BE/invalid-256     rust  1.582 base  1.409 zig  2.748
DecodeUtf16/UTF-16BE/invalid-4096    rust  1.798 base  0.253 zig  2.544
DecodeUtf16/UTF-16BE/invalid-65536   rust  1.764 base  0.016 zig  2.456
DecodeUtf8/UTF-16BE/invalid-16       rust  0.654 base  0.472 zig  0.642
DecodeUtf8/UTF-16BE/invalid-64       rust  0.706 base  0.571 zig  0.573
DecodeUtf8/UTF-16BE/invalid-256      rust  0.771 base  0.844 zig  0.739
DecodeUtf8/UTF-16BE/invalid-4096     rust  0.880 base  1.048 zig  0.954
DecodeUtf8/UTF-16BE/invalid-65536    rust  0.745 base  0.855 zig  0.829
```

Rows below `base` by more than 5% (all still above encoding_rs but
UTF-16LE `invalid-64`):

- `DecodeUtf16/UTF-16LE` at 4 KiB, 0.91-0.92x `base` (13.7x
  encoding_rs): `base`'s `@memcpy` and utf's validation of LE in place
  run at 60 GB/s there, the 32-unit register loop at 55.
- `DecodeUtf16/UTF-16LE/invalid-256` and `-64`, 0.60x and 0.85x: utf's
  validation handled their few surrogates faster than the block check
  and the standard's algorithm do; 1.10x and 0.73x encoding_rs.
- `DecodeUtf8` on non-ASCII text from 64 bytes to 1 MiB, 0.86-0.94x,
  mostly UTF-16BE: the failed ASCII checks before each 256-unit window
  and the copy loop; 1.9-8.7x encoding_rs.

## 5. Per-call cost through `Decoder` and a single-encoding `DecoderFor`

Every 16-byte row of the single-byte, x-user-defined, and UTF-16
encodings (eight shapes each, 1,056 rows), through the runtime
`Decoder` and `Encoder` (`base`, `zig`: bench/zig/arm.zig) and through
a single-encoding `DecoderFor(&.{e})` and `EncoderFor(&.{e})` picked
before the timed loop (`ctbase`, `ct`: bench/comptime, built from the
same two trees):

```
BENCHTIME_MS=20 just arms="rust zig base ct ctbase" bench-compare 5 '^[A-Za-z0-9]+/(<the 30>|x-user-defined|UTF-16LE|UTF-16BE)/[a-z]+-16$'
```

ns per call, median over each family's rows:

```
ns per call, 16 bytes, median of rows     rust    base     zig  ctbase      ct
UTF-16BE/DecodeUtf16                      17.3    20.1    10.1    18.4     8.2
UTF-16BE/DecodeUtf8                       14.2    19.1    11.2    19.5    10.4
UTF-16LE/DecodeUtf16                      17.3    19.4     9.3    17.2     8.1
UTF-16LE/DecodeUtf8                       14.9    19.6    10.7    20.3    10.0
single-byte/DecodeUtf16                   10.9     8.6     7.7     6.4     4.9
single-byte/DecodeUtf8                    10.6     9.4     7.3     7.5     5.2
single-byte/EncodeUtf16                   12.5     8.2     7.3     6.9     6.1
single-byte/EncodeUtf8                    12.4     8.2     7.0     7.7     6.1
x-user-defined/DecodeUtf16                 9.3    14.2     5.5     9.9     3.0
x-user-defined/DecodeUtf8                 16.2    18.8     7.1    16.9     5.0
x-user-defined/EncodeUtf16                18.8    48.0     7.8    28.9     6.2
x-user-defined/EncodeUtf8                 16.3   124.7     7.5   123.0     5.5
```

Through `Decoder`, every family is ahead of encoding_rs at 16 bytes.
Through a single-encoding type, which inlines the family into the
caller (and moves its code with the caller's: section 1), this branch
is 1.1-1.8x faster still than through `Decoder`, and 4.9 ns decodes 16
single-byte bytes to UTF-16. The single-encoding gain over `base` holds
in each direction (`ct` against `ctbase`: 1.3x single-byte decode, 3.3x
x-user-defined decode to UTF-16, 22x x-user-defined UTF-8 encode, 2.1-2.2x
UTF-16 decode to UTF-16).

## 6. `codec.putBmp` in the CJK decoders

big5.zig, gb18030.zig, and japanese.zig each carried a private writer of
a code point from U+0080 to U+FFFF; it is now `codec.putBmp`, which
returns 0 when the code point does not fit, with no optional. Big5 keeps
its plane-2 branch in front of it. Japanese's fast loop runs only where
the room is known, and its private copy checked none: the shared
function's checks cost EUC-JP 7-10% (`EUC-JP` decode geomean 0.899 to
UTF-16, 0.931 to UTF-8, against the copy, over 44 rows each). Called
with `dst[0 .. o + per]`, the slice's length tells it the room, and the
checks fold away: EUC-JP 0.993 and 1.000, Shift_JIS 0.994 and 1.005.

```
BENCHTIME_MS=20 just arms="rust zig cjkpre" bench-compare 5 '^Decode(Utf8|Utf16)/(Shift_JIS|EUC-JP)/'
```

`cjkpre` is `origin/wave2-cjk` with this branch's commits on it but
the switch. Over all six CJK decoders' 528 decode rows, the first
version measured 0.994 geomean (Big5 1.025 and 0.994, GBK 1.016 and
1.010, gb18030 1.008 and 1.012, ISO-2022-JP 1.063 and 1.021, which
does not call it). The full run below has every CJK decode row as a
control against `base`.

## 7. The full run

Every single-byte, x-user-defined, and UTF-16 row (44 inputs: eight
shapes at 16 bytes to 1 MiB, 5,632 rows with the IBM pages), plus every
CJK decode row and the CJK UTF-8 encode rows as controls for the `read`
and `putBmp` changes:

```
SB='<the 30>'
BENCHTIME_MS=20 just arms="rust base zig" bench-compare 5 "^[A-Za-z0-9]+/($SB|x-user-defined|UTF-16LE|UTF-16BE)/" \
    "^EncodeUtf8/(Shift_JIS|EUC-JP|ISO-2022-JP|GBK|gb18030|Big5|EUC-KR)/" \
    "^Decode(Utf8|Utf16)/(Shift_JIS|EUC-JP|ISO-2022-JP|GBK|gb18030|Big5|EUC-KR)/"
```

GB/s geomean by family and operation, the single-byte family without
the IBM pages, which encoding_rs lacks:

```
family/op                     rows    rust    base     zig zig/base base/rust zig/rust base<rust zig<rust  worst zig/rust
UTF-16BE/DecodeUtf16            44   2.037   3.082  11.368     3.69      1.51     5.58        11        1  1.00 DecodeUtf16/UTF-16BE/invalid-64
UTF-16BE/DecodeUtf8             44   1.440   3.975   4.851     1.22      2.76     3.37         9        4  0.81 DecodeUtf8/UTF-16BE/invalid-64
UTF-16LE/DecodeUtf16            44   2.505   7.673  11.736     1.53      3.06     4.68        10        2  0.73 DecodeUtf16/UTF-16LE/invalid-64
UTF-16LE/DecodeUtf8             44   1.448   3.284   4.174     1.27      2.27     2.88         9        2  0.84 DecodeUtf8/UTF-16LE/invalid-64
single-byte/DecodeUtf16       1232   1.525   1.943   5.840     3.01      1.27     3.83       390        2  0.92 DecodeUtf16/ISO-8859-6/ascii-1048576
single-byte/DecodeUtf8        1232   1.156   1.576   3.744     2.38      1.36     3.24       198       16  0.78 DecodeUtf8/ISO-8859-10/csv-64
single-byte/EncodeUtf16       1232   1.162   2.281   4.582     2.01      1.96     3.94       189        2  0.97 EncodeUtf16/ISO-8859-14/nonascii-16
single-byte/EncodeUtf8        1232   0.629   1.390   1.982     1.43      2.21     3.15        38        0  1.08 EncodeUtf8/ISO-8859-13/csv-65536
x-user-defined/DecodeUtf16      44   6.586   1.684  11.713     6.95      0.26     1.78        44        2  0.98 DecodeUtf16/x-user-defined/mixed-1048576
x-user-defined/DecodeUtf8       44   1.085   0.774   3.732     4.82      0.71     3.44        44        0  1.46 DecodeUtf8/x-user-defined/mixed-16
x-user-defined/EncodeUtf16      44   2.099   1.095   5.481     5.00      0.52     2.61        43        0  1.43 EncodeUtf16/x-user-defined/ascii-1048576
x-user-defined/EncodeUtf8       44   1.330   0.202   2.745    13.59      0.15     2.06        44        2  0.62 EncodeUtf8/x-user-defined/mixed-16
```

ns per call at 16 bytes, median over the eight 16-byte inputs:

```
family/op                       rust    base     zig
UTF-16BE/DecodeUtf16            17.2    20.8    10.2
UTF-16BE/DecodeUtf8             13.9    21.3    11.0
UTF-16LE/DecodeUtf16            17.2    19.5     9.4
UTF-16LE/DecodeUtf8             15.0    22.2    11.0
single-byte/DecodeUtf16         10.9     8.6     7.6
single-byte/DecodeUtf8          10.5     9.4     7.3
single-byte/EncodeUtf16         12.5     8.2     7.3
single-byte/EncodeUtf8          12.3     8.2     7.0
x-user-defined/DecodeUtf16       9.1    14.1     5.3
x-user-defined/DecodeUtf8       16.2    18.9     7.1
x-user-defined/EncodeUtf16      18.7    47.6     7.6
x-user-defined/EncodeUtf8       16.7   125.6     7.3
```

Over this branch's 5,632 rows, geomean 1.805 to 3.872 GB/s (2.14x);
against encoding_rs on its 5,280, 3.49x, with 33 rows below it, from
1,029. 4,571 rows are more than 5% faster than `base` and 586 more than
5% slower, all but a few of them (section 8) still above encoding_rs:

- Encoding text the encoding lacks, where nearly every character is a
  numeric character reference (`mixed` and `invalid` into the tables
  that lack their scripts): 279 rows at every size, median 0.79-0.93x
  `base` by operation, worst 0.52x (`EncodeUtf16/*/invalid`). Each such
  character costs a block attempt before the one-character path; going
  one character at a time for the rest of a block after a miss measured
  no better (section 10).
- Other `EncodeUtf8` rows on the search-bound tables (175 rows, 76 of
  them at 4 KiB, median 0.85-0.93x): the per-character path between
  ASCII runs, with `denseUtf8`'s test in front of it, and `ascii` at
  256 bytes and 4 KiB (0.92x, 23 against 25 GB/s in the unchanged
  `codec.asciiRunOut`: code placement).
- `DecodeUtf8` (76 rows, 54 of them at 16 bytes, `mixed-16` and
  `invalid-16`, median 0.84x): a whole block of non-ASCII bytes goes to
  UTF-16 and through a call into utf, which 16 bytes do not repay.
- Other `EncodeUtf16` (24 rows, 0.85-0.93x) and UTF-16 (32 rows,
  section 4).

The CJK controls against `base`, geomean per family (none of their code
changed but `putBmp`, `read`, and placement):

```
family        DecodeUtf16  DecodeUtf8  EncodeUtf8
Shift_JIS           0.969       1.004       1.030
EUC-JP              1.011       1.016       1.027
ISO-2022-JP         0.923       0.991       1.014
GBK                 0.987       0.997       1.002
gb18030             0.987       1.004       0.987
Big5                1.009       1.006       0.978
EUC-KR              1.014       1.016       0.972
```

ISO-2022-JP decode to UTF-16, 0.923, calls neither changed function; in
the putBmp A/B (section 6) it measured 1.063.

## 8. Rows still below encoding_rs

33 of the 5,280 rows encoding_rs also has, from 1,029 for `base`
(full run, zig/rust, `base`/rust in brackets):

- Single-byte decode to UTF-8 of Latin text with sparse non-ASCII at 64
  and 256 bytes (16 rows, 0.78-1.00x: ISO-8859-10 `csv-64` 0.78 [0.55],
  windows-1252 `web-256` 0.80 [1.23], ISO-8859-16 `csv-64` 0.81 [0.96],
  ISO-8859-13 `subtitles-64` 0.85 [0.96], ISO-8859-2 `web-256` 0.94
  [1.31], windows-1251 `invalid-16` 0.91 [1.09], and others at
  0.93-1.00). At the first block with a byte from 0x80, up to 256 bytes go
  to UTF-16 and through utf; text with one accented letter every few
  blocks pays that for a few characters. A scalar path for sparse text
  would bring back the loop over single bytes section 1 removed;
  encoding_rs is ahead here by 0-20%.
- UTF-16 (9 rows): unpaired surrogates (`invalid`, 0.73-1.00x: LE
  `invalid-64` to UTF-16 0.73 [0.87], BE and LE `invalid-64` to UTF-8
  0.81 and 0.84 [0.81, 0.79], LE `invalid-65536` to UTF-16 0.92
  [0.05]), and BE `nonascii-16` to UTF-8 0.89 [0.84]: each unpaired surrogate
  and the units before it in its block go through the standard's
  algorithm one unit at a time, and to UTF-8 fewer than 16 units are
  converted one at a time.
- x-user-defined `EncodeUtf8` `mixed-16` 0.62 [0.18] and `invalid-16`
  0.80 [0.18]: 16 bytes that are nearly all numeric character
  references.
- Decode to UTF-16 at 1 MiB, memory-bound: ISO-8859-6 and windows-1251
  `ascii` 0.92 and 0.95 [0.84, 0.80], x-user-defined `mixed` and
  `nonascii` 0.98 and 0.99 [0.25].
- ISO-8859-14 `EncodeUtf16` `nonascii-16` and `-64`, 0.97 and 1.00
  [0.65, 0.72]: section 2.

## 9. Without AVX-512

The single-byte decoder's whole-block lookup uses AVX-512BW's
`vpermi2w`; without it, a non-ASCII block is widened and its non-ASCII
lanes patched one by one. `zigv3` and `basev3` are the two trees built
for `-Dcpu=x86_64_v3` (AVX2, no AVX-512; the single-byte decoder has no
zmm register in `zigv3`), timed on the same machine against `zig`, the
host build:

```
BENCHTIME_MS=20 just arms="rust zig zigv3 basev3" bench-compare 5 '^[A-Za-z0-9]+/(<the 30>|x-user-defined|UTF-16LE|UTF-16BE)/(web-65536|csv-4096|mixed-256|nonascii-16|web-16)$'
```

```
GB/s geomean                    rust  basev3   zigv3     zig v3/basev3  v3/rust v3<rust
UTF-16BE/DecodeUtf16           1.838   3.064   9.815  10.120      3.20     5.34       0
UTF-16BE/DecodeUtf8            1.114   3.412   3.621   3.532      1.06     3.25       0
UTF-16LE/DecodeUtf16           2.173   7.288  10.408  10.729      1.43     4.79       0
UTF-16LE/DecodeUtf8            1.047   2.636   2.835   2.821      1.08     2.71       0
single-byte/DecodeUtf16        1.050   1.389   2.482   4.205      1.79     2.28       0
single-byte/DecodeUtf8         0.757   1.031   1.762   2.376      1.71     2.27       0
single-byte/EncodeUtf16        0.829   1.278   2.717   3.453      2.13     3.35       3
single-byte/EncodeUtf8         0.448   0.787   1.101   1.327      1.40     2.44       3
x-user-defined/DecodeUtf16     5.046   1.577   8.617   9.726      5.47     1.71       0
x-user-defined/DecodeUtf8      0.962   0.725   2.379   2.555      3.28     2.47       0
x-user-defined/EncodeUtf16     2.022   0.985   4.320   4.771      4.38     2.14       0
x-user-defined/EncodeUtf8      1.230   0.228   1.756   1.844      7.71     1.43       0
  below rust: EncodeUtf16/ISO-8859-10/nonascii-16 0.99
  below rust: EncodeUtf16/ISO-8859-13/nonascii-16 0.97
  below rust: EncodeUtf16/ISO-8859-14/nonascii-16 0.66
  below rust: EncodeUtf8/ISO-8859-13/csv-4096 0.82
  below rust: EncodeUtf8/ISO-8859-13/mixed-256 0.97
  below rust: EncodeUtf8/windows-1254/csv-4096 0.86
```

Without AVX-512, single-byte decode keeps 1.7-1.8x `base` and 2.3x
encoding_rs, at 59% (to UTF-16) and 74% (to UTF-8) of the AVX-512
build. The search's 128-entry compare takes eight ymm compares instead
of four zmm, and six encode rows of the 600 fall below encoding_rs,
worst ISO-8859-14 `nonascii-16` at 0.66x. A `pshufb` or NEON `tbl`
lookup of the table's high bytes would serve AVX2 and ARM.

## 10. Rejected

Measured on the way, before the rebase onto testingx v0.4.0, with
interleaved A/Bs as above:

- A scalar `bmpToUtf8` for 16 units or fewer instead of utf's: slower.
- Staging 64 or 128 units instead of 256 before utf transcodes them:
  256 measured best on the 256-byte and longer rows, and the same at 16.
- An inner loop over a block's non-ASCII lanes in the UTF-8 encoder:
  slower than going back to the block loop.
- Leaving the C1 controls out of the run's search instead of trimming
  them from it: the same speed, more code.
- A dedicated staged UTF-8 encoder for x-user-defined (2.7-4.1 GB/s
  against 2.0-2.7 for the shared `codec.encodeStaged`): both are above
  encoding_rs, and the shared one is one function less.
- The second run on every block (section 2): 6-8% off the encodings
  with one run.
- `@memcpy` instead of the 64- and 16-byte copy loop of a UTF-16 window
  to UTF-8: no difference beyond noise.
- After a unit the table lacks, the rest of its block one character at
  a time in the UTF-16 encoder and `codec.encodeStaged`, for text the
  encoding lacks: 0.98-1.00x geomean over 160 rows of `mixed`,
  `invalid`, `nonascii`, `web`, and `subtitles` into eight encodings.
- The second run tested in the one-character path's `lookup` too: the
  `EncodeUtf8` `nonascii-16` geomean then varied 17% across placements
  (IBM866's row 2.0x), against 4% without it.
- UTF-16 to UTF-16 through utf's validation, a window of 256 units at a
  time, at a block with a surrogate (section 4).
- `read` testing E0 first among three-byte leads: 10% off the CJK
  encoders' UTF-8 input; E0 second is neutral for them.

## Raw output

The full run's `bench-compare` summary (zig against encoding_rs, per
encoding and operation):

```
zig/arm, geomean              rows  zig GB/s     rust     ±   <1    ~   slowest vs rust
DecodeUtf8/IBM866               44      3.64     3.85    3%    0    0   1.25 [1.01, 1.31] invalid-16
DecodeUtf16/IBM866              44      5.52     4.06    1%    0    0   1.11 [1.05, 1.44] ascii-1048576
EncodeUtf8/IBM866               44      2.46     7.95    2%    0    0   1.59 [1.39, 2.22] ascii-1048576
EncodeUtf16/IBM866              44      7.48    20.13    2%    0    0   1.33 [1.17, 1.61] ascii-1048576
DecodeUtf8/ISO-8859-2           44      4.04     2.80    2%    0    1   0.98 [0.74, 1.23] web-256
DecodeUtf16/ISO-8859-2          44      6.22     3.47    2%    0    0   1.07 [1.06, 1.13] ascii-1048576
EncodeUtf8/ISO-8859-2           44      1.76     2.99    3%    0    0   1.36 [1.35, 1.71] web-256
EncodeUtf16/ISO-8859-2          44      3.19     3.94    2%    0    0   1.41 [1.20, 1.54] ascii-1048576
DecodeUtf8/ISO-8859-3           44      3.75     2.41    2%    1    6   0.90 [0.79, 1.03] subtitles-64
DecodeUtf16/ISO-8859-3          44      6.20     3.33    4%    0    0   1.11 [1.00, 1.19] ascii-1048576
EncodeUtf8/ISO-8859-3           44      1.83     2.92    3%    0    0   1.60 [1.40, 1.73] ascii-1048576
EncodeUtf16/ISO-8859-3          44      3.25     3.82    2%    0    0   1.27 [1.08, 1.38] ascii-1048576
DecodeUtf8/ISO-8859-4           44      4.22     2.96    1%    0    1   1.28 [0.91, 1.49] subtitles-256
DecodeUtf16/ISO-8859-4          44      6.24     3.50    2%    0    0   1.06 [1.04, 1.14] ascii-1048576
EncodeUtf8/ISO-8859-4           44      1.78     2.74    0%    0    0   1.68 [1.52, 1.74] ascii-1048576
EncodeUtf16/ISO-8859-4          44      3.11     3.46    2%    0    0   1.35 [1.32, 1.41] ascii-1048576
DecodeUtf8/ISO-8859-5           44      3.74     3.88    1%    0    0   1.20 [1.12, 1.25] invalid-16
DecodeUtf16/ISO-8859-5          44      5.65     4.09    2%    0    0   1.08 [1.02, 1.09] ascii-1048576
EncodeUtf8/ISO-8859-5           44      2.63     3.96    1%    0    0   1.24 [1.14, 1.32] mixed-16
EncodeUtf16/ISO-8859-5          44      9.33     4.56    2%    0    0   1.39 [1.29, 1.48] ascii-1048576
DecodeUtf8/ISO-8859-6           44      3.62     4.05    1%    0    0   1.44 [1.43, 1.58] mail-16
DecodeUtf16/ISO-8859-6          44      5.50     4.34    3%    0    1   1.07 [0.88, 1.33] ascii-1048576
EncodeUtf8/ISO-8859-6           44      2.13     4.79    1%    0    0   1.65 [1.33, 1.69] ascii-1048576
EncodeUtf16/ISO-8859-6          44      6.31     7.74    2%    0    0   1.36 [1.35, 1.42] ascii-1048576
DecodeUtf8/ISO-8859-7           44      3.62     3.83    3%    0    2   1.23 [0.96, 1.30] invalid-16
DecodeUtf16/ISO-8859-7          44      5.44     4.09    3%    0    0   1.17 [1.07, 1.48] ascii-1048576
EncodeUtf8/ISO-8859-7           44      2.45     4.01    2%    0    1   1.34 [0.98, 1.47] mixed-16
EncodeUtf16/ISO-8859-7          44      8.34     4.89    2%    0    0   1.32 [1.29, 1.47] ascii-1048576
DecodeUtf8/ISO-8859-8           44      3.62     3.99    2%    0    0   1.42 [1.32, 1.88] csv-16
DecodeUtf16/ISO-8859-8          44      5.42     4.34    1%    0    0   1.08 [1.03, 1.13] ascii-1048576
EncodeUtf8/ISO-8859-8           44      2.49     4.10    2%    0    0   1.21 [1.18, 1.39] mixed-16
EncodeUtf16/ISO-8859-8          44      8.84     5.16    2%    0    0   1.28 [1.23, 1.36] ascii-1048576
DecodeUtf8/ISO-8859-8-I         44      3.57     3.91    1%    0    0   1.28 [1.27, 1.84] invalid-16
DecodeUtf16/ISO-8859-8-I        44      5.49     4.25    2%    0    1   1.05 [0.93, 1.09] ascii-1048576
EncodeUtf8/ISO-8859-8-I         44      2.48     4.07    2%    0    0   1.22 [1.10, 1.24] mixed-16
EncodeUtf16/ISO-8859-8-I        44      8.88     5.17    2%    0    0   1.33 [1.25, 1.39] ascii-1048576
DecodeUtf8/ISO-8859-10          44      3.73     3.00    1%    1    0   0.86 [0.77, 0.99] csv-64
DecodeUtf16/ISO-8859-10         44      5.59     3.69    2%    0    0   1.07 [1.05, 1.16] ascii-1048576
EncodeUtf8/ISO-8859-10          44      1.39     2.18    1%    0    0   1.09 [1.08, 1.10] subtitles-256
EncodeUtf16/ISO-8859-10         44      2.49     2.50    1%    0    0   1.32 [1.30, 1.44] nonascii-16
DecodeUtf8/ISO-8859-13          44      3.91     2.70    0%    1    2   0.84 [0.74, 0.94] subtitles-64
DecodeUtf16/ISO-8859-13         44      6.15     3.50    2%    0    0   1.09 [1.06, 1.31] ascii-1048576
EncodeUtf8/ISO-8859-13          44      1.65     2.00    1%    0    1   1.08 [1.06, 1.13] csv-65536
EncodeUtf16/ISO-8859-13         44      2.95     2.18    1%    0    1   1.12 [1.08, 1.16] nonascii-256
DecodeUtf8/ISO-8859-14          44      5.15     2.65    2%    0    1   1.05 [1.03, 1.21] csv-65536
DecodeUtf16/ISO-8859-14         44      7.55     3.33    1%    0    0   1.09 [1.06, 1.15] ascii-1048576
EncodeUtf8/ISO-8859-14          44      3.04     2.09    2%    0    0   1.23 [1.14, 1.28] mixed-16
EncodeUtf16/ISO-8859-14         44      5.36     2.27    2%    0    2   0.96 [0.93, 1.08] nonascii-16
DecodeUtf8/ISO-8859-15          44      4.60     2.79    2%    0    2   1.08 [0.96, 1.15] invalid-16
DecodeUtf16/ISO-8859-15         44      6.81     3.42    1%    0    1   1.09 [0.94, 1.10] ascii-1048576
EncodeUtf8/ISO-8859-15          44      3.81     2.61    1%    0    0   1.12 [1.10, 1.42] csv-256
EncodeUtf16/ISO-8859-15         44     10.89     3.75    1%    0    0   1.33 [1.25, 1.42] ascii-1048576
DecodeUtf8/ISO-8859-16          44      3.57     2.47    2%    3    5   0.91 [0.72, 0.92] csv-64
DecodeUtf16/ISO-8859-16         44      5.94     3.42    1%    0    2   1.08 [0.96, 1.37] ascii-1048576
EncodeUtf8/ISO-8859-16          44      1.77     2.37    1%    0    0   1.23 [1.17, 1.23] subtitles-64
EncodeUtf16/ISO-8859-16         44      3.28     2.91    1%    0    0   1.34 [1.28, 1.38] ascii-1048576
DecodeUtf8/KOI8-R               44      3.59     3.83    1%    0    0   1.11 [1.09, 1.30] invalid-16
DecodeUtf16/KOI8-R              44      5.63     4.09    1%    0    1   1.08 [0.91, 1.12] ascii-1048576
EncodeUtf8/KOI8-R               44      0.94     2.53    1%    0    0   1.38 [1.06, 1.43] subtitles-64
EncodeUtf16/KOI8-R              44      1.47     2.61    1%    0    0   1.34 [1.27, 1.38] ascii-1048576
DecodeUtf8/KOI8-U               44      3.64     3.81    3%    0    1   1.17 [1.16, 1.20] invalid-16
DecodeUtf16/KOI8-U              44      5.59     4.09    2%    0    0   1.08 [1.04, 1.10] ascii-1048576
EncodeUtf8/KOI8-U               44      1.13     3.35    1%    0    0   1.69 [1.47, 2.02] ascii-1048576
EncodeUtf16/KOI8-U              44      1.79     3.51    1%    0    0   1.33 [1.22, 1.39] ascii-1048576
DecodeUtf8/macintosh            44      4.20     2.45    3%    0    9   0.98 [0.95, 1.29] subtitles-4096
DecodeUtf16/macintosh           44      7.16     3.38    1%    0    0   1.10 [1.08, 1.13] ascii-1048576
EncodeUtf8/macintosh            44      2.39     3.64    2%    0    0   1.67 [1.59, 1.83] ascii-1048576
EncodeUtf16/macintosh           44      4.09     4.30    2%    0    0   1.31 [1.26, 1.35] ascii-1048576
DecodeUtf8/windows-874          44      3.04     3.32    1%    0    2   1.05 [1.00, 1.16] invalid-16
DecodeUtf16/windows-874         44      5.44     3.83    1%    0    1   1.12 [0.91, 2.00] ascii-1048576
EncodeUtf8/windows-874          44      2.71     4.14    4%    0    1   1.16 [1.15, 1.62] mixed-16
EncodeUtf16/windows-874         44      7.83     5.66    2%    0    0   1.30 [1.08, 1.35] ascii-1048576
DecodeUtf8/windows-1250         44      3.49     3.06    1%    0    3   1.08 [1.02, 1.12] invalid-16
DecodeUtf16/windows-1250        44      5.51     3.92    3%    0    0   1.07 [1.05, 1.17] ascii-1048576
EncodeUtf8/windows-1250         44      1.32     2.40    2%    0    0   1.36 [1.28, 1.76] subtitles-256
EncodeUtf16/windows-1250        44      2.43     2.87    2%    0    0   1.34 [1.31, 1.37] ascii-1048576
DecodeUtf8/windows-1251         44      3.55     3.70    2%    0    1   0.96 [0.87, 1.00] invalid-16
DecodeUtf16/windows-1251        44      5.48     4.08    2%    0    1   1.06 [0.91, 1.12] ascii-1048576
EncodeUtf8/windows-1251         44      2.48     3.84    3%    0    0   1.24 [1.17, 1.26] mixed-16
EncodeUtf16/windows-1251        44      8.29     4.06    1%    0    0   1.35 [1.16, 1.37] ascii-1048576
DecodeUtf8/windows-1252         44      3.98     2.39    3%    1    5   0.85 [0.80, 0.88] web-256
DecodeUtf16/windows-1252        44      6.52     3.31    2%    0    0   1.08 [1.02, 1.16] ascii-1048576
EncodeUtf8/windows-1252         44      3.79     2.55    2%    0    0   1.21 [1.18, 1.33] mixed-16
EncodeUtf16/windows-1252        44     10.95     3.23    2%    0    0   1.29 [1.16, 1.40] ascii-1048576
DecodeUtf8/windows-1253         44      3.58     3.75    1%    0    0   1.10 [1.08, 1.22] invalid-16
DecodeUtf16/windows-1253        44      5.47     4.06    1%    0    0   1.08 [1.06, 1.09] ascii-1048576
EncodeUtf8/windows-1253         44      2.52     3.97    2%    0    0   1.36 [1.20, 1.49] mixed-16
EncodeUtf16/windows-1253        44      8.26     4.87    1%    0    0   1.34 [1.31, 1.41] ascii-1048576
DecodeUtf8/windows-1254         44      3.64     2.97    1%    0    0   1.12 [1.11, 1.14] web-256
DecodeUtf16/windows-1254        44      5.66     3.75    2%    0    0   1.09 [1.04, 1.18] ascii-1048576
EncodeUtf8/windows-1254         44      1.46     2.10    1%    0    0   1.24 [1.21, 1.29] web-4096
EncodeUtf16/windows-1254        44      2.73     2.52    2%    0    0   1.36 [1.31, 1.50] ascii-1048576
DecodeUtf8/windows-1255         44      3.61     3.83    1%    0    0   1.43 [1.36, 1.86] subtitles-16
DecodeUtf16/windows-1255        44      5.53     4.19    1%    0    1   1.04 [0.85, 1.10] ascii-1048576
EncodeUtf8/windows-1255         44      2.41     4.12    1%    0    0   1.56 [1.10, 1.83] subtitles-16
EncodeUtf16/windows-1255        44      8.62     5.53    2%    0    0   1.31 [1.25, 1.41] ascii-1048576
DecodeUtf8/windows-1256         44      3.55     3.80    2%    0    1   1.13 [0.96, 1.21] invalid-16
DecodeUtf16/windows-1256        44      5.54     4.08    1%    0    0   1.10 [1.08, 1.17] ascii-1048576
EncodeUtf8/windows-1256         44      1.22     2.85    2%    0    0   1.69 [1.57, 1.89] ascii-1048576
EncodeUtf16/windows-1256        44      2.00     2.76    2%    0    0   1.31 [1.30, 1.35] ascii-1048576
DecodeUtf8/windows-1257         44      3.73     2.75    3%    0    2   1.14 [0.84, 1.60] invalid-16
DecodeUtf16/windows-1257        44      6.03     3.51    1%    0    0   1.10 [1.09, 1.38] ascii-1048576
EncodeUtf8/windows-1257         44      1.79     2.57    3%    0    0   1.59 [1.53, 2.37] mail-4096
EncodeUtf16/windows-1257        44      3.13     2.99    2%    0    0   1.33 [1.30, 1.48] ascii-1048576
DecodeUtf8/windows-1258         44      3.52     3.52    2%    0    1   1.13 [0.92, 1.44] csv-64
DecodeUtf16/windows-1258        44      5.44     4.39    2%    0    2   1.10 [1.08, 1.43] ascii-1048576
EncodeUtf8/windows-1258         44      1.14     2.37    2%    0    1   1.38 [1.15, 2.06] subtitles-16
EncodeUtf16/windows-1258        44      1.97     2.68    3%    0    0   1.29 [1.13, 1.46] ascii-1048576
DecodeUtf8/x-mac-cyrillic       44      3.44     3.70    1%    0    0   1.15 [1.15, 1.21] invalid-16
DecodeUtf16/x-mac-cyrillic      44      5.45     4.05    1%    0    1   1.10 [1.06, 1.37] ascii-1048576
EncodeUtf8/x-mac-cyrillic       44      1.99     3.64    1%    0    0   1.37 [1.26, 1.58] mixed-16
EncodeUtf16/x-mac-cyrillic      44      5.50     5.52    1%    0    0   1.38 [1.34, 1.56] ascii-1048576
DecodeUtf8/GBK                  44      1.33     1.75    1%    0    2   1.03 [0.81, 1.04] mixed-64
DecodeUtf16/GBK                 44      1.43     1.66    1%    2    2   0.87 [0.84, 0.89] subtitles-64
EncodeUtf8/GBK                  44      1.10    12.92    2%    0    0   1.59 [1.07, 1.60] mail-16
DecodeUtf8/gb18030              44      1.34     1.79    2%    0    0   1.04 [1.01, 1.08] mixed-64
DecodeUtf16/gb18030             44      1.43     1.69    2%    1    4   0.83 [0.82, 0.85] subtitles-64
EncodeUtf8/gb18030              44      1.13    12.91    1%    0    0   1.57 [1.24, 1.60] web-16
DecodeUtf8/Big5                 44      1.27     1.43    2%    1    8   0.90 [0.89, 0.97] nonascii-16
DecodeUtf16/Big5                44      1.32     1.29    3%    8    7   0.84 [0.77, 0.95] subtitles-4096
EncodeUtf8/Big5                 44      1.23    12.07    2%    0    0   1.39 [1.38, 1.51] subtitles-16
DecodeUtf8/EUC-JP               44      1.45     1.81    4%    0    3   1.21 [0.81, 1.37] mail-256
DecodeUtf16/EUC-JP              44      1.78     1.85    2%    0    1   1.09 [1.08, 1.28] ascii-1048576
EncodeUtf8/EUC-JP               44      1.15     5.78    2%    0    1   1.29 [1.12, 1.31] csv-16
DecodeUtf8/ISO-2022-JP          44      0.90     2.37    2%    0    1   1.20 [0.94, 1.22] mixed-16
DecodeUtf16/ISO-2022-JP         44      1.15     2.75    3%    0    2   1.10 [0.95, 1.18] mail-16
EncodeUtf8/ISO-2022-JP          44      0.69     5.98    1%    0    0   1.50 [1.49, 1.55] web-16
DecodeUtf8/Shift_JIS            44      1.19     1.47    1%    3    8   0.87 [0.86, 0.94] subtitles-64
DecodeUtf16/Shift_JIS           44      1.32     1.67    1%    0    3   1.02 [1.01, 1.05] subtitles-64
EncodeUtf8/Shift_JIS            44      1.03     5.35    2%    0    0   1.22 [1.08, 1.26] mail-16
DecodeUtf8/EUC-KR               44      1.41     1.39    1%    0    9   0.94 [0.93, 1.25] mixed-256
DecodeUtf16/EUC-KR              44      1.46     1.47    2%    0    4   0.99 [0.98, 1.24] mixed-4096
EncodeUtf8/EUC-KR               44      1.06     3.64    1%    0    0   1.43 [1.19, 1.67] web-16
DecodeUtf8/UTF-16BE             44      4.85     3.36    2%    3    2   0.82 [0.81, 0.88] invalid-64
DecodeUtf16/UTF-16BE            44     11.37     5.54    1%    0    1   0.94 [0.92, 1.40] invalid-64
DecodeUtf8/UTF-16LE             44      4.17     2.88    3%    2    1   0.83 [0.82, 0.93] invalid-64
DecodeUtf16/UTF-16LE            44     11.74     4.71    2%    2    0   0.74 [0.57, 0.78] invalid-64
DecodeUtf8/x-user-defined       44      3.73     3.44    2%    0    0   1.49 [1.35, 1.95] mixed-16
DecodeUtf16/x-user-defined      44     11.71     1.80    1%    0    4   0.98 [0.81, 1.15] mixed-1048576
EncodeUtf8/x-user-defined       44      2.74     2.08    1%    2    1   0.62 [0.58, 0.76] mixed-16
EncodeUtf16/x-user-defined      44      5.48     2.59    2%    0    0   1.43 [1.39, 1.45] ascii-1048576
DecodeUtf8/IBM437               44      4.44        -     -    0    0   -
DecodeUtf16/IBM437              44      7.35        -     -    0    0   -
EncodeUtf8/IBM437               44      2.35        -     -    0    0   -
EncodeUtf16/IBM437              44      4.11        -     -    0    0   -
DecodeUtf8/IBM850               44      3.75        -     -    0    0   -
DecodeUtf16/IBM850              44      6.23        -     -    0    0   -
EncodeUtf8/IBM850               44      1.87        -     -    0    0   -
EncodeUtf16/IBM850              44      3.32        -     -    0    0   -
all                           6556      3.29     3.38         31  128

ns/call, median      bytes       zig      rust  zig/rust
DecodeUtf8              16       7.5      11.3      1.44
DecodeUtf8              64      26.4      45.8      1.77
DecodeUtf8             256      68.8     267.0      3.67
DecodeUtf16             16       7.8      11.1      1.46
DecodeUtf16             64      12.3      32.0      2.09
DecodeUtf16            256      41.7     144.9      3.14
EncodeUtf8              16       7.1      12.3      1.75
EncodeUtf8              64      47.3     129.0      2.04
EncodeUtf8             256     181.1    1103.4      3.59
EncodeUtf16             16       7.3      12.5      1.72
EncodeUtf16             64      13.7      57.4      2.00
EncodeUtf16            256      48.7     270.8      3.28
```

benchstat, `base` and `zig` against `rust`, GB/s, for the x-user-defined
and UTF-16 rows, and the geomean over every row of the run:

```
                                            │      rust      │                  base                   │                   zig                    │
                                            │      GB/s      │      GB/s       vs base                 │      GB/s       vs base                  │
DecodeUtf8/UTF-16BE/ascii-16                   1219.9m ± ∞ ¹     817.1m ± ∞ ¹    -33.02% (p=0.008 n=5)    1576.4m ± ∞ ¹     +29.22% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/csv-16                     1219.4m ± ∞ ¹     817.0m ± ∞ ¹    -33.00% (p=0.008 n=5)    1591.7m ± ∞ ¹     +30.53% (p=0.016 n=5)
DecodeUtf8/UTF-16BE/invalid-16                  653.7m ± ∞ ¹     471.6m ± ∞ ¹    -27.86% (p=0.008 n=5)     642.0m ± ∞ ¹           ~ (p=0.841 n=5)
DecodeUtf8/UTF-16BE/mail-16                    1149.8m ± ∞ ¹     753.1m ± ∞ ¹    -34.50% (p=0.008 n=5)    1451.5m ± ∞ ¹     +26.24% (p=0.016 n=5)
DecodeUtf8/UTF-16BE/mixed-16                    746.6m ± ∞ ¹     539.2m ± ∞ ¹    -27.78% (p=0.008 n=5)     767.8m ± ∞ ¹           ~ (p=0.421 n=5)
DecodeUtf8/UTF-16BE/nonascii-16                 698.7m ± ∞ ¹     589.0m ± ∞ ¹    -15.70% (p=0.032 n=5)     619.5m ± ∞ ¹           ~ (p=0.151 n=5)
DecodeUtf8/UTF-16BE/subtitles-16               1146.8m ± ∞ ¹     751.5m ± ∞ ¹    -34.47% (p=0.008 n=5)    1461.1m ± ∞ ¹     +27.41% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-16                     1157.2m ± ∞ ¹     753.8m ± ∞ ¹    -34.86% (p=0.008 n=5)    1455.5m ± ∞ ¹     +25.78% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/ascii-64                     2.921 ± ∞ ¹      3.188 ± ∞ ¹     +9.14% (p=0.008 n=5)      5.537 ± ∞ ¹     +89.56% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/csv-64                       3.169 ± ∞ ¹      3.235 ± ∞ ¹          ~ (p=0.548 n=5)      6.103 ± ∞ ¹     +92.56% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/invalid-64                  705.8m ± ∞ ¹     571.4m ± ∞ ¹          ~ (p=0.151 n=5)     573.4m ± ∞ ¹     -18.76% (p=0.032 n=5)
DecodeUtf8/UTF-16BE/mail-64                      2.931 ± ∞ ¹      3.227 ± ∞ ¹          ~ (p=0.421 n=5)      5.439 ± ∞ ¹     +85.59% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/mixed-64                    986.2m ± ∞ ¹    2434.1m ± ∞ ¹   +146.82% (p=0.008 n=5)    2187.3m ± ∞ ¹    +121.79% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/nonascii-64                 865.6m ± ∞ ¹    2418.6m ± ∞ ¹   +179.41% (p=0.008 n=5)    2186.9m ± ∞ ¹    +152.65% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/subtitles-64                 2.909 ± ∞ ¹      3.207 ± ∞ ¹    +10.25% (p=0.032 n=5)      5.529 ± ∞ ¹     +90.05% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-64                       2.888 ± ∞ ¹      3.216 ± ∞ ¹    +11.36% (p=0.008 n=5)      5.499 ± ∞ ¹     +90.41% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/ascii-256                    3.040 ± ∞ ¹     10.739 ± ∞ ¹   +253.30% (p=0.008 n=5)     16.870 ± ∞ ¹    +455.00% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/csv-256                      1.546 ± ∞ ¹      7.390 ± ∞ ¹   +378.12% (p=0.008 n=5)      6.379 ± ∞ ¹    +312.68% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/invalid-256                 770.9m ± ∞ ¹     844.1m ± ∞ ¹          ~ (p=0.095 n=5)     738.7m ± ∞ ¹           ~ (p=0.151 n=5)
DecodeUtf8/UTF-16BE/mail-256                     2.687 ± ∞ ¹      8.631 ± ∞ ¹   +221.27% (p=0.008 n=5)      7.810 ± ∞ ¹    +190.71% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/mixed-256                    1.308 ± ∞ ¹      7.231 ± ∞ ¹   +452.63% (p=0.008 n=5)      6.517 ± ∞ ¹    +398.02% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/nonascii-256                 1.145 ± ∞ ¹      7.120 ± ∞ ¹   +522.14% (p=0.008 n=5)      6.678 ± ∞ ¹    +483.48% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/subtitles-256                1.649 ± ∞ ¹      7.409 ± ∞ ¹   +349.17% (p=0.008 n=5)      7.406 ± ∞ ¹    +349.02% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-256                      1.987 ± ∞ ¹      7.522 ± ∞ ¹   +278.64% (p=0.008 n=5)      6.945 ± ∞ ¹    +249.56% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/ascii-4096                   4.567 ± ∞ ¹     20.912 ± ∞ ¹   +357.92% (p=0.008 n=5)     52.322 ± ∞ ¹   +1045.75% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/csv-4096                     1.597 ± ∞ ¹     11.031 ± ∞ ¹   +590.68% (p=0.008 n=5)     10.129 ± ∞ ¹    +534.18% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/invalid-4096                880.1m ± ∞ ¹    1048.0m ± ∞ ¹    +19.08% (p=0.008 n=5)     954.0m ± ∞ ¹           ~ (p=0.151 n=5)
DecodeUtf8/UTF-16BE/mail-4096                    1.724 ± ∞ ¹     11.554 ± ∞ ¹   +570.17% (p=0.008 n=5)     11.463 ± ∞ ¹    +564.91% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/mixed-4096                   1.493 ± ∞ ¹     11.234 ± ∞ ¹   +652.33% (p=0.008 n=5)      9.938 ± ∞ ¹    +565.54% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/nonascii-4096                1.273 ± ∞ ¹     10.732 ± ∞ ¹   +743.04% (p=0.008 n=5)     10.026 ± ∞ ¹    +687.60% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/subtitles-4096               1.707 ± ∞ ¹     10.909 ± ∞ ¹   +539.04% (p=0.008 n=5)     10.431 ± ∞ ¹    +511.01% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-4096                     1.786 ± ∞ ¹     11.181 ± ∞ ¹   +526.02% (p=0.008 n=5)     10.368 ± ∞ ¹    +480.52% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/ascii-65536                  4.241 ± ∞ ¹     17.674 ± ∞ ¹   +316.75% (p=0.008 n=5)     48.577 ± ∞ ¹   +1045.44% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/csv-65536                   925.3m ± ∞ ¹    9594.2m ± ∞ ¹   +936.87% (p=0.008 n=5)    9479.8m ± ∞ ¹    +924.51% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/invalid-65536               745.4m ± ∞ ¹     855.2m ± ∞ ¹          ~ (p=0.421 n=5)     828.9m ± ∞ ¹           ~ (p=0.548 n=5)
DecodeUtf8/UTF-16BE/mail-65536                  827.4m ± ∞ ¹    9338.2m ± ∞ ¹  +1028.62% (p=0.008 n=5)    9336.2m ± ∞ ¹   +1028.38% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/mixed-65536                  1.513 ± ∞ ¹      8.777 ± ∞ ¹   +480.16% (p=0.008 n=5)      9.013 ± ∞ ¹    +495.72% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/nonascii-65536               1.282 ± ∞ ¹      8.754 ± ∞ ¹   +582.95% (p=0.008 n=5)      8.934 ± ∞ ¹    +597.02% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/subtitles-65536             887.7m ± ∞ ¹    9341.2m ± ∞ ¹   +952.29% (p=0.008 n=5)    9024.6m ± ∞ ¹    +916.63% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-65536                   975.6m ± ∞ ¹    8694.6m ± ∞ ¹   +791.21% (p=0.008 n=5)    8192.2m ± ∞ ¹    +739.71% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/ascii-1048576                4.100 ± ∞ ¹     16.505 ± ∞ ¹   +302.55% (p=0.008 n=5)     42.742 ± ∞ ¹    +942.43% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/mixed-1048576                1.461 ± ∞ ¹      8.107 ± ∞ ¹   +454.85% (p=0.008 n=5)      9.142 ± ∞ ¹    +525.68% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/nonascii-1048576             1.401 ± ∞ ¹      7.869 ± ∞ ¹   +461.55% (p=0.008 n=5)      7.868 ± ∞ ¹    +461.53% (p=0.008 n=5)
DecodeUtf8/UTF-16BE/web-1048576                 845.6m ± ∞ ¹    7855.5m ± ∞ ¹   +828.99% (p=0.008 n=5)    7337.0m ± ∞ ¹    +767.67% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-16                   909.7m ± ∞ ¹     795.0m ± ∞ ¹          ~ (p=0.095 n=5)    1568.0m ± ∞ ¹     +72.36% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/csv-16                     934.5m ± ∞ ¹     795.7m ± ∞ ¹          ~ (p=0.095 n=5)    1726.3m ± ∞ ¹     +84.73% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/invalid-16                 938.1m ± ∞ ¹     769.5m ± ∞ ¹    -17.97% (p=0.008 n=5)    1581.9m ± ∞ ¹     +68.63% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mail-16                    919.8m ± ∞ ¹     760.7m ± ∞ ¹    -17.30% (p=0.008 n=5)    1554.7m ± ∞ ¹     +69.03% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-16                   947.4m ± ∞ ¹     765.8m ± ∞ ¹    -19.17% (p=0.008 n=5)    1570.7m ± ∞ ¹     +65.79% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-16               1003.6m ± ∞ ¹     771.5m ± ∞ ¹    -23.13% (p=0.008 n=5)    1563.7m ± ∞ ¹     +55.81% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/subtitles-16               928.2m ± ∞ ¹     767.5m ± ∞ ¹    -17.31% (p=0.008 n=5)    1589.8m ± ∞ ¹     +71.28% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-16                     918.5m ± ∞ ¹     765.6m ± ∞ ¹    -16.65% (p=0.008 n=5)    1575.4m ± ∞ ¹     +71.52% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-64                    1.505 ± ∞ ¹      2.708 ± ∞ ¹    +79.89% (p=0.008 n=5)      6.558 ± ∞ ¹    +335.66% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/csv-64                      1.595 ± ∞ ¹      2.792 ± ∞ ¹    +75.09% (p=0.008 n=5)      7.096 ± ∞ ¹    +345.02% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/invalid-64                  1.239 ± ∞ ¹      1.317 ± ∞ ¹          ~ (p=0.222 n=5)      1.239 ± ∞ ¹           ~ (p=0.690 n=5)
DecodeUtf16/UTF-16BE/mail-64                     1.498 ± ∞ ¹      2.644 ± ∞ ¹    +76.50% (p=0.008 n=5)      6.475 ± ∞ ¹    +332.21% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-64                    1.500 ± ∞ ¹      2.612 ± ∞ ¹    +74.15% (p=0.008 n=5)      6.133 ± ∞ ¹    +308.96% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-64                 1.501 ± ∞ ¹      2.628 ± ∞ ¹    +75.03% (p=0.008 n=5)      6.534 ± ∞ ¹    +335.17% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/subtitles-64                1.485 ± ∞ ¹      2.584 ± ∞ ¹    +73.99% (p=0.008 n=5)      6.530 ± ∞ ¹    +339.63% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-64                      1.500 ± ∞ ¹      2.622 ± ∞ ¹    +74.86% (p=0.008 n=5)      6.494 ± ∞ ¹    +333.10% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-256                   2.421 ± ∞ ¹      6.245 ± ∞ ¹   +157.93% (p=0.008 n=5)     20.263 ± ∞ ¹    +736.83% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/csv-256                     2.498 ± ∞ ¹      6.160 ± ∞ ¹   +146.64% (p=0.008 n=5)     20.273 ± ∞ ¹    +711.63% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/invalid-256                 1.582 ± ∞ ¹      1.409 ± ∞ ¹    -10.94% (p=0.008 n=5)      2.748 ± ∞ ¹     +73.68% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mail-256                    2.495 ± ∞ ¹      6.190 ± ∞ ¹   +148.09% (p=0.008 n=5)     20.340 ± ∞ ¹    +715.20% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-256                   2.506 ± ∞ ¹      6.260 ± ∞ ¹   +149.78% (p=0.008 n=5)     21.820 ± ∞ ¹    +770.72% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-256                2.708 ± ∞ ¹      6.252 ± ∞ ¹   +130.84% (p=0.008 n=5)     19.248 ± ∞ ¹    +610.72% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/subtitles-256               2.498 ± ∞ ¹      6.210 ± ∞ ¹   +148.66% (p=0.008 n=5)     20.386 ± ∞ ¹    +716.23% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-256                     2.489 ± ∞ ¹      6.211 ± ∞ ¹   +149.53% (p=0.008 n=5)     20.227 ± ∞ ¹    +712.61% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-4096                  3.138 ± ∞ ¹      9.357 ± ∞ ¹   +198.14% (p=0.008 n=5)     51.980 ± ∞ ¹   +1556.32% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/csv-4096                    3.136 ± ∞ ¹      9.412 ± ∞ ¹   +200.16% (p=0.008 n=5)     52.044 ± ∞ ¹   +1559.73% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/invalid-4096              1798.5m ± ∞ ¹     253.3m ± ∞ ¹    -85.92% (p=0.008 n=5)    2543.8m ± ∞ ¹           ~ (p=0.095 n=5)
DecodeUtf16/UTF-16BE/mail-4096                   3.134 ± ∞ ¹      9.448 ± ∞ ¹   +201.47% (p=0.008 n=5)     52.069 ± ∞ ¹   +1561.54% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-4096                  3.150 ± ∞ ¹      9.509 ± ∞ ¹   +201.93% (p=0.008 n=5)     51.985 ± ∞ ¹   +1550.58% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-4096               3.145 ± ∞ ¹      9.488 ± ∞ ¹   +201.68% (p=0.008 n=5)     52.351 ± ∞ ¹   +1564.64% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/subtitles-4096              3.142 ± ∞ ¹      9.488 ± ∞ ¹   +202.02% (p=0.008 n=5)     51.674 ± ∞ ¹   +1544.90% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-4096                    3.418 ± ∞ ¹      9.412 ± ∞ ¹   +175.38% (p=0.008 n=5)     51.086 ± ∞ ¹   +1394.75% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-65536                 3.161 ± ∞ ¹      7.240 ± ∞ ¹   +129.04% (p=0.008 n=5)     40.027 ± ∞ ¹   +1166.23% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/csv-65536                   3.168 ± ∞ ¹      7.288 ± ∞ ¹   +130.08% (p=0.008 n=5)     40.619 ± ∞ ¹   +1182.28% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/invalid-65536            1764.30m ± ∞ ¹     16.40m ± ∞ ¹    -99.07% (p=0.008 n=5)   2455.90m ± ∞ ¹     +39.20% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mail-65536                  3.193 ± ∞ ¹      7.255 ± ∞ ¹   +127.23% (p=0.008 n=5)     40.412 ± ∞ ¹   +1165.64% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-65536                 3.167 ± ∞ ¹      7.258 ± ∞ ¹   +129.13% (p=0.008 n=5)     40.586 ± ∞ ¹   +1181.35% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-65536              3.180 ± ∞ ¹      7.296 ± ∞ ¹   +129.47% (p=0.008 n=5)     40.408 ± ∞ ¹   +1170.82% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/subtitles-65536             3.185 ± ∞ ¹      7.282 ± ∞ ¹   +128.61% (p=0.008 n=5)     40.662 ± ∞ ¹   +1176.59% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-65536                   3.175 ± ∞ ¹      7.280 ± ∞ ¹   +129.27% (p=0.008 n=5)     40.451 ± ∞ ¹   +1173.86% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/ascii-1048576               3.033 ± ∞ ¹      5.858 ± ∞ ¹    +93.14% (p=0.008 n=5)     21.162 ± ∞ ¹    +597.65% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/mixed-1048576               3.055 ± ∞ ¹      5.964 ± ∞ ¹    +95.19% (p=0.008 n=5)     22.688 ± ∞ ¹    +642.58% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/nonascii-1048576            3.074 ± ∞ ¹      6.538 ± ∞ ¹   +112.70% (p=0.008 n=5)     23.610 ± ∞ ¹    +668.05% (p=0.008 n=5)
DecodeUtf16/UTF-16BE/web-1048576                 3.032 ± ∞ ¹      5.929 ± ∞ ¹    +95.56% (p=0.008 n=5)     21.485 ± ∞ ¹    +608.67% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-16                   1076.8m ± ∞ ¹     719.9m ± ∞ ¹    -33.14% (p=0.008 n=5)    1454.4m ± ∞ ¹     +35.07% (p=0.016 n=5)
DecodeUtf8/UTF-16LE/csv-16                     1081.9m ± ∞ ¹     722.0m ± ∞ ¹    -33.27% (p=0.008 n=5)    1450.2m ± ∞ ¹     +34.04% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/invalid-16                  655.4m ± ∞ ¹     451.1m ± ∞ ¹    -31.17% (p=0.008 n=5)     621.7m ± ∞ ¹           ~ (p=0.095 n=5)
DecodeUtf8/UTF-16LE/mail-16                    1068.4m ± ∞ ¹     720.8m ± ∞ ¹    -32.53% (p=0.008 n=5)    1463.2m ± ∞ ¹     +36.95% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-16                    694.8m ± ∞ ¹     496.9m ± ∞ ¹    -28.48% (p=0.016 n=5)     766.1m ± ∞ ¹           ~ (p=0.151 n=5)
DecodeUtf8/UTF-16LE/nonascii-16                 657.6m ± ∞ ¹     490.0m ± ∞ ¹    -25.49% (p=0.008 n=5)     666.6m ± ∞ ¹           ~ (p=0.841 n=5)
DecodeUtf8/UTF-16LE/subtitles-16               1081.1m ± ∞ ¹     724.0m ± ∞ ¹    -33.03% (p=0.008 n=5)    1455.0m ± ∞ ¹     +34.59% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-16                     1064.8m ± ∞ ¹     720.1m ± ∞ ¹    -32.37% (p=0.008 n=5)    1452.1m ± ∞ ¹     +36.37% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-64                     2.823 ± ∞ ¹      3.095 ± ∞ ¹     +9.65% (p=0.008 n=5)      6.038 ± ∞ ¹    +113.90% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/csv-64                       2.823 ± ∞ ¹      3.082 ± ∞ ¹     +9.18% (p=0.008 n=5)      5.950 ± ∞ ¹    +110.82% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/invalid-64                  703.5m ± ∞ ¹     555.5m ± ∞ ¹    -21.04% (p=0.008 n=5)     588.1m ± ∞ ¹     -16.40% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mail-64                      2.820 ± ∞ ¹      3.087 ± ∞ ¹          ~ (p=0.151 n=5)      5.841 ± ∞ ¹    +107.14% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-64                    914.6m ± ∞ ¹    1886.7m ± ∞ ¹   +106.29% (p=0.008 n=5)    1697.4m ± ∞ ¹     +85.59% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/nonascii-64                 818.7m ± ∞ ¹    1906.6m ± ∞ ¹   +132.88% (p=0.008 n=5)    1700.4m ± ∞ ¹    +107.70% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/subtitles-64                 2.822 ± ∞ ¹      3.093 ± ∞ ¹          ~ (p=0.421 n=5)      6.014 ± ∞ ¹    +113.12% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-64                       2.810 ± ∞ ¹      3.357 ± ∞ ¹          ~ (p=0.151 n=5)      5.922 ± ∞ ¹    +110.77% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-256                    3.781 ± ∞ ¹      9.659 ± ∞ ¹   +155.45% (p=0.008 n=5)     17.629 ± ∞ ¹    +366.24% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/csv-256                      1.310 ± ∞ ¹      5.150 ± ∞ ¹   +293.16% (p=0.008 n=5)      4.972 ± ∞ ¹    +279.53% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/invalid-256                 915.0m ± ∞ ¹    1691.0m ± ∞ ¹    +84.81% (p=0.008 n=5)    1550.6m ± ∞ ¹     +69.46% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mail-256                     2.933 ± ∞ ¹      6.889 ± ∞ ¹   +134.91% (p=0.008 n=5)      6.842 ± ∞ ¹    +133.28% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-256                    1.207 ± ∞ ¹      4.800 ± ∞ ¹   +297.52% (p=0.008 n=5)      4.613 ± ∞ ¹    +282.05% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/nonascii-256                 1.116 ± ∞ ¹      4.815 ± ∞ ¹   +331.38% (p=0.008 n=5)      4.617 ± ∞ ¹    +313.64% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/subtitles-256                1.486 ± ∞ ¹      5.354 ± ∞ ¹   +260.28% (p=0.008 n=5)      5.369 ± ∞ ¹    +261.31% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-256                      1.885 ± ∞ ¹      5.973 ± ∞ ¹   +216.94% (p=0.008 n=5)      5.898 ± ∞ ¹    +212.93% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-4096                   6.591 ± ∞ ¹     18.113 ± ∞ ¹   +174.81% (p=0.008 n=5)     57.071 ± ∞ ¹    +765.86% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/csv-4096                     1.424 ± ∞ ¹      6.389 ± ∞ ¹   +348.64% (p=0.008 n=5)      6.420 ± ∞ ¹    +350.85% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/invalid-4096                927.9m ± ∞ ¹    1445.7m ± ∞ ¹    +55.80% (p=0.008 n=5)    1257.4m ± ∞ ¹     +35.51% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mail-4096                    1.439 ± ∞ ¹      7.354 ± ∞ ¹   +411.15% (p=0.008 n=5)      7.162 ± ∞ ¹    +397.81% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-4096                   1.295 ± ∞ ¹      6.356 ± ∞ ¹   +390.89% (p=0.008 n=5)      5.931 ± ∞ ¹    +358.08% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/nonascii-4096                1.142 ± ∞ ¹      6.429 ± ∞ ¹   +463.10% (p=0.008 n=5)      6.131 ± ∞ ¹    +437.00% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/subtitles-4096               1.371 ± ∞ ¹      6.864 ± ∞ ¹   +400.57% (p=0.008 n=5)      6.777 ± ∞ ¹    +394.21% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-4096                     1.343 ± ∞ ¹      7.492 ± ∞ ¹   +457.71% (p=0.008 n=5)      6.531 ± ∞ ¹    +386.15% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-65536                  6.378 ± ∞ ¹     16.807 ± ∞ ¹   +163.52% (p=0.008 n=5)     52.393 ± ∞ ¹    +721.51% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/csv-65536                    1.224 ± ∞ ¹      5.876 ± ∞ ¹   +380.07% (p=0.008 n=5)      5.970 ± ∞ ¹    +387.78% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/invalid-65536               764.1m ± ∞ ¹     899.6m ± ∞ ¹    +17.73% (p=0.008 n=5)     896.1m ± ∞ ¹     +17.28% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mail-65536                   1.425 ± ∞ ¹      7.546 ± ∞ ¹   +429.67% (p=0.008 n=5)      7.743 ± ∞ ¹    +443.49% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-65536                  1.297 ± ∞ ¹      6.352 ± ∞ ¹   +389.71% (p=0.008 n=5)      6.060 ± ∞ ¹    +367.23% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/nonascii-65536               1.120 ± ∞ ¹      6.125 ± ∞ ¹   +446.79% (p=0.008 n=5)      6.029 ± ∞ ¹    +438.23% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/subtitles-65536              1.189 ± ∞ ¹      6.523 ± ∞ ¹   +448.51% (p=0.008 n=5)      6.292 ± ∞ ¹    +429.10% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-65536                    1.151 ± ∞ ¹      6.364 ± ∞ ¹   +452.81% (p=0.008 n=5)      6.222 ± ∞ ¹    +440.46% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/ascii-1048576                6.783 ± ∞ ¹     17.568 ± ∞ ¹   +158.99% (p=0.008 n=5)     47.316 ± ∞ ¹    +597.54% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/mixed-1048576                1.313 ± ∞ ¹      6.515 ± ∞ ¹   +396.03% (p=0.008 n=5)      5.700 ± ∞ ¹    +333.99% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/nonascii-1048576             1.128 ± ∞ ¹      5.418 ± ∞ ¹   +380.37% (p=0.008 n=5)      5.315 ± ∞ ¹    +371.25% (p=0.008 n=5)
DecodeUtf8/UTF-16LE/web-1048576                  1.008 ± ∞ ¹      5.382 ± ∞ ¹   +433.69% (p=0.008 n=5)      5.166 ± ∞ ¹    +412.21% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-16                   928.9m ± ∞ ¹     823.9m ± ∞ ¹    -11.30% (p=0.032 n=5)    1706.9m ± ∞ ¹     +83.75% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/csv-16                     927.9m ± ∞ ¹     823.8m ± ∞ ¹    -11.22% (p=0.008 n=5)    1722.5m ± ∞ ¹     +85.63% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/invalid-16                 949.3m ± ∞ ¹     821.3m ± ∞ ¹    -13.48% (p=0.008 n=5)    1699.1m ± ∞ ¹     +78.98% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mail-16                    927.4m ± ∞ ¹     822.1m ± ∞ ¹    -11.35% (p=0.008 n=5)    1709.6m ± ∞ ¹     +84.34% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-16                   916.9m ± ∞ ¹     823.4m ± ∞ ¹    -10.20% (p=0.008 n=5)    1707.4m ± ∞ ¹     +86.21% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-16                916.3m ± ∞ ¹     821.9m ± ∞ ¹    -10.30% (p=0.008 n=5)    1702.2m ± ∞ ¹     +85.77% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/subtitles-16               944.2m ± ∞ ¹     817.8m ± ∞ ¹          ~ (p=0.095 n=5)    1673.6m ± ∞ ¹     +77.25% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-16                     928.3m ± ∞ ¹     822.8m ± ∞ ¹          ~ (p=0.056 n=5)    1708.5m ± ∞ ¹     +84.05% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-64                    2.076 ± ∞ ¹      3.662 ± ∞ ¹    +76.41% (p=0.008 n=5)      6.720 ± ∞ ¹    +223.69% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/csv-64                      2.349 ± ∞ ¹      4.223 ± ∞ ¹    +79.82% (p=0.008 n=5)      6.677 ± ∞ ¹    +184.31% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/invalid-64                1267.6m ± ∞ ¹    1097.2m ± ∞ ¹          ~ (p=0.222 n=5)     931.3m ± ∞ ¹     -26.53% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mail-64                     2.084 ± ∞ ¹      3.363 ± ∞ ¹    +61.35% (p=0.008 n=5)      6.818 ± ∞ ¹    +227.09% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-64                    2.103 ± ∞ ¹      3.334 ± ∞ ¹    +58.50% (p=0.008 n=5)      6.862 ± ∞ ¹    +226.25% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-64                 1.996 ± ∞ ¹      3.360 ± ∞ ¹    +68.34% (p=0.008 n=5)      7.114 ± ∞ ¹    +256.44% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/subtitles-64                1.916 ± ∞ ¹      3.352 ± ∞ ¹    +74.89% (p=0.008 n=5)      6.823 ± ∞ ¹    +256.04% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-64                      1.896 ± ∞ ¹      3.353 ± ∞ ¹    +76.83% (p=0.008 n=5)      6.923 ± ∞ ¹    +265.12% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-256                   2.883 ± ∞ ¹     12.271 ± ∞ ¹   +325.63% (p=0.008 n=5)     20.962 ± ∞ ¹    +627.11% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/csv-256                     2.982 ± ∞ ¹     12.176 ± ∞ ¹   +308.29% (p=0.008 n=5)     21.013 ± ∞ ¹    +604.62% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/invalid-256                 2.150 ± ∞ ¹      3.953 ± ∞ ¹    +83.88% (p=0.008 n=5)      2.363 ± ∞ ¹           ~ (p=0.095 n=5)
DecodeUtf16/UTF-16LE/mail-256                    2.965 ± ∞ ¹     12.233 ± ∞ ¹   +312.56% (p=0.008 n=5)     20.946 ± ∞ ¹    +606.40% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-256                   2.972 ± ∞ ¹     12.265 ± ∞ ¹   +312.64% (p=0.008 n=5)     20.666 ± ∞ ¹    +595.26% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-256                2.977 ± ∞ ¹     12.159 ± ∞ ¹   +308.44% (p=0.008 n=5)     20.878 ± ∞ ¹    +601.34% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/subtitles-256               2.969 ± ∞ ¹     12.155 ± ∞ ¹   +309.35% (p=0.008 n=5)     20.930 ± ∞ ¹    +604.89% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-256                     3.224 ± ∞ ¹     13.108 ± ∞ ¹   +306.64% (p=0.008 n=5)     23.347 ± ∞ ¹    +624.26% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-4096                  4.518 ± ∞ ¹     62.649 ± ∞ ¹  +1286.68% (p=0.008 n=5)     56.905 ± ∞ ¹   +1159.54% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/csv-4096                    4.150 ± ∞ ¹     62.343 ± ∞ ¹  +1402.30% (p=0.008 n=5)     57.144 ± ∞ ¹   +1277.03% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/invalid-4096                2.236 ± ∞ ¹      2.758 ± ∞ ¹          ~ (p=0.056 n=5)      2.894 ± ∞ ¹     +29.42% (p=0.032 n=5)
DecodeUtf16/UTF-16LE/mail-4096                   4.155 ± ∞ ¹     62.660 ± ∞ ¹  +1408.06% (p=0.008 n=5)     56.820 ± ∞ ¹   +1267.52% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-4096                  4.156 ± ∞ ¹     62.504 ± ∞ ¹  +1403.91% (p=0.008 n=5)     56.716 ± ∞ ¹   +1264.64% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-4096               4.153 ± ∞ ¹     62.327 ± ∞ ¹  +1400.92% (p=0.008 n=5)     57.126 ± ∞ ¹   +1275.66% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/subtitles-4096              4.134 ± ∞ ¹     61.972 ± ∞ ¹  +1399.09% (p=0.008 n=5)     56.472 ± ∞ ¹   +1266.04% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-4096                    4.131 ± ∞ ¹     62.207 ± ∞ ¹  +1406.01% (p=0.008 n=5)     56.808 ± ∞ ¹   +1275.30% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-65536                 4.274 ± ∞ ¹     30.051 ± ∞ ¹   +603.10% (p=0.008 n=5)     40.676 ± ∞ ¹    +851.69% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/csv-65536                   4.281 ± ∞ ¹     31.944 ± ∞ ¹   +646.13% (p=0.008 n=5)     42.881 ± ∞ ¹    +901.59% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/invalid-65536            1915.00m ± ∞ ¹     87.00m ± ∞ ¹    -95.46% (p=0.008 n=5)   1763.90m ± ∞ ¹           ~ (p=0.310 n=5)
DecodeUtf16/UTF-16LE/mail-65536                  4.263 ± ∞ ¹     31.775 ± ∞ ¹   +645.45% (p=0.008 n=5)     40.821 ± ∞ ¹    +857.68% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-65536                 4.254 ± ∞ ¹     30.646 ± ∞ ¹   +620.33% (p=0.008 n=5)     43.291 ± ∞ ¹    +917.56% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-65536              4.503 ± ∞ ¹     31.354 ± ∞ ¹   +596.33% (p=0.008 n=5)     42.773 ± ∞ ¹    +849.93% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/subtitles-65536             4.533 ± ∞ ¹     31.889 ± ∞ ¹   +603.43% (p=0.008 n=5)     43.239 ± ∞ ¹    +853.82% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-65536                   4.243 ± ∞ ¹     30.016 ± ∞ ¹   +607.45% (p=0.008 n=5)     40.750 ± ∞ ¹    +860.46% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/ascii-1048576               3.955 ± ∞ ¹     19.603 ± ∞ ¹   +395.71% (p=0.008 n=5)     21.988 ± ∞ ¹    +456.01% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/mixed-1048576               3.966 ± ∞ ¹     18.486 ± ∞ ¹   +366.04% (p=0.008 n=5)     22.039 ± ∞ ¹    +455.62% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/nonascii-1048576            3.994 ± ∞ ¹     19.083 ± ∞ ¹   +377.83% (p=0.008 n=5)     21.931 ± ∞ ¹    +449.13% (p=0.008 n=5)
DecodeUtf16/UTF-16LE/web-1048576                 3.919 ± ∞ ¹     19.723 ± ∞ ¹   +403.22% (p=0.008 n=5)     22.070 ± ∞ ¹    +463.11% (p=0.008 n=5)
geomean                                         965.7m            1.710          +73.07%                    3.292          +237.95%
```

The run directories (raw samples of every arm) are not committed; each
command above regenerates them.
