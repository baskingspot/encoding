// The C arms of `just bench-compare` (bench/README.md), one program built
// three ways: `bench-icu` (-DARM_ICU) times ICU's converters,
// `bench-iconv` (-DARM_ICONV) glibc's iconv, and `bench-libiconv`
// (-DARM_LIBICONV) GNU libiconv, which has the same API under other names.
//
// Usage, from the repository root, with the same contract as every arm:
//
//     bench-<arm> check [OP...]   one checksum line per row
//     bench-<arm> serve           one row per request line on stdin
//
// OP is decode-utf8, decode-utf16, encode-utf8, or encode-utf16; none means
// all, over every encoding in bench/encodings.tsv. A `serve` request is
// `OP ENCODING INPUT N`: time the row N iterations after one untimed call,
// or for BENCHTIME_MS (default 100) when N is 0, sized the way Go's
// `testing.B` sizes a loop. Every input starts BENCH_IN_OFFSET bytes
// (default 0) past a page boundary and its output BENCH_OUT_OFFSET bytes
// (default 2048) past another, as in every arm.
//
// A converter is opened once per row, as a program converting many
// strings would keep one, and reset before each call. Errors are replaced
// as the standard's modes do: U+FFFD for bytes that do not decode, and a
// decimal numeric character reference for a character the encoding lacks
// (ICU's UCNV_ESCAPE_XML_DEC callback; iconv's arm writes one after each
// EILSEQ). The libraries' tables are not the standard's, so a row whose
// checksum differs from encoding_rs's is dropped for that arm and listed.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

#if defined(ARM_ICU)
#include <unicode/ucnv.h>
#define ARM "icu"
#elif defined(ARM_ICONV) || defined(ARM_LIBICONV)
// Declared here rather than from <iconv.h>, which in the dev shell is
// libiconv's and renames the functions.
typedef void *iconv_t;
#if defined(ARM_LIBICONV)
#define ARM "libiconv"
#define iconv_open libiconv_open
#define iconv libiconv
#define iconv_close libiconv_close
#else
#define ARM "iconv"
#endif
iconv_t iconv_open(const char *to, const char *from);
size_t iconv(iconv_t cd, char **in, size_t *inleft, char **out, size_t *outleft);
int iconv_close(iconv_t cd);
#else
#error "define ARM_ICU, ARM_ICONV, or ARM_LIBICONV"
#endif

static const char *corpus = "bench/corpus-gen";

static _Noreturn void fail(const char *fmt, const char *arg) {
    fprintf(stderr, "bench-" ARM ": ");
    fprintf(stderr, fmt, arg);
    fputc('\n', stderr);
    exit(1);
}

// `len` bytes `off` bytes past a page boundary, in an anonymous mapping of
// their own: zeroed, and resident only once written.
typedef struct {
    uint8_t *base;
    size_t size, off, len;
} Placed;

static Placed placed(size_t len, size_t off) {
    Placed p = {0};
    p.size = (off + len + 4096) / 4096 * 4096;
    p.base = mmap(NULL, p.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p.base == MAP_FAILED) fail("%s", "out of memory");
    p.off = off;
    p.len = len;
    return p;
}

static uint8_t *bytes(Placed p) { return p.base + p.off; }
static void unplace(Placed p) { munmap(p.base, p.size); }

static size_t in_offset = 0, out_offset = 2048;

static size_t offset_env(const char *name, size_t def) {
    const char *v = getenv(name);
    if (!v) return def;
    size_t off = strtoul(v, NULL, 10);
    if (off >= 4096 || off % 4) fail("%s must be a multiple of 4 under 4096", name);
    return off;
}

// Copies `data` into a placed buffer and writes every other page of its
// mapping: a masked load whose masked-off lanes reach a page nothing has
// touched takes a microcode assist on every call.
static Placed place(const uint8_t *data, size_t len) {
    Placed p = placed(len, in_offset);
    memset(p.base, 1, p.off);
    memcpy(bytes(p), data, len);
    memset(bytes(p) + len, 1, p.size - p.off - len);
    return p;
}

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) fail("open %s (run `just bench-corpus`)", path);
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(*len + 1);
    if (*len && fread(buf, 1, *len, f) != *len) fail("read %s", path);
    fclose(f);
    return buf;
}

// Valid UTF-8 to native UTF-16; returns the code units written.
static size_t utf8_to_utf16(const uint8_t *s, size_t n, uint16_t *out) {
    size_t i = 0, o = 0;
    while (i < n) {
        uint32_t c = s[i];
        size_t k = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        if (k > 1) c &= 0x3F >> (k - 1);
        for (size_t j = 1; j < k; j++) c = c << 6 | (s[i + j] & 0x3F);
        i += k;
        if (c >= 0x10000) {
            out[o++] = (uint16_t)(0xD800 + ((c - 0x10000) >> 10));
            out[o++] = (uint16_t)(0xDC00 + (c & 0x3FF));
        } else {
            out[o++] = (uint16_t)c;
        }
    }
    return o;
}

// One input: its bytes in the encoding, its text in UTF-8, and the same
// text in UTF-16.
typedef struct {
    char name[64];
    Placed forms[3];
} Input;

static Placed input_of(const Input *in, int op) { return in->forms[op < 2 ? 0 : op == 2 ? 1 : 2]; }

static int by_size(const void *a, const void *b) {
    const Input *x = a, *y = b;
    if (x->forms[0].len != y->forms[0].len) return x->forms[0].len < y->forms[0].len ? -1 : 1;
    return strcmp(x->name, y->name);
}

// Every input of an encoding, smallest first, then by name.
static Input *load(const char *enc, size_t *count) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", corpus, enc);
    DIR *d = opendir(path);
    if (!d) fail("open %s (run `just bench-corpus`)", path);
    size_t cap = 64, n = 0;
    Input *list = malloc(cap * sizeof *list);
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".bin")) continue;
        if (n == cap) list = realloc(list, (cap *= 2) * sizeof *list);
        Input *in = &list[n++];
        snprintf(in->name, sizeof in->name, "%.*s", (int)(len - 4), e->d_name);
        size_t blen, ulen;
        snprintf(path, sizeof path, "%s/%s/%s.bin", corpus, enc, in->name);
        uint8_t *bin = read_file(path, &blen);
        snprintf(path, sizeof path, "%s/%s/%s.utf8", corpus, enc, in->name);
        uint8_t *utf8 = read_file(path, &ulen);
        uint16_t *units = malloc(2 * ulen + 2);
        size_t nunits = utf8_to_utf16(utf8, ulen, units);
        in->forms[0] = place(bin, blen);
        in->forms[1] = place(utf8, ulen);
        in->forms[2] = place((uint8_t *)units, 2 * nunits);
        free(bin);
        free(utf8);
        free(units);
    }
    closedir(d);
    qsort(list, n, sizeof *list, by_size);
    *count = n;
    return list;
}

static void unload(Input *list, size_t n) {
    for (size_t i = 0; i < n; i++)
        for (int f = 0; f < 3; f++) unplace(list[i].forms[f]);
    free(list);
}

static const struct {
    const char *arg, *row;
    size_t out;
} ops[4] = {
    {"decode-utf8", "DecodeUtf8", 3},
    {"decode-utf16", "DecodeUtf16", 2},
    {"encode-utf8", "EncodeUtf8", 4},
    {"encode-utf16", "EncodeUtf16", 4},
};

// The library's names for an encoding, tried in order, from the standard's
// name; NULL where the library has none worth timing.
static const char *const *names(const char *enc) {
    static const struct {
        const char *enc;
        const char *names[4];
    } table[] = {
#if defined(ARM_ICU)
        {"Shift_JIS", {"windows-31j"}},
        {"EUC-KR", {"windows-949"}},
        {"GBK", {"windows-936"}},
        {"Big5", {"Big5-HKSCS"}},
        {"ISO-8859-8-I", {"ISO-8859-8"}},
        {"IBM437", {"ibm-437"}},
        {"IBM850", {"ibm-850"}},
        {"x-user-defined", {NULL}},
#else
        {"Shift_JIS", {"CP932", "WINDOWS-31J", "SHIFT_JIS"}},
        {"EUC-KR", {"CP949", "EUC-KR"}},
        {"Big5", {"BIG5-HKSCS", "BIG5HKSCS", "BIG5"}},
        {"ISO-8859-8-I", {"ISO-8859-8"}},
        {"IBM437", {"CP437", "IBM437"}},
        {"IBM850", {"CP850", "IBM850"}},
        {"IBM866", {"CP866", "IBM866"}},
        {"windows-874", {"CP874", "WINDOWS-874"}},
        {"macintosh", {"MACINTOSH", "MAC"}},
        {"x-mac-cyrillic", {"MAC-CYRILLIC", "MACCYRILLIC"}},
        {"x-user-defined", {NULL}},
#endif
    };
    static const char *own[2];
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
        if (!strcmp(table[i].enc, enc)) return table[i].names;
    own[0] = enc;
    return own;
}

// An open converter for one encoding and direction.
typedef struct {
#if defined(ARM_ICU)
    UConverter *cnv;
#else
    iconv_t cd;
#endif
    int op;
} Coder;

static int is_utf16(const char *enc) { return !strcmp(enc, "UTF-16LE") || !strcmp(enc, "UTF-16BE"); }

// Opens `enc` for `op`, or returns 0 and why not.
static int coder_open(Coder *c, const char *enc, int op, const char **why) {
    c->op = op;
    if (op >= 2 && is_utf16(enc)) {
        *why = "the standard has no encoder for it";
        return 0;
    }
    *why = "the library has no such encoding";
    for (const char *const *n = names(enc); *n; n++) {
#if defined(ARM_ICU)
        UErrorCode err = U_ZERO_ERROR;
        c->cnv = ucnv_open(*n, &err);
        if (U_FAILURE(err)) continue;
        if (op >= 2) {
            ucnv_setFromUCallBack(c->cnv, UCNV_FROM_U_CALLBACK_ESCAPE, UCNV_ESCAPE_XML_DEC, NULL, NULL, &err);
        }
        return 1;
#else
        const char *unicode = op == 0 || op == 2 ? "UTF-8" : "UTF-16LE";
        c->cd = op < 2 ? iconv_open(unicode, *n) : iconv_open(*n, unicode);
        if (c->cd != (iconv_t)-1) return 1;
#endif
    }
    return 0;
}

static void coder_close(Coder *c) {
#if defined(ARM_ICU)
    ucnv_close(c->cnv);
#else
    iconv_close(c->cd);
#endif
}

#if !defined(ARM_ICU)
// Writes `s` at *out if it fits.
static void put(char **out, size_t *left, const char *s, size_t n) {
    if (n > *left) return;
    memcpy(*out, s, n);
    *out += n;
    *left -= n;
}

// The character at the start of UTF-8 or UTF-16 input, and its length.
static uint32_t next_char(int utf16, const char *in, size_t left, size_t *len) {
    const uint8_t *s = (const uint8_t *)in;
    if (utf16) {
        uint32_t u = s[0] | s[1] << 8;
        if (u >= 0xD800 && u < 0xDC00 && left >= 4) {
            *len = 4;
            return 0x10000 + ((u - 0xD800) << 10) + ((s[2] | s[3] << 8) - 0xDC00);
        }
        *len = 2;
        return u;
    }
    uint32_t c = s[0];
    size_t k = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
    if (k > 1) c &= 0x3F >> (k - 1);
    for (size_t j = 1; j < k; j++) c = c << 6 | (s[j] & 0x3F);
    *len = k;
    return c;
}
#endif

// Converts the whole input; returns the bytes written.
static size_t convert(Coder *c, const uint8_t *src, size_t n, uint8_t *dst, size_t cap) {
#if defined(ARM_ICU)
    UErrorCode err = U_ZERO_ERROR;
    switch (c->op) {
    case 0:
        return (size_t)ucnv_toAlgorithmic(UCNV_UTF8, c->cnv, (char *)dst, (int32_t)cap, (const char *)src, (int32_t)n, &err);
    case 1: {
        ucnv_resetToUnicode(c->cnv);
        UChar *t = (UChar *)dst;
        const char *s = (const char *)src;
        ucnv_toUnicode(c->cnv, &t, (UChar *)(dst + cap), &s, s + n, NULL, 1, &err);
        return (size_t)((uint8_t *)t - dst);
    }
    case 2:
        return (size_t)ucnv_fromAlgorithmic(c->cnv, UCNV_UTF8, (char *)dst, (int32_t)cap, (const char *)src, (int32_t)n, &err);
    default: {
        ucnv_resetFromUnicode(c->cnv);
        char *t = (char *)dst;
        const UChar *s = (const UChar *)src;
        ucnv_fromUnicode(c->cnv, &t, (char *)dst + cap, &s, (const UChar *)(src + n), NULL, 1, &err);
        return (size_t)((uint8_t *)t - dst);
    }
    }
#else
    char *in = (char *)src, *out = (char *)dst;
    size_t inleft = n, outleft = cap;
    iconv(c->cd, NULL, NULL, NULL, NULL);
    int decode = c->op < 2, utf16 = c->op == 1 || c->op == 3;
    while (inleft > 0) {
        if (iconv(c->cd, &in, &inleft, &out, &outleft) != (size_t)-1) break;
        if (errno == E2BIG) break;
        if (decode) {
            // U+FFFD for the byte that does not decode, or the incomplete
            // sequence at the end.
            if (utf16) put(&out, &outleft, "\xFD\xFF", 2);
            else put(&out, &outleft, "\xEF\xBF\xBD", 3);
            if (errno == EINVAL) break;
            in++;
            inleft--;
        } else {
            size_t len;
            uint32_t cp = next_char(utf16, in, inleft, &len);
            char ncr[16];
            put(&out, &outleft, ncr, (size_t)snprintf(ncr, sizeof ncr, "&#%u;", cp));
            in += len;
            inleft -= len;
        }
    }
    iconv(c->cd, NULL, NULL, &out, &outleft);
    return (size_t)(out - (char *)dst);
#endif
}

static uint64_t fnv1a(const uint8_t *p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ull;
    return h;
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// The call the timed loop makes through a pointer the compiler cannot see
// through, so it stays out of line.
static size_t (*volatile call)(Coder *, const uint8_t *, size_t, uint8_t *, size_t) = convert;

static double run(Coder *c, Placed in, Placed out, uint64_t n) {
    double start = now();
    for (uint64_t i = 0; i < n; i++) {
        size_t r = call(c, bytes(in), in.len, bytes(out), out.len);
        __asm__ volatile("" : : "r"(r) : "memory");
    }
    return now() - start;
}

static void measure(const char *row, Coder *c, Placed in, Placed out, uint64_t n, double goal) {
    double elapsed;
    if (n > 0) {
        run(c, in, out, 1);
        elapsed = run(c, in, out, n);
    } else {
        n = 1;
        elapsed = run(c, in, out, n);
        while (elapsed < goal && n < 1000000000) {
            uint64_t last = n;
            double next = goal * (double)last / (elapsed > 1e-9 ? elapsed : 1e-9);
            next += next / 5;
            n = (uint64_t)next;
            if (n < last + 1) n = last + 1;
            if (n > 100 * last) n = 100 * last;
            if (n > 1000000000) n = 1000000000;
            elapsed = run(c, in, out, n);
        }
    }
    printf("Benchmark%s\t%llu\t%.2f ns/op\t%.2f MB/s\n", row, (unsigned long long)n, elapsed * 1e9 / (double)n,
           (double)in.len * (double)n / 1e6 / elapsed);
    fflush(stdout);
}

static int op_of(const char *arg) {
    for (int i = 0; i < 4; i++)
        if (!strcmp(ops[i].arg, arg)) return i;
    return -1;
}

static Placed output(int op, const Input *in) { return placed(input_of(in, op).len * ops[op].out + 64, out_offset); }

static void serve(double goal) {
    char line[512], loaded[64] = "";
    Input *ins = NULL;
    size_t nins = 0;
    while (fgets(line, sizeof line, stdin)) {
        char arg[32], enc[64], name[64];
        unsigned long long n;
        if (sscanf(line, "%31s %63s %63s %llu", arg, enc, name, &n) != 4) fail("bad request: %s", line);
        int op = op_of(arg);
        if (op < 0) fail("no operation %s", arg);
        Coder c;
        const char *why;
        if (!coder_open(&c, enc, op, &why)) fail("%s", why);
        if (strcmp(loaded, enc)) {
            if (ins) unload(ins, nins);
            ins = load(enc, &nins);
            snprintf(loaded, sizeof loaded, "%s", enc);
        }
        size_t k = 0;
        while (k < nins && strcmp(ins[k].name, name)) k++;
        if (k == nins) fail("no input %s", name);
        Placed out = output(op, &ins[k]);
        memset(out.base, 1, out.size);
        char row[256];
        snprintf(row, sizeof row, "%s/%s/%s", ops[op].row, enc, name);
        measure(row, &c, input_of(&ins[k], op), out, n, goal);
        unplace(out);
        coder_close(&c);
    }
}

int main(int argc, char **argv) {
    in_offset = offset_env("BENCH_IN_OFFSET", 0);
    out_offset = offset_env("BENCH_OUT_OFFSET", 2048);
    const char *ms = getenv("BENCHTIME_MS");
    double goal = (ms ? strtod(ms, NULL) : 100) / 1000;
    if (argc >= 2 && !strcmp(argv[1], "serve")) {
        serve(goal);
        return 0;
    }
    if (argc < 2 || strcmp(argv[1], "check")) {
        fprintf(stderr, "usage: bench-" ARM " check [OP...] | serve\n");
        return 2;
    }
    int wanted[4] = {argc == 2, argc == 2, argc == 2, argc == 2};
    for (int i = 2; i < argc; i++) {
        int op = op_of(argv[i]);
        if (op < 0) fail("unknown operation %s", argv[i]);
        wanted[op] = 1;
    }
    size_t tlen;
    char *tsv = (char *)read_file("bench/encodings.tsv", &tlen);
    tsv[tlen] = 0;
    for (char *line = strtok(tsv, "\n"); line; line = strtok(NULL, "\n")) {
        if (line[0] == '#') continue;
        char enc[64];
        sscanf(line, "%63[^\t]", enc);
        Input *ins = NULL;
        size_t nins = 0;
        for (int op = 0; op < 4; op++) {
            if (!wanted[op]) continue;
            Coder c;
            const char *why;
            if (!coder_open(&c, enc, op, &why)) {
                printf("# SKIP Benchmark%s/%s: %s\n", ops[op].row, enc, why);
                continue;
            }
            if (!ins) ins = load(enc, &nins);
            for (size_t k = 0; k < nins; k++) {
                Placed out = output(op, &ins[k]);
                Placed in = input_of(&ins[k], op);
                size_t n = convert(&c, bytes(in), in.len, bytes(out), out.len);
                printf("%s/%s/%s\tlen=%zu fnv=%016llx\n", ops[op].row, enc, ins[k].name, n,
                       (unsigned long long)fnv1a(bytes(out), n));
                unplace(out);
            }
            coder_close(&c);
        }
        if (ins) unload(ins, nins);
    }
    return 0;
}
