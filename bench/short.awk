# The per-call cost on short inputs at the end of `just bench-compare`
# (bench/README.md): for each operation and input size up to 256 bytes, the
# median ns per call over every encoding and shape each arm timed, and this
# package's median ratio to encoding_rs over the rows both timed.
#
#     awk -f bench/short.awk DIR/raw-zig.txt DIR/raw-rust.txt DIR/raw-...
#
# Each file holds the arm's raw rows, `Benchmark<Op>/<encoding>/<shape>-<size>
# <n> <ns> ns/op <MB/s> MB/s`, one per round.

FNR == 1 {
    arm = FILENAME
    sub(/.*raw-/, "", arm)
    sub(/\.txt$/, "", arm)
    arms[++narms] = arm
}

/^Benchmark/ {
    n = split($1, p, "/")
    size = p[n]
    sub(/.*-/, "", size)
    if (size + 0 > 256) next
    op = p[1]
    sub(/^Benchmark/, "", op)
    key = op " " size
    if (!(key in seen)) {
        seen[key] = 1
        keys[++nkeys] = key
    }
    row = $1
    k = arm SUBSEP row
    v[k, ++c[k]] = $3
    if (!((key, row) in has)) {
        has[key, row] = 1
        rows[key, ++nrows[key]] = row
    }
}

function sort(a, m,    i, j, t) {
    for (i = 2; i <= m; i++) {
        t = a[i]
        for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
        a[j + 1] = t
    }
}

function median(a, m) {
    sort(a, m)
    return m % 2 ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}

function rowmedian(k,    i, a) {
    for (i = 1; i <= c[k]; i++) a[i] = v[k, i] + 0
    return median(a, c[k])
}

END {
    printf "%-20s %5s", "ns/call, median", "bytes"
    for (a = 1; a <= narms; a++) printf " %9s", arms[a]
    printf " %9s\n", arms[1] "/" arms[2]
    for (i = 1; i <= nkeys; i++) {
        split(keys[i], kk, " ")
        printf "%-20s %5d", kk[1], kk[2]
        delete q; nq = 0
        for (a = 1; a <= narms; a++) {
            delete m; nm = 0
            for (r = 1; r <= nrows[keys[i]]; r++) {
                k = arms[a] SUBSEP rows[keys[i], r]
                if (k in c) m[++nm] = rowmedian(k)
            }
            printf " %9s", nm ? sprintf("%.1f", median(m, nm)) : "-"
        }
        # Per row, rust's ns over zig's: above 1, this package is faster.
        for (r = 1; r <= nrows[keys[i]]; r++) {
            ka = arms[1] SUBSEP rows[keys[i], r]
            kb = arms[2] SUBSEP rows[keys[i], r]
            if ((ka in c) && (kb in c)) q[++nq] = rowmedian(kb) / rowmedian(ka)
        }
        printf " %9s\n", nq ? sprintf("%.2f", median(q, nq)) : "-"
    }
}
