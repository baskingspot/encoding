# Detection: corpus, trainer, and scoring

How `src/detect.zig`'s models are trained and how the detector is scored
against chardetng and uchardet.

## Corpus

`gen/detect/sources.tsv` pins 60 Wikipedia articles, by revision, for each
of 56 languages (Chinese counted twice, as simplified and traditional
script). `just detect-select` picked them once, at random among articles
of 6000 bytes or more; it is random by design and its output is what is
committed. `just detect-corpus` fetches the revisions into
`zig-out/detect/wiki/`, checks them against `gen/detect/SHA256SUMS`, and
runs `detect-corpus build` (`rs/src/bin/detect-corpus.rs`), which is
deterministic:

- The wikitext is reduced to prose, the same reduction `bench/corpus`
  uses.
- Of each language's articles, the first two of every three are training
  text, written to `zig-out/detect/train/LANG.txt` as UTF-8 limited to what
  the language's group's first encoding can write.
- The third is test text, encoded with encoding_rs into every encoding of
  its group (`gen/detect/groups.tsv`) and written to
  `zig-out/detect/samples.txt`: five windows per article at each of 16, 32,
  64, 128, 256, 1024, and 4096 bytes, starting at random characters and
  holding at least one byte outside ASCII, and the whole article (up to 96
  KB of prose), cut at 16, 24, 32, 48, 64, 96, ... bytes for the bytes
  needed.

Each sample is a header line, `KIND LANG ENCODING LENGTH NCUTS CUT...`,
then its bytes and a newline. Training and test text never share an
article.

## Trainer

`gen/detect/train.zig` (`zig build detect-train`) reads the training text
and the standard's indexes and writes `src/detect/tables.zig`; `just
detect-gen` runs it and `just detect-check` fails if the committed tables
differ from what it writes. Its header describes the models. `detect-train
variant NAME OUT` writes one of the model variants the detector was
chosen from; `just detect-variants` scores them all.

## Scoring

`just detect-score` builds three arms and runs each on the test samples:

- `score.zig`: this package, with the committed tables or, built with
  `-Ddetect-tables=FILE`, a variant's.
- `rs/src/bin/detect-chardetng.rs`: chardetng 0.1.17, Firefox's detector.
- `uchardet.c`: uchardet from the dev shell.

Each arm guesses every cut of every sample with a fresh detector, with no
top-level domain and UTF-8 allowed. `detect-score report` then counts a
guess right when it decodes the sample's bytes to the same text as the
sample's own encoding, so windows-1250 is right for Polish in ISO-8859-2
when the two agree on every byte present. It prints accuracy by encoding
and size, the bytes each encoding's articles need (the shortest cut from
which every longer cut is guessed right), and accuracy by language. Last,
each arm's speed on the whole articles, pinned to one core.
