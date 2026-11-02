# Third-party material

What this repository includes from elsewhere, where it came from, and under
what terms. Everything under `vendor/` is unmodified; each directory has a
`SHA256SUMS` of its files, and `just check` verifies them.

## vendor/whatwg-encoding

The Encoding Standard's indexes (`index-*.txt`) and its label table
(`encodings.json`), from [whatwg/encoding](https://github.com/whatwg/encoding)
at commit `be17ac5c49881336538acfc7b40dba3c8009144b` (2026-10-19). The
generator (`gen/`) turns them into the tables under `src/tables/`, and the
tests check those tables against them in full.

License: Creative Commons Attribution 4.0 International, with portions
incorporated into source code (the indexes, as the generated tables) under
the BSD 3-Clause License, `vendor/whatwg-encoding/LICENSE`. Copyright WHATWG
(Apple, Google, Mozilla, Microsoft).

`SHA256SUMS`: `fe46e241df7c8f2a1daeed1604dd33b54859dd559fd659f28150cf368088ea8e`

## vendor/wpt

The web-platform-tests encoding tests (`encoding/`) and the files they load
(`resources/testharness.js`, `common/subset-tests.js`, `common/sab.js`), from
[web-platform-tests/wpt](https://github.com/web-platform-tests/wpt) at commit
`4e3292cf4dbfd512ec6104a9d3644eecb886a010` (2026-11-02). `just wpt` runs them
against the package built as WebAssembly.

License: 3-Clause BSD, `vendor/wpt/LICENSE.md`. Copyright web-platform-tests
contributors.

`SHA256SUMS`: `ee860b7640134c2cdc75f93947ceb9613c7584e1ec823fc1734e384964bc0b5b`

## vendor/unicode

Unicode's mappings of IBM code pages 437 and 850 (`CP437.TXT`,
`CP850.TXT`, Microsoft's tables of 1996), from
`https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/`, fetched
2026-11-02, for the IBM437 and IBM850 tables, which the Encoding Standard
does not define.

License: Unicode License v3, `vendor/unicode/LICENSE`. Copyright Unicode,
Inc.

`SHA256SUMS`: `967904da878a0d156346e8adc335e5217ab7faaf1920f568b63f05022595a16b`

## Not included, fetched by the developer tools

- `just bench-corpus` fetches one Wikipedia article per language at a
  fixed revision (`bench/corpus/sources.tsv`), under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) by the
  articles' contributors, and generates the benchmark inputs from them into
  the gitignored `bench/corpus-gen/`. `bench/corpus/SHA256SUMS` pins the
  fetched and generated files.
- The test and benchmark programs depend on encoding_rs (MIT or Apache-2.0)
  and unicode-normalization (MIT or Apache-2.0) through Cargo, on
  golang.org/x/text (BSD 3-Clause) through Go modules, and on ICU, glibc's
  iconv, and GNU libiconv from the Nix dev shell. None of them is part of
  the package.
