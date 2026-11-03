/* The uchardet arm of the detection scoring harness (test/detect/README.md),
 * run from the repository root:
 *
 *     detect-uchardet guess SAMPLES   one line per sample: uchardet's guess
 *                                     for each of its cuts
 *     detect-uchardet bench SAMPLES   the whole articles' bytes per second,
 *                                     then the time per call on the 32-byte
 *                                     windows, each over at least BENCH_MS
 *
 * Each guess is a fresh detector fed the bytes up to the cut and ended; an
 * empty answer (uchardet found nothing) is written as "unknown". */

#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <uchardet.h>

struct sample {
    char kind;
    size_t length;
    size_t ncuts;
    size_t *cuts;
    unsigned char *bytes;
};

static void fail(const char *message) {
    fprintf(stderr, "detect-uchardet: %s\n", message);
    exit(1);
}

static struct sample *read_samples(const char *path, size_t *count) {
    FILE *f = fopen(path, "rb");
    if (!f) fail("cannot open the samples");
    size_t cap = 1024, n = 0;
    struct sample *s = malloc(cap * sizeof *s);
    char line[8192];
    while (fgets(line, sizeof line, f)) {
        if (n == cap) s = realloc(s, (cap *= 2) * sizeof *s);
        char kind, lang[64], enc[64];
        size_t length, ncuts;
        int used;
        if (sscanf(line, "%c %63s %63s %zu %zu%n", &kind, lang, enc, &length, &ncuts, &used) != 5)
            fail("bad sample header");
        s[n].kind = kind;
        s[n].length = length;
        s[n].ncuts = ncuts;
        s[n].cuts = malloc(ncuts * sizeof(size_t));
        char *p = line + used;
        for (size_t i = 0; i < ncuts; i++) s[n].cuts[i] = strtoull(p, &p, 10);
        size_t len = s[n].cuts[ncuts - 1];
        s[n].bytes = malloc(len + 1);
        if (fread(s[n].bytes, 1, len + 1, f) != len + 1) fail("short sample");
        n++;
    }
    fclose(f);
    *count = n;
    return s;
}

static const char *guess(uchardet_t u, const unsigned char *bytes, size_t len) {
    uchardet_reset(u);
    uchardet_handle_data(u, (const char *)bytes, len);
    uchardet_data_end(u);
    const char *name = uchardet_get_charset(u);
    return name[0] ? name : "unknown";
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 3) fail("usage: detect-uchardet guess|bench SAMPLES");
    size_t n;
    struct sample *s = read_samples(argv[2], &n);
    uchardet_t u = uchardet_new();
    if (strcmp(argv[1], "guess") == 0) {
        for (size_t i = 0; i < n; i++) {
            for (size_t k = 0; k < s[i].ncuts; k++)
                printf(k ? " %s" : "%s", guess(u, s[i].bytes, s[i].cuts[k]));
            putchar('\n');
        }
    } else if (strcmp(argv[1], "bench") == 0) {
        const char *env = getenv("BENCH_MS");
        double secs = (env ? atof(env) : 2000) / 1000;
        size_t total = 0, sink = 0;
        for (size_t i = 0; i < n; i++)
            if (s[i].kind == 'd') total += s[i].cuts[s[i].ncuts - 1];
        unsigned long rounds = 0;
        double start = now();
        while (rounds == 0 || now() - start < secs) {
            for (size_t i = 0; i < n; i++)
                if (s[i].kind == 'd') sink ^= strlen(guess(u, s[i].bytes, s[i].cuts[s[i].ncuts - 1]));
            rounds++;
        }
        double t = now() - start;
        printf("uchardet\t%zu bytes x %lu\t%.1f MB/s\t(sink %zu)\n", total, rounds, total * (double)rounds / t / 1e6, sink);
        /* The cost of a call on short input: the detector reset for each
         * 32-byte window. */
        unsigned long calls = 0;
        start = now();
        while (calls == 0 || now() - start < secs) {
            for (size_t i = 0; i < n; i++) {
                if (s[i].kind == 'w' && s[i].length == 32) {
                    sink ^= strlen(guess(u, s[i].bytes, s[i].cuts[0]));
                    calls++;
                }
            }
        }
        printf("uchardet\t32-byte windows x %lu\t%.0f ns per call\t(sink %zu)\n", calls, (now() - start) * 1e9 / calls, sink);
    } else {
        fail("usage: detect-uchardet guess|bench SAMPLES");
    }
    uchardet_delete(u);
    return 0;
}
