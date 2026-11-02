# Compile-time decoders and encoders

A decoder and encoder specialized at compile time to one encoding, or to a
chosen set, so that a program links only those encodings' code and tables.
The runtime `Decoder` and `Encoder` stay for callers that pick the encoding
from a label at run time, and become the same type over every encoding.
Measurements: `docs/slop/results/comptime-20261102.md`. Prototype:
`src/specialized.zig`, tested by `src/specialized_test.zig`, with the
experiment for "no new type" in `src/inline_init.zig`. Its build,
link-size programs, and bench arms are in `bench/comptime/`.

## The problem

link-size-20261102.md: a program that decodes only windows-1252, with
`Decoder.init(.windows_1252, .{})` known at compile time, links 178 KB of
decode tables in ReleaseSmall. `Decoder` holds a union of every family's
state, and `decodeToUtf8` is one function with a switch over the union's
tag. When Zig analyzes that function, it analyzes every family's `decode`,
and they reference every table. LLVM keeps code that the call graph or a
stored function pointer can reach. It does not track which tag values the
union in memory can hold, so the other prongs stay. encoding_rs pays the
same cost.

## What Zig drops, and when

Zig analyzes a declaration only when something analyzed refers to it, and
emits a function only when analysis reaches it. That gives the rules the
design is built on:

- Importing a file, or reading one declaration of it, analyzes nothing
  else. `codecs.families` imports every family, and reading a family's
  `encodings` or asking `@hasDecl(module, "Encoder")` does not analyze its
  decoder, so a type built from `families` touches only the families it
  chooses.
- A switch on a value known at compile time analyzes only the prong it
  takes. An `inline else` over a union analyzes every prong, so its
  reach is set by the union's fields, which a type parameter can choose.
- A generic function is instantiated once per set of compile-time
  arguments. `single_byte.Decoder.decode(u8, ...)` is one function whether
  the runtime `Decoder` or a specialized one calls it. Two types over the
  same family share the family's code, and only their thin wrappers are
  emitted twice. Measured: `both` (results, size table).
- A table is emitted only if analyzed code refers to it. A family state
  built at compile time with `init(.windows_1252)` holds a pointer to one
  256-byte table, so only that table is emitted.

## Without a new type?

Can `Decoder.init` with an encoding known at compile time get there
without a new type? Not with `Decoder` as it is: the state is a union, and
`decodeToUtf8` switches on its run-time tag. Making `init` inline does not
change what `decodeToUtf8` reaches.

It can if the family is reached through a function pointer that `init`
stores. Make `init` inline and `switch (e) { inline else => ... }` over the
encoding. With a constant encoding, only one prong is analyzed, and the
decoder stores a pointer to that family's decode only. With a run-time
encoding, all of them are analyzed. `src/inline_init.zig` does this for
`.bom = .keep` and measures it:

- windows-1252 known at compile time: +296 B .rodata and +1.7 KB .text
  in ReleaseSmall, against 178 KB and 34 KB today. The size goal is met
  with no new API.
- Encoding chosen at run time: +19 KB .text against today's `Decoder`
  (53.7 KB against 34.4 KB). The per-family thunks inline some families'
  decoders, utf16's 8 KB among them, while out-of-line copies remain.
- Per call it is faster on decode at 16 bytes: 0.830× `Decoder`'s time
  (geomean), against 0.851× for a one-encoding `DecoderFor`. It calls the
  family out of line, so the caller stays small. Inlining the family's
  whole decoder into the caller, as `Decoder` and `DecoderFor` do, pays its
  prologue on every short call. That is a lesson for the wrappers more than
  an argument for the pointer (results §3).
- It does not remove the dispatch; it moves it into a pointer, which adds
  eight bytes to `Decoder`.
- It works only while `init`'s arguments are known at compile time at
  the call site. One `init` from a label anywhere in the program links
  everything again, and nothing in the types says so.
- `.sniff` has the same problem one level down. The switch to UTF-8 or
  UTF-16 on a byte order mark references those decoders unless it too
  goes through a pointer that an inline `init` sets only when
  `options.bom` is a constant `.sniff`.

It is a useful trick, but the size it saves depends on how the caller
writes `init`, which is invisible and easy to lose, and it costs 19 KB
wherever the encoding comes from a label. A type parameter makes the set
explicit, removes the dispatch, and leaves the runtime type as it is. That
is the proposal. The trick stays on file as the measured alternative.

## API

```zig
/// A decoder for `encodings`, in any order.
pub fn DecoderFor(comptime encodings: []const Encoding) type;
/// An encoder for the output encodings of `encodings`.
pub fn EncoderFor(comptime encodings: []const Encoding) type;

/// What `.sniff` can switch to: add these for the standard's "decode".
pub const bom_encodings = [_]Encoding{ .utf_8, .utf_16be, .utf_16le };
/// Every implemented encoding but the CJK ones (open question below).
pub const no_cjk: [N]Encoding;

pub const Decoder = DecoderFor(&implemented);
pub const Encoder = EncoderFor(&implemented);
```

```zig
// A ZIP reader: filenames without the UTF-8 flag are IBM437.
var d: encoding.DecoderFor(&.{.ibm437}) = .init(.ibm437, .{ .bom = .keep });
const r = d.decodeToUtf8(name, &buf, true);

// A mail reader: UTF-8 or windows-1252 from the charset, with the
// standard's byte order mark handling. Any other charset panics in init.
const Mail = encoding.DecoderFor(&(.{.windows_1252} ++ encoding.bom_encodings));
var m: Mail = .init(charset orelse .windows_1252, .{});

// Shift_JIS out.
var e: encoding.EncoderFor(&.{.shift_jis}) = .init(.shift_jis, .{});
```

The rules:

- **The same calls as `Decoder` and `Encoder`.** `init`, `decodeToUtf8`,
  `decodeToUtf16`, `maxUtf8Len`,
  `maxUtf16Len`, the `encoding` field, and the same `Result`, `Status`,
  and `Mode`. Code written against `Decoder` compiles against any
  `DecoderFor` whose options it can express. `init` takes the encoding
  even for a set of one, so changing the type is the only edit.
- **The set is canonical.** `DecoderFor` turns its slice into a
  `std.EnumSet(Encoding)` and builds the type from that, so the same
  encodings in any order, or repeated, give the same type.
- **Errors at compile time where possible.** An empty set or an
  unimplemented encoding is a compile error. So is `.sniff` on a set that
  cannot switch encodings (next rule). An encoding outside the set
  panics in `init`, as an unimplemented one does in `Decoder.init` today.
  The check runs in every mode, because a wrong family state would read
  out of bounds.
- **Byte order marks.** `.sniff` can switch to UTF-8, UTF-16BE, or
  UTF-16LE, and those decoders cost 14.0 KB of .text and 2.3 KB of .rodata
  in ReleaseSmall, 17 times the windows-1252 decoder. So the cost is
  explicit. A set that holds all of `bom_encodings` takes
  `Decoder.Options`, whose default is `.sniff`. Any other set takes
  `OptionsWithoutSniff`, whose `bom` is `.remove` or `.keep` with no
  default. Passing `.sniff` there is a compile error, and `.{}` is
  rejected, so code moved from `Decoder` must say which behavior it wants
  and cannot change behavior silently. `.remove` is TextDecoder's default
  and the standard's "UTF-8 decode". The runtime `Decoder` holds every
  encoding, so its options do not change.
- **Error modes** stay a run-time option. The families test `mode` only
  after they find an error, so a compile-time mode would remove a branch
  on the error path and nothing in the loop. Not measured; a
  `DecoderFor(set, mode)` could be added later if a profile shows it.
- **`maxUtf8Len`** is the same method. It counts held bytes, and with
  `.sniff` it covers UTF-8 and UTF-16. Because a fresh state is built at
  compile time, `comptime D.init(e, opts).maxUtf8Len(n).?` sizes a stack
  buffer for the first call (tested). This works for the runtime
  `Decoder` too.

## How it shares the families and the contract

`src/specialized.zig` has three parts:

1. **`Families(set, "Decoder" or "Encoder")`**: from `codecs.families`, the
   families with an encoding in the set. The state is that family's own
   type when there is one family, with no tag, and a tagged union of just
   those families otherwise. It also builds each encoding's fresh state at
   compile time, as `wave1-core`'s `fresh_states` does, and provides
   `decode`, `encode`, and the `maxLen`s. With one family, these are direct
   calls; otherwise they are the same `inline else` switch as
   `codecs.decode`, over fewer prongs. This replaces `codecs.DecoderState`,
   `EncoderState`, `initDecoder`, `initEncoder`, `decode`, `encode`,
   `decoderMaxLen`, and `encoderMaxLen`.
2. **`Decoder(set)`**: `src/Decoder.zig` made generic over `Families(set)`.
   The byte order mark phases, the held bytes, and the replay are
   `Decoder.zig`'s, line for line. The only additions are `can_sniff`,
   which is known at compile time, and the options rule.
3. **`Encoder(set)`**: `src/Encoder.zig` likewise. Characters split across
   calls are handled in the wrapper, so families see whole characters.

The families do not change. They keep `init(e)`, `decode`, `encode`, and
`maxLen`, and the streaming contract in `adding-an-encoding.md` holds for
any set, because the wrappers are the runtime ones. For the prototype,
which may not edit `Decoder.zig` and `Encoder.zig`, the wrappers are
copies. The tests run every specialized type in lockstep with the runtime
type: the same chunks and output room into both, with every call's result,
output, `maxLen`, and `encoding` compared. They cover every implemented
encoding, both units, both modes, every byte order mark option, and random
splits. A deliberately broken replay fails them.

**The runtime types built from it.** `Decoder` becomes
`DecoderFor(&implemented)`, and `Encoder` becomes
`EncoderFor(&implemented)`. The prototype's `DecoderFor(&implemented)`
links what `Decoder` links: 185,034 B of .rodata against 185,642, and
33,809 B of .text against 34,420, in ReleaseSmall. It matches
`bench-zig`'s checksums on all 7,040 rows, and costs the same per call
(1.004× at 16 bytes, 0.989× at 64 KiB). The change below is tested on
`wave1-core`: `zig build test` passes with `Decoder.zig` and `Encoder.zig`
deleted. After the core orb lands, the change is:

- `src/specialized.zig` is renamed (to `src/coder.zig`, say) and takes
  `Decoder.zig`'s and `Encoder.zig`'s documentation and tests.
- `src/Decoder.zig` and `src/Encoder.zig` are deleted.
- `codecs.zig` keeps `families`, `family_of`, and `implemented`. Its
  state unions and dispatch move into `Families`.
- `root.zig` exports `Decoder`, `Encoder`, `DecoderFor`, `EncoderFor`,
  `bom_encodings`, and `OptionsWithoutSniff`.

The whole change is `docs/slop/comptime-shared.diff`, to `git apply` on
this branch once `wave1-core` is under it. It includes Japanese's
`decodeAs`, deletes `src/inline_init.zig`, and points `bench/comptime/` at
the public module. With it applied on `wave1-core` (`d72503e`), `just test`,
ziglint, `zig fmt --check`, and `bench/comptime`'s `zig build test arms
sizes` pass.

**Families that tell encodings apart at run time.** Three families serve
more than one encoding:

- `single_byte` keeps a table pointer in its state. That pointer is built
  at compile time, so this costs nothing.
- `utf16` keeps a byte-order flag, a few instructions.
- `japanese` switches on a `kind` at run time between Shift_JIS, EUC-JP,
  and ISO-2022-JP, so `DecoderFor(&.{.shift_jis})` links EUC-JP's
  decoder and jis0212, 13 KB.

The prototype supports an optional family declaration for this case:
`decodeAs(d, comptime Unit, comptime e, ...)` and `encodeAs`, which are `decode` and
`encode` with the encoding as a compile-time parameter. When a family has
exactly one encoding in the set and declares them, `Families` calls them.
Japanese's `decode` becomes
`switch (d.kind) { inline else => |k| d.decodeAs(k, ...) }`, so the
runtime path does not change. Measured with that change applied locally:
Shift_JIS decode drops from 29.7 KB to 16.5 KB of .rodata and from 8.5 KB to
3.5 KB of .text, and the runtime types are the same size.
`gb18030`'s GBK flag, which only affects the encoder, saves too little to
need it.

## Sets

- **One encoding** is the case the problem names: windows-1252 links
  320 B of .rodata and 812 B of .text in ReleaseSmall, against 178 KB and
  34 KB.
- **"HTML-relevant"** is the standard's list. Every encoding in it is
  one a page can declare, and a browser or crawler needs them all, which
  is the runtime `Decoder`. A smaller "web" set has nothing principled to
  drop. Leaving out IBM437 and IBM850 saves 512 bytes.
- **Everything but CJK** (`no_cjk`) is the useful cut: Western, Cyrillic,
  Greek, Hebrew, Arabic, Thai, and Vietnamese single-byte encodings, UTF-8,
  UTF-16, x-user-defined, and replacement. ReleaseSmall, net of the label
  table: 8.4 KB of .rodata and 15.6 KB of .text, against 176 KB and 33.5 KB
  for every encoding. Most of the .text is UTF-8 and UTF-16.
- **A program's own few**, like `{UTF-8, windows-1252}` for mail or
  subtitles: 0.9 KB of .rodata and 6.3 KB of .text net of the label table.
  UTF-8 is most of it.

`no_cjk` is the only named set the prototype defines; `implemented` and
`bom_encodings` already exist or are needed. Callers can concatenate
arrays with `++` for their own sets. Duplicates are fine because the set
is canonical.

## Speed

A one-family `DecoderFor` has no tag and no switch, and its fresh state is
a constant, so a call is the family's decode and nothing else. The
interleaved, pinned A/B against `bench-zig` on `wave1-core` covers 460 rows
across every family, at 16 bytes and 64 KiB:

- **One encoding**: 0.876× the time per call at 16 bytes (17.33 against
  19.79 ns geomean), 0.851× on decode and 0.904× on encode. Single-byte
  and CJK decode take 7–9 ns against 10–12 ns. At 64 KiB it is within
  1%.
- **The runtime types built from the generic**: 1.004× at 16 bytes and
  0.989× at 64 KiB, with the same instructions in the caller.
- **EUC-JP is the exception**, 1.3 ns slower, because Japanese still
  switches on its encoding inside `decode`. `decodeAs` removes that switch,
  but that is not measured.

Two lessons came out of the measurement. Both are in the results:

- Call a set's methods at compile time explicitly: `if (set.count() == 1)`
  ran a popcount on every `init`.
- `bench-zig`'s numbers depend on LLVM inlining `decodeToUtf8` into its
  single caller. With 41 call sites the same decoder was 1.34× slower.

## Plan

1. The core orb lands `wave1-core`.
2. The prototype becomes the implementation of `Decoder` and `Encoder`.
   This is a refactor with no behavior change: the existing tests,
   fuzzer, oracle, WPT, and props pass unchanged, and `bench-compare` shows
   no change against `head`.
3. `DecoderFor`, `EncoderFor`, `bom_encodings`, and `OptionsWithoutSniff`
   become public, with a CHANGELOG line, and the lockstep test becomes a
   test of the public types. The fuzzer gets a specialized target.
4. Japanese adds `decodeAs` and `encodeAs`.

## Decisions (the owner's, 2026-11-02)

Landed as `src/coder.zig`, with `Decoder.zig`, `Encoder.zig`, and
`inline_init.zig` deleted; the sections above describe the prototype as
measured.

1. **A type parameter**, not the inline-`init` trick.
2. **The names stay:** `DecoderFor` and `EncoderFor`, taking a slice.
3. **`OptionsWithoutSniff`** for sets without `bom_encodings`: no
   `.sniff` and no default, a compile error rather than 16 KB.
4. **No named sets exported.** `no_cjk` stays internal, for the tests and
   the size programs.
5. **`decodeAs` and `encodeAs`** are an optional part of the family
   contract (`adding-an-encoding.md`); Japanese adds them in wave 2.
