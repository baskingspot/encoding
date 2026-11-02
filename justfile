# encoding: Legacy text encodings in Zig with no C: the WHATWG Encoding Standard's Shift_JIS, GBK, Big5, EUC-KR, windows-125x, and the rest. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md docs/slop bench/README.md .github"
zig_dirs := "src gen test bench/zig build.zig build.zig.zon bench/build.zig bench/build.zig.zon"

[private]
default:
    @just --list

[doc("Unit tests, the table checks against the vendored indexes, and the streaming checks, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("The tests on big-endian s390x under qemu")]
[group("test")]
test-big-endian:
    zig build test -Dtarget=s390x-linux-musl -fqemu -Doptimize=ReleaseSafe --summary all

[doc("Generate every multi-byte index in every table layout into the cache, and check each against its index in full")]
[group("test")]
test-layouts:
    zig build test-layouts -Doptimize=ReleaseSafe --summary all

[doc("The committed tables are what `just gen` writes, and vendor/ matches its checksums")]
[group("test")]
check:
    zig build gen-check
    cd vendor/whatwg-encoding && sha256sum --quiet --check SHA256SUMS
    cd vendor/wpt && sha256sum --quiet --check SHA256SUMS
    cd vendor/unicode && sha256sum --quiet --check SHA256SUMS

[doc("Write the tables under src/tables/ from vendor/ (gen/sources.zig lists them)")]
[group("test")]
gen:
    zig build gen

[doc("Lint Zig, Rust, Go, Nix, Markdown, the workflows, and this justfile")]
[group("lint")]
lint:
    ziglint
    zig fmt --check {{ zig_dirs }} test/oracle/compare.zig
    cargo fmt --check --manifest-path test/oracle/rs/Cargo.toml
    cargo fmt --check --manifest-path bench/rust/Cargo.toml
    test -z "$(gofmt -l bench/go)"
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt {{ zig_dirs }}
    cargo fmt --manifest-path test/oracle/rs/Cargo.toml
    cargo fmt --manifest-path bench/rust/Cargo.toml
    gofmt -w bench/go
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

# The build mode of the fuzz recipes: ReleaseSafe, so safety checks fire, or
# Debug for its slower, stricter checks.
fuzz_mode := "ReleaseSafe"

[doc("Fuzz for SECONDS (default 600) every implemented codec, or TARGET (decode, encode, or all) on ENCODING (a label, or all): no crash, well-formed output, and the same output for any split and buffer. Findings go to zig-out/fuzz/findings/ and fail the recipe")]
[group("fuzz")]
fuzz SECONDS="600" TARGET="all" ENCODING="all" *ARGS:
    zig build fuzz -Doptimize={{ fuzz_mode }}
    zig-out/bin/fuzz run --seconds {{ SECONDS }} --target {{ TARGET }} --encoding {{ ENCODING }} {{ ARGS }}

[doc("The bounded fuzz run CI does: 60 seconds over every codec")]
[group("fuzz")]
fuzz-ci: (fuzz "60")

[doc("Build the encoding_rs oracle, test/oracle/rs, with the dev shell's cargo")]
[group("oracle")]
oracle-build:
    cargo build --quiet --release --locked --manifest-path test/oracle/rs/Cargo.toml

[doc("Compare every implemented codec and the label table with encoding_rs: N random inputs per codec (default 2000) plus the exhaustive sets (test/oracle/compare.zig)")]
[group("oracle")]
oracle N="2000" SEED="1": oracle-build
    zig build oracle -Doptimize=ReleaseSafe
    zig-out/bin/oracle-compare test/oracle/rs/target/release/encoding-oracle --random {{ N }} --seed {{ SEED }}

[doc("Run the web-platform-tests encoding tests under Node against the package built as WebAssembly; fails on a test that does not match test/wpt/expectations.txt")]
[group("test")]
wpt *ARGS:
    zig build wpt-wasm
    node test/wpt/run.mjs {{ ARGS }}

# The arms `just bench-compare` times, encoding_rs (rust) first: every
# other arm is checked against it. Override with `just arms="rust zig"
# bench-compare`.
arms := "rust zig icu iconv libiconv go"

[doc("Fetch the corpus sources into bench/corpus-gen/sources/, generate every encoding's inputs, and verify all of it against bench/corpus/SHA256SUMS")]
[group("bench")]
bench-corpus:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bench/corpus-gen/sources
    grep -v '^#' bench/corpus/sources.tsv | while IFS=$'\t' read -r name url; do
        [ -f "bench/corpus-gen/sources/$name" ] && continue
        curl -sSfL -A 'baskingspot-encoding-corpus/1 (https://github.com/baskingspot/encoding)' \
            -o "bench/corpus-gen/sources/$name" "$url"
        sleep 1
    done
    cargo build --quiet --release --locked --manifest-path bench/rust/Cargo.toml
    bench/rust/target/release/bench-corpus
    cd bench/corpus-gen && sha256sum --quiet --strict --check ../corpus/SHA256SUMS

[doc("Rewrite bench/corpus/SHA256SUMS from bench/corpus-gen/ (the sources and every encoding's inputs; the .utf8 files are their decodes), after a deliberate change to the corpus")]
[group("bench")]
bench-corpus-sums:
    cd bench/corpus-gen && { find sources -type f; find . -name '*.bin' | cut -c3-; } | LC_ALL=C sort | xargs sha256sum > ../corpus/SHA256SUMS

# Every arm, into zig-out/bin/bench-<arm>.
[private]
bench-build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p zig-out/bin
    (cd bench && zig build -p ../zig-out)
    cargo build --quiet --release --locked --manifest-path bench/rust/Cargo.toml
    cp bench/rust/target/release/bench-rust zig-out/bin/
    cc -O2 -std=c11 -Wall -Wextra -Werror -DARM_ICU -o zig-out/bin/bench-icu bench/c/arm.c $(pkg-config --cflags --libs icu-uc)
    cc -O2 -std=c11 -Wall -Wextra -Werror -DARM_ICONV -o zig-out/bin/bench-iconv bench/c/arm.c
    cc -O2 -std=c11 -Wall -Wextra -Werror -DARM_LIBICONV -o zig-out/bin/bench-libiconv bench/c/arm.c -liconv
    go build -C bench/go -o ../../zig-out/bin/bench-go .

[doc("Compare with encoding_rs, ICU, glibc iconv, GNU libiconv, and Go's x/text on this machine: checksums against encoding_rs, peak RSS, then rounds on one core that time the arms on each row back to back, benchstat, a summary per operation and encoding, and the per-call cost on short inputs. FILTER, extended regular expressions, picks rows by name (Op/encoding/shape-size); the default is every row this package has. The numbers are not claims")]
[group("bench")]
[positional-arguments]
bench-compare ROUNDS="10" *FILTER: bench-corpus bench-build
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out"
    arms=({{ arms }})
    export BENCHTIME_MS="${BENCHTIME_MS:-50}"
    for arm in "${arms[@]}"; do
        zig-out/bin/bench-$arm check > "$out/check-$arm.txt" 2> "$out/stderr-$arm.txt" ||
            { cat "$out/stderr-$arm.txt"; exit 1; }
    done
    {
        echo "zig: ReleaseFast, native, $(git describe --always --dirty)"
        echo "rust: encoding_rs $(grep -A1 'name = "encoding_rs"' bench/rust/Cargo.lock | sed -n 's/version = //p' | tr -d '"'); icu $(pkg-config --modversion icu-uc); go: x/text $(awk '/golang.org\/x\/text/ { print $NF }' bench/go/go.mod)"
        echo "buffers: input ${BENCH_IN_OFFSET:-0} bytes past a page, output ${BENCH_OUT_OFFSET:-2048}; ${BENCHTIME_MS} ms a sample, {{ ROUNDS }} rounds"
        lscpu | grep -E '^(Model name|CPU\(s\))' || true
    } | tee "$out/config.txt"
    # The reference checksum of a row is encoding_rs's, or this package's
    # where encoding_rs lacks the encoding. This package must match it; any
    # other arm's row that does not is left out, and counted.
    awk -F'\t' '!/^#/ { print }' "$out/check-rust.txt" | sort > "$out/ref.txt"
    join -t $'\t' -v 2 "$out/ref.txt" <(grep -v '^#' "$out/check-zig.txt" | sort) >> "$out/ref.txt"
    sort -o "$out/ref.txt" "$out/ref.txt"
    join -t $'\t' "$out/ref.txt" <(grep -v '^#' "$out/check-zig.txt" | sort) | awk -F'\t' '$2 != $3' > "$out/check-diff-zig.txt"
    if [ -s "$out/check-diff-zig.txt" ]; then
        echo "this package's output differs from encoding_rs's (row, encoding_rs, zig):"
        cat "$out/check-diff-zig.txt"
        exit 1
    fi
    filter=("${@:2}")
    pattern=$(IFS='|'; echo "${filter[*]:-.}")
    grep -v '^#' "$out/check-zig.txt" | cut -f1 | grep -E "$pattern" > "$out/rows.list" || true
    [ -s "$out/rows.list" ] || { echo "no rows match $pattern"; exit 1; }
    declare -A has
    : > "$out/checks.txt"
    for arm in "${arms[@]}"; do
        join -t $'\t' "$out/ref.txt" <(grep -v '^#' "$out/check-$arm.txt" | sort) |
            awk -F'\t' -v m="$out/match-$arm.txt" -v d="$out/check-diff-$arm.txt" '$2 == $3 { print $1 > m; next } { print > d }'
        touch "$out/match-$arm.txt" "$out/check-diff-$arm.txt"
        while read -r row; do has[$arm/$row]=1; done < "$out/match-$arm.txt"
        printf '%-9s %5d rows match the reference, %4d differ (%s), %d skipped\n' "$arm" \
            "$(wc -l < "$out/match-$arm.txt")" "$(wc -l < "$out/check-diff-$arm.txt")" "$out/check-diff-$arm.txt" \
            "$(grep -c '^# SKIP' "$out/check-$arm.txt" || true)" >> "$out/checks.txt"
    done
    cat "$out/checks.txt"
    echo
    # Peak RSS of one pass over every encoding's inputs per operation: the
    # inputs and output buffers, which every arm holds alike, plus the arm.
    {
        printf '%-14s' "peak RSS (MiB)"; printf '%9s' "${arms[@]}"; echo
        for op in decode-utf8 decode-utf16 encode-utf8 encode-utf16; do
            printf '%-14s' "$op"
            for arm in "${arms[@]}"; do
                command time -f %M -o "$out/rss-run.txt" zig-out/bin/bench-$arm check "$op" > "$out/rss-check.txt" 2> /dev/null
                if ! grep -qv '^#' "$out/rss-check.txt"; then printf '%9s' -; continue; fi
                awk '{ printf "%9.1f", $1 / 1024 }' "$out/rss-run.txt"
            done
            echo
        done
    } | tee "$out/rss.txt"
    echo
    # The rounds, as in baskingspot/utf's harness: each arm a server pinned
    # to the last core, each row timed by every arm that has it back to
    # back in an order that rotates from row to row and round to round, so
    # the arms' samples of a row see the same machine. Round 0 sizes each
    # row's loop to BENCHTIME_MS and is not counted.
    core=$(( $(nproc) - 1 ))
    taskset -cp 0 $$ > /dev/null
    declare -A iters to from
    mapfile -t rows < "$out/rows.list"
    fifos=$(mktemp -d)
    trap 'rm -rf "$fifos"' EXIT
    start() {
        for arm in "${arms[@]}"; do
            mkfifo "$fifos/$arm.in" "$fifos/$arm.out"
            taskset -c "$core" zig-out/bin/bench-$arm serve < "$fifos/$arm.in" > "$fifos/$arm.out" 2>> "$out/stderr-$arm.txt" &
            exec {fd}> "$fifos/$arm.in"
            to[$arm]=$fd
            exec {fd}< "$fifos/$arm.out"
            from[$arm]=$fd
        done
    }
    stop() {
        for arm in "${arms[@]}"; do eval "exec ${to[$arm]}>&-"; done
        wait
        for arm in "${arms[@]}"; do eval "exec ${from[$arm]}<&-"; done
        rm -f "$fifos"/*
    }
    declare -A arg_of=([DecodeUtf8]=decode-utf8 [DecodeUtf16]=decode-utf16 [EncodeUtf8]=encode-utf8 [EncodeUtf16]=encode-utf16)
    # One row on one arm, N iterations (0: BENCHTIME_MS), into $line.
    sample() {
        local rest=${2#*/}
        printf '%s %s %s %s\n' "${arg_of[${2%%/*}]}" "${rest%/*}" "${rest##*/}" "$3" >&"${to[$1]}"
        if ! IFS= read -r line <&"${from[$1]}" || [[ $line != Benchmark* ]]; then
            echo "bench-$1 failed on $2: $line"
            cat "$out/stderr-$1.txt"
            exit 1
        fi
    }
    for round in $(seq 0 {{ ROUNDS }}); do
        start
        j=0
        for row in "${rows[@]}"; do
            present=()
            for arm in "${arms[@]}"; do [ -n "${has[$arm/$row]:-}" ] && present+=("$arm"); done
            for i in "${!present[@]}"; do
                arm=${present[$(( (round + j + i) % ${#present[@]} ))]}
                if [ "$round" = 0 ]; then
                    sample "$arm" "$row" 0
                    IFS=$'\t' read -r _ n _ <<< "$line"
                    iters[$arm/$row]=$n
                else
                    sample "$arm" "$row" "${iters[$arm/$row]}"
                    echo "$line" >> "$out/raw-$arm.txt"
                fi
            done
            j=$(( j + 1 ))
        done
        stop
        echo "round $round of {{ ROUNDS }} done at $(date +%T)"
    done
    files=()
    for arm in "${arms[@]}"; do
        [ -s "$out/raw-$arm.txt" ] || continue
        awk '/^Benchmark/ { for (i = 3; i < NF; i += 2) if ($(i + 1) == "MB/s") printf "%s\t%s\t%.4f GB/s\n", $1, $2, $i / 1000 }' \
            "$out/raw-$arm.txt" > "$out/$arm.txt"
        files+=("$arm=$out/$arm.txt")
    done
    benchstat "${files[@]}" > "$out/benchstat.txt"
    echo "benchstat: $out/benchstat.txt"
    echo
    just bench-summary "$out" | tee "$out/summary.txt"

[doc("Summarize a bench-compare run in DIR: per operation and encoding, this package's geomean throughput against each arm's, every row's ratio with its interval into DIR/rows.txt, and the per-call cost on inputs up to 256 bytes")]
[group("bench")]
bench-summary DIR="zig-out/bench-compare":
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    raws=()
    for arm in zig rust icu iconv libiconv go; do
        [ -s "{{ DIR }}/$arm.txt" ] && files+=("{{ DIR }}/$arm.txt") && raws+=("{{ DIR }}/raw-$arm.txt")
    done
    : > "{{ DIR }}/rows.txt"
    awk -v rows="{{ DIR }}/rows.txt" -f bench/summary.awk "${files[@]}"
    echo
    awk -f bench/short.awk "${raws[@]}"

[doc("The bytes this package's generated tables take in its arm binary and in encoding_rs's (which shares only the single-byte layout), encoding_rs's own data tables by symbol, and each binary's .rodata")]
[group("bench")]
bench-rodata: bench-build
    zig build rodata -- zig-out/bin/bench-zig zig-out/bin/bench-rust
    nm -S -C zig-out/bin/bench-rust | awk '$3 == "r" && $4 ~ /^encoding_rs::data::/ { n += strtonum("0x" $2) } END { print "zig-out/bin/bench-rust: encoding_rs::data, " n " bytes" }'
    size -A zig-out/bin/bench-zig zig-out/bin/bench-rust | grep -E '^(zig-out|\.rodata|\.text) '

[doc("Everything CI runs")]
[group("ci")]
ci: test check test-layouts lint fuzz-ci oracle wpt test-big-endian
