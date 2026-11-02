# AGENTS.md

Working notes for AI coding agents in baskingspot/encoding.

## What this is

Legacy text encodings in Zig, with no C: every encoding in the WHATWG Encoding Standard (Shift_JIS, EUC-JP, ISO-2022-JP, GBK, gb18030, Big5, EUC-KR, the windows-125x and ISO-8859 single-byte families, KOI8, UTF-16), decoded to and encoded from UTF-8 and UTF-16, plus a few IBM code pages and charset detection. Think Rust's encoding_rs, or Go's `golang.org/x/text/encoding`, as a Zig package. It is incubating: unstable, with no promises about its API.

`docs/slop/plan.md` is the scope, the API, the order of work, and the decisions still to measure. Read it before starting.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit. `.agents/setup` installs Nix when an orb lacks it and warms the dev shell.

## Correctness

The WHATWG Encoding Standard is the specification, word for word: its decoders, encoders, error handling (replacement characters on decode, numeric character references or errors on encode), label table, and BOM sniffing. Where encoding_rs, ICU, or iconv disagree with the standard, the standard wins and the difference is documented.

Decoders read untrusted bytes: no input may crash, hang, read or write out of bounds, or produce invalid UTF-8 or UTF-16. No `@setRuntimeSafety(false)` in decoders or encoders. Every codec gets a fuzz target from its first commit.

## Performance

Speed and memory count equally. encoding_rs is the bar on every encoding and direction it shares with us, on throughput, per-call cost on short inputs, and the size of its tables in the binary. ICU, GNU libiconv, glibc's iconv, and Go's x/text are comparison arms; chardetng and uchardet are the bars for detection.

- SIMD with `@Vector` and `std.simd` for the ASCII runs every legacy encoding is mostly made of, as baskingspot/utf does.
- Tables are part of the memory bar: the CJK indexes are the bulk of the package's size. A faster table layout that costs binary size, or the reverse, is measured both ways.
- Measure on realistic inputs: real web pages, mail, subtitles, and CSV in each encoding, plus synthetic worst cases, at sizes from 16 bytes to megabytes. Short inputs matter.
- A change to a hot path comes with an interleaved A/B, pinned to one core (`taskset`), compared with benchstat, written up in `docs/slop/results/<topic>-<yyyymmdd>.md` with the raw output, throughput in GB/s and the CPU named.
- No allocation: callers pass output buffers, and functions say how big they must be.

## Tests

The standard's indexes and the web-platform-tests encoding tests are vendored unmodified, with checksums in `THIRD_PARTY.md`. Each codec is checked against the standard's algorithm on every index entry, against encoding_rs differentially on random and adversarial input (every byte sequence at every position, across SIMD block boundaries and buffer splits), and for streaming: any split of the input into chunks gives the same output as one call.

## Agent notes

Docs split by reader. `README.md`, `CHANGELOG.md`, and `THIRD_PARTY.md` are for a person deciding whether and how to use the package. Agent material goes in `docs/slop/`: design notes, plans, and measurements in `docs/slop/results/`. `docs/slop/plan.md` is the architecture, the decisions still to measure, and who owns which files; update it when a decision lands. `AGENTS.md` and code comments may link `docs/slop/`; no human document links or names it.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history. A change made for a measurement adds a short body that names its `docs/slop/results/` file and gives the headline number.
- Gate commands on their exit codes, and claim only what you ran.
- `just fmt` formats Zig, Nix, Markdown, and the justfile; `just lint` checks them and lints the workflows with actionlint and zizmor.
- Implement from the standard, not by translating encoding_rs's or anyone's source. Other libraries are oracles and benchmarks.
- This repo's GitHub settings come from `baskingspot/.github`: run `just settings --repo encoding` in a checkout of that repo. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
