// Command bench-go is the Go arm of `just bench-compare` (bench/README.md):
// golang.org/x/text's encodings, looked up by the standard's names with
// htmlindex, and its IBM code pages from charmap.
//
// Usage, from the repository root, with the same contract as every arm:
//
//	bench-go check [OP...]   one checksum line per row
//	bench-go serve           one row per request line on stdin
//
// OP is decode-utf8, decode-utf16, encode-utf8, or encode-utf16; none means
// all, over every encoding in bench/encodings.tsv. A serve request is
// `OP ENCODING INPUT N`: time the row N iterations, or for BENCHTIME_MS
// (default 100) when N is 0; Go's own testing.Benchmark sizes it. Every
// input starts BENCH_IN_OFFSET bytes (default 0) past a page boundary and
// its output BENCH_OUT_OFFSET bytes (default 2048) past another, as in
// every arm.
//
// A transformer is made once per row and reset before each call, as a
// program converting many strings would keep one. x/text converts to and
// from UTF-8 only, so this arm skips the UTF-16 operations. Its encoders
// write a numeric character reference for a character the encoding lacks,
// through encoding.HTMLEscapeUnsupported.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/htmlindex"
	"golang.org/x/text/transform"
)

const corpus = "bench/corpus-gen"

var ops = []struct {
	arg, row string
	out      int
}{
	{"decode-utf8", "DecodeUtf8", 3},
	{"decode-utf16", "DecodeUtf16", 2},
	{"encode-utf8", "EncodeUtf8", 4},
	{"encode-utf16", "EncodeUtf16", 4},
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "bench-go: "+format+"\n", args...)
	os.Exit(1)
}

// coder is this arm's transformer for an encoding and operation, or why
// there is none.
func coder(name string, op int) (transform.Transformer, string) {
	if op == 1 || op == 3 {
		return nil, "x/text converts only to and from UTF-8"
	}
	if op == 2 && (name == "UTF-16LE" || name == "UTF-16BE") {
		return nil, "the standard has no encoder for it"
	}
	var e encoding.Encoding
	switch name {
	case "IBM437":
		e = charmap.CodePage437
	case "IBM850":
		e = charmap.CodePage850
	default:
		var err error
		if e, err = htmlindex.Get(name); err != nil {
			return nil, "x/text has no such encoding"
		}
	}
	if op == 0 {
		return e.NewDecoder(), ""
	}
	return encoding.HTMLEscapeUnsupported(e.NewEncoder()), ""
}

// placed is n bytes off bytes past a page boundary, in an anonymous mapping
// of their own, and the whole mapping.
func placed(n, off int) (data, mapping []byte) {
	size := (off + n + 4096) / 4096 * 4096
	m, err := syscall.Mmap(-1, 0, size, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		fail("mmap: %v", err)
	}
	return m[off : off+n : off+n], m
}

func offsetEnv(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	off, err := strconv.Atoi(v)
	if err != nil || off >= 4096 || off%4 != 0 {
		fail("%s must be a multiple of 4 under 4096", name)
	}
	return off
}

var inOffset, outOffset int

// mappings holds the loaded encoding's inputs' mappings, unmapped when
// another is loaded, so that only one encoding's inputs count in RSS.
var mappings [][]byte

func unload() {
	for _, m := range mappings {
		syscall.Munmap(m)
	}
	mappings = nil
}

// place copies data into a placed buffer and writes every other page of its
// mapping: a masked load whose masked-off lanes reach a page nothing has
// touched takes a microcode assist on every call.
func place(data []byte) []byte {
	p, m := placed(len(data), inOffset)
	mappings = append(mappings, m)
	for i := range m {
		m[i] = 1
	}
	copy(p, data)
	return p
}

type input struct {
	name      string
	bin, utf8 []byte
}

func (in input) of(op int) []byte {
	if op < 2 {
		return in.bin
	}
	return in.utf8
}

func load(name string) []input {
	unload()
	dir := filepath.Join(corpus, name)
	files, err := filepath.Glob(filepath.Join(dir, "*.bin"))
	if err != nil || len(files) == 0 {
		fail("open %s (run `just bench-corpus`)", dir)
	}
	var ins []input
	for _, f := range files {
		bin, err := os.ReadFile(f)
		if err != nil {
			fail("%v", err)
		}
		stem := strings.TrimSuffix(f, ".bin")
		utf8, err := os.ReadFile(stem + ".utf8")
		if err != nil {
			fail("%v", err)
		}
		ins = append(ins, input{filepath.Base(stem), place(bin), place(utf8)})
	}
	slices.SortFunc(ins, func(a, b input) int {
		if len(a.bin) != len(b.bin) {
			return len(a.bin) - len(b.bin)
		}
		return strings.Compare(a.name, b.name)
	})
	return ins
}

func encodings() []string {
	text, err := os.ReadFile("bench/encodings.tsv")
	if err != nil {
		fail("open bench/encodings.tsv: %v (run from the repository root)", err)
	}
	var names []string
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" || line[0] == '#' {
			continue
		}
		names = append(names, strings.SplitN(line, "\t", 2)[0])
	}
	return names
}

// convert runs the whole input through t; it returns the bytes written.
//
//go:noinline
func convert(t transform.Transformer, src, dst []byte) int {
	t.Reset()
	n, _, _ := t.Transform(dst, src, true)
	return n
}

var sink int

func measure(row string, t transform.Transformer, src, dst []byte, n int, goal time.Duration) {
	var r testing.BenchmarkResult
	if n > 0 {
		convert(t, src, dst)
		start := time.Now()
		for i := 0; i < n; i++ {
			sink += convert(t, src, dst)
		}
		r = testing.BenchmarkResult{N: n, T: time.Since(start), Bytes: int64(len(src))}
	} else {
		flag.Set("test.benchtime", goal.String())
		r = testing.Benchmark(func(b *testing.B) {
			b.SetBytes(int64(len(src)))
			for i := 0; i < b.N; i++ {
				sink += convert(t, src, dst)
			}
		})
	}
	ns := float64(r.T.Nanoseconds()) / float64(r.N)
	mbs := float64(r.Bytes) * float64(r.N) / 1e6 / r.T.Seconds()
	fmt.Printf("Benchmark%s\t%d\t%.2f ns/op\t%.2f MB/s\n", row, r.N, ns, mbs)
}

func main() {
	testing.Init()
	inOffset = offsetEnv("BENCH_IN_OFFSET", 0)
	outOffset = offsetEnv("BENCH_OUT_OFFSET", 2048)
	goal := 100 * time.Millisecond
	if v := os.Getenv("BENCHTIME_MS"); v != "" {
		ms, err := strconv.Atoi(v)
		if err != nil {
			fail("BENCHTIME_MS needs a number")
		}
		goal = time.Duration(ms) * time.Millisecond
	}
	if len(os.Args) >= 2 && os.Args[1] == "serve" {
		serve(goal)
		return
	}
	if len(os.Args) < 2 || os.Args[1] != "check" {
		fmt.Fprintln(os.Stderr, "usage: bench-go check [OP...] | serve")
		os.Exit(2)
	}
	wanted := make([]bool, len(ops))
	for i := range wanted {
		wanted[i] = len(os.Args) == 2
	}
	for _, a := range os.Args[2:] {
		i := slices.IndexFunc(ops, func(o struct {
			arg, row string
			out      int
		}) bool {
			return o.arg == a
		})
		if i < 0 {
			fail("unknown operation %s", a)
		}
		wanted[i] = true
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	for _, name := range encodings() {
		var ins []input
		for op, o := range ops {
			if !wanted[op] {
				continue
			}
			t, why := coder(name, op)
			if t == nil {
				fmt.Fprintf(w, "# SKIP Benchmark%s/%s: %s\n", o.row, name, why)
				continue
			}
			if ins == nil {
				ins = load(name)
			}
			for _, in := range ins {
				src := in.of(op)
				dst, m := placed(len(src)*o.out+64, outOffset)
				n := convert(t, src, dst)
				h := fnv.New64a()
				h.Write(dst[:n])
				fmt.Fprintf(w, "%s/%s/%s\tlen=%d fnv=%016x\n", o.row, name, in.name, n, h.Sum64())
				syscall.Munmap(m)
			}
		}
	}
}

func serve(goal time.Duration) {
	scanner := bufio.NewScanner(os.Stdin)
	loaded := ""
	var ins []input
	for scanner.Scan() {
		f := strings.Fields(scanner.Text())
		if len(f) != 4 {
			fail("bad request: %s", scanner.Text())
		}
		op := slices.IndexFunc(ops, func(o struct {
			arg, row string
			out      int
		}) bool {
			return o.arg == f[0]
		})
		n, err := strconv.Atoi(f[3])
		if op < 0 || err != nil {
			fail("bad request: %s", scanner.Text())
		}
		t, why := coder(f[1], op)
		if t == nil {
			fail("%s %s: %s", f[0], f[1], why)
		}
		if loaded != f[1] {
			ins, loaded = load(f[1]), f[1]
		}
		k := slices.IndexFunc(ins, func(in input) bool { return in.name == f[2] })
		if k < 0 {
			fail("no input %s", f[2])
		}
		src := ins[k].of(op)
		dst, m := placed(len(src)*ops[op].out+64, outOffset)
		for i := range m {
			m[i] = 1
		}
		measure(ops[op].row+"/"+f[1]+"/"+f[2], t, src, dst, n, goal)
		syscall.Munmap(m)
	}
}
