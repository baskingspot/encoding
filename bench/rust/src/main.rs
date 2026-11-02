//! The encoding_rs arm of `just bench-compare` (bench/README.md), the bar
//! every other arm is compared with.
//!
//! Usage, from the repository root, with the same contract as every arm:
//!
//!     bench-rust check [OP...]   one checksum line per row
//!     bench-rust serve           one row per request line on stdin
//!
//! OP is decode-utf8, decode-utf16, encode-utf8, or encode-utf16; none
//! means all, over every encoding in bench/encodings.tsv. A `serve`
//! request is `OP ENCODING INPUT N`: time the row N iterations after one
//! untimed call, or for BENCHTIME_MS (default 100) when N is 0, sized the
//! way Go's `testing.B` sizes a loop. Every input starts BENCH_IN_OFFSET
//! bytes (default 0) past a page boundary and its output BENCH_OUT_OFFSET
//! bytes (default 2048) past another, as in every arm.
//!
//! Each call makes a decoder without BOM handling, or an encoder, and
//! converts the whole input with `last` set, replacing errors (U+FFFD, or
//! a numeric character reference), as the package's arm does.

use encoding_rs::Encoding;
use std::hint::black_box;
use std::io::{BufRead, Read, Write};
use std::time::{Duration, Instant};

const CORPUS: &str = "bench/corpus-gen";

extern "C" {
    fn mmap(addr: *mut u8, len: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut u8;
    fn munmap(addr: *mut u8, len: usize) -> i32;
}

/// `len` bytes `off` bytes past a page boundary, in an anonymous mapping of
/// their own: zeroed, and resident only once written. Every arm places its
/// buffers this way.
struct Placed {
    base: *mut u8,
    size: usize,
    off: usize,
    len: usize,
}

impl Placed {
    fn new(len: usize, off: usize) -> Placed {
        let size = (off + len + 4096) / 4096 * 4096;
        // PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS
        let base = unsafe { mmap(std::ptr::null_mut(), size, 3, 0x22, -1, 0) };
        if base as isize == -1 {
            fail("out of memory");
        }
        Placed {
            base,
            size,
            off,
            len,
        }
    }
    fn bytes(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.base.add(self.off), self.len) }
    }
    fn bytes_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.base.add(self.off), self.len) }
    }
    /// The bytes as native-endian UTF-16 code units; the offsets are even.
    fn units(&self) -> &[u16] {
        unsafe { std::slice::from_raw_parts(self.base.add(self.off) as *const u16, self.len / 2) }
    }
    fn units_mut(&mut self) -> &mut [u16] {
        unsafe { std::slice::from_raw_parts_mut(self.base.add(self.off) as *mut u16, self.len / 2) }
    }
    /// Writes every page of the mapping but the data's bytes: a masked load
    /// whose masked-off lanes reach a page nothing has touched takes a
    /// microcode assist on every call.
    fn write_rest(&mut self) {
        unsafe {
            std::ptr::write_bytes(self.base, 1, self.off);
            std::ptr::write_bytes(
                self.base.add(self.off + self.len),
                1,
                self.size - self.off - self.len,
            );
        }
    }
    fn write_all(&mut self) {
        unsafe { std::ptr::write_bytes(self.base, 1, self.size) };
    }
}

impl Drop for Placed {
    fn drop(&mut self) {
        unsafe { munmap(self.base, self.size) };
    }
}

fn fail(message: &str) -> ! {
    eprintln!("bench-rust: {message}");
    std::process::exit(1);
}

fn offset_env(name: &str, default: usize) -> usize {
    let off = std::env::var(name).ok().map_or(default, |v| {
        v.parse()
            .unwrap_or_else(|_| fail(&format!("{name} needs a number")))
    });
    if off >= 4096 || off % 4 != 0 {
        fail(&format!("{name} must be a multiple of 4 under 4096"));
    }
    off
}

/// One input: its bytes in the encoding, its text in UTF-8, and the same
/// text in UTF-16, each placed alike.
struct Input {
    name: String,
    bin: Placed,
    utf8: Placed,
    utf16: Placed,
}

impl Input {
    /// The input an operation reads.
    fn of(&self, op: usize) -> &Placed {
        [&self.bin, &self.bin, &self.utf8, &self.utf16][op]
    }
}

/// The operations: argument, row name, and output bytes per input byte.
const OPS: [(&str, &str, usize); 4] = [
    ("decode-utf8", "DecodeUtf8", 3),
    ("decode-utf16", "DecodeUtf16", 2),
    ("encode-utf8", "EncodeUtf8", 4),
    ("encode-utf16", "EncodeUtf16", 4),
];

type Fn = fn(&'static Encoding, &Placed, &mut Placed) -> usize;

fn decode_utf8(e: &'static Encoding, src: &Placed, dst: &mut Placed) -> usize {
    let mut d = e.new_decoder_without_bom_handling();
    d.decode_to_utf8(src.bytes(), dst.bytes_mut(), true).2
}

fn decode_utf16(e: &'static Encoding, src: &Placed, dst: &mut Placed) -> usize {
    let mut d = e.new_decoder_without_bom_handling();
    2 * d.decode_to_utf16(src.bytes(), dst.units_mut(), true).2
}

fn encode_utf8(e: &'static Encoding, src: &Placed, dst: &mut Placed) -> usize {
    let mut enc = e.new_encoder();
    // The corpus's UTF-8 is valid.
    let s = unsafe { std::str::from_utf8_unchecked(src.bytes()) };
    enc.encode_from_utf8(s, dst.bytes_mut(), true).2
}

fn encode_utf16(e: &'static Encoding, src: &Placed, dst: &mut Placed) -> usize {
    let mut enc = e.new_encoder();
    enc.encode_from_utf16(src.units(), dst.bytes_mut(), true).2
}

const FNS: [Fn; 4] = [decode_utf8, decode_utf16, encode_utf8, encode_utf16];

/// This arm's encoding for a name in bench/encodings.tsv, or why not. An
/// encoder for an encoding whose output encoding is another (UTF-16 and
/// replacement encode as UTF-8) is skipped, as in every arm.
fn coder(name: &str, op: usize) -> Result<&'static Encoding, &'static str> {
    let e = match Encoding::for_label(name.as_bytes()) {
        Some(e) if e.name() == name => e,
        _ => return Err("encoding_rs has no such encoding"),
    };
    if op >= 2 && e.output_encoding() != e {
        return Err("the standard has no encoder for it");
    }
    Ok(e)
}

fn encodings() -> Vec<String> {
    let text = std::fs::read_to_string("bench/encodings.tsv").unwrap_or_else(|e| {
        fail(&format!(
            "open bench/encodings.tsv: {e} (run from the repository root)"
        ))
    });
    text.lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| l.split('\t').next().unwrap().to_string())
        .collect()
}

/// Every input of an encoding, smallest first, then by name.
fn load(name: &str, in_offset: usize) -> Vec<Input> {
    let path = format!("{CORPUS}/{name}");
    let entries = std::fs::read_dir(&path)
        .unwrap_or_else(|e| fail(&format!("open {path}: {e} (run `just bench-corpus`)")));
    let place = |bytes: &[u8]| {
        let mut p = Placed::new(bytes.len(), in_offset);
        p.bytes_mut().copy_from_slice(bytes);
        p.write_rest();
        p
    };
    let mut inputs: Vec<Input> = entries
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|x| x == "bin"))
        .map(|path| {
            let read = |p: &std::path::Path| {
                let mut v = Vec::new();
                std::fs::File::open(p)
                    .unwrap_or_else(|e| fail(&format!("{}: {e}", p.display())))
                    .read_to_end(&mut v)
                    .unwrap();
                v
            };
            let bin = read(&path);
            let utf8 = read(&path.with_extension("utf8"));
            let units: Vec<u8> = std::str::from_utf8(&utf8)
                .unwrap()
                .encode_utf16()
                .flat_map(u16::to_ne_bytes)
                .collect();
            Input {
                name: path.file_stem().unwrap().to_string_lossy().into_owned(),
                bin: place(&bin),
                utf8: place(&utf8),
                utf16: place(&units),
            }
        })
        .collect();
    inputs.sort_by(|a, b| a.bin.len.cmp(&b.bin.len).then_with(|| a.name.cmp(&b.name)));
    inputs
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| {
        (h ^ b as u64).wrapping_mul(0x100000001b3)
    })
}

/// Calls `f` through its pointer, hidden from the optimizer, so the call
/// stays out of line and the loop does not keep the function's constants.
fn run(f: Fn, e: &'static Encoding, input: &Placed, out: &mut Placed, n: u64) -> Duration {
    let start = Instant::now();
    for _ in 0..n {
        black_box(black_box(f)(
            black_box(e),
            black_box(input),
            black_box(&mut *out),
        ));
    }
    start.elapsed()
}

/// Times one row: `n` iterations after one untimed call, or with `n` 0,
/// growing `n` until a run takes the goal, as Go's `testing.B` does.
fn measure(
    row: &str,
    f: Fn,
    e: &'static Encoding,
    input: &Placed,
    out: &mut Placed,
    mut n: u64,
    goal: Duration,
) {
    let elapsed = if n > 0 {
        run(f, e, input, out, 1);
        run(f, e, input, out, n)
    } else {
        let max_n = 1_000_000_000;
        n = 1;
        let mut elapsed = run(f, e, input, out, n);
        while elapsed < goal && n < max_n {
            let last = n;
            let prev_ns = elapsed.as_nanos().max(1);
            let mut next = (goal.as_nanos() * last as u128 / prev_ns) as u64;
            next += next / 5;
            n = next.max(last + 1).min(100 * last).min(max_n);
            elapsed = run(f, e, input, out, n);
        }
        elapsed
    };
    let ns_per_op = elapsed.as_nanos() as f64 / n as f64;
    let mb_per_s = input.len as f64 * n as f64 / 1e6 / elapsed.as_secs_f64();
    let mut stdout = std::io::stdout().lock();
    writeln!(
        stdout,
        "Benchmark{row}\t{n}\t{ns_per_op:.2} ns/op\t{mb_per_s:.2} MB/s"
    )
    .unwrap();
    stdout.flush().unwrap();
}

fn output(op: usize, input: &Input, out_offset: usize) -> Placed {
    Placed::new(input.of(op).len * OPS[op].2 + 64, out_offset)
}

/// `serve`: one row per request line, `OP ENCODING INPUT N`, until stdin
/// ends. The requested encoding's inputs stay loaded until another is
/// requested.
fn serve(goal: Duration, in_offset: usize, out_offset: usize) {
    let mut loaded: Option<(String, Vec<Input>)> = None;
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let fields: Vec<&str> = line.split_whitespace().collect();
        let [arg, name, input, n] = fields[..] else {
            fail(&format!("bad request: {line}"))
        };
        let n: u64 = n
            .parse()
            .unwrap_or_else(|_| fail(&format!("bad request: {line}")));
        let op = OPS
            .iter()
            .position(|o| o.0 == arg)
            .unwrap_or_else(|| fail(&format!("no operation {arg}")));
        let e = coder(name, op).unwrap_or_else(|why| fail(&format!("{arg} {name}: {why}")));
        if loaded.as_ref().is_none_or(|(l, _)| l != name) {
            loaded = Some((name.to_string(), load(name, in_offset)));
        }
        let inputs = &loaded.as_ref().unwrap().1;
        let k = inputs
            .iter()
            .position(|i| i.name == input)
            .unwrap_or_else(|| fail(&format!("no input {input} for {name}")));
        let mut out = output(op, &inputs[k], out_offset);
        out.write_all();
        measure(
            &format!("{}/{name}/{input}", OPS[op].1),
            FNS[op],
            e,
            inputs[k].of(op),
            &mut out,
            n,
            goal,
        );
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let goal_ms: u64 = std::env::var("BENCHTIME_MS").ok().map_or(100, |v| {
        v.parse()
            .unwrap_or_else(|_| fail("BENCHTIME_MS needs a number"))
    });
    let in_offset = offset_env("BENCH_IN_OFFSET", 0);
    let out_offset = offset_env("BENCH_OUT_OFFSET", 2048);
    match args.get(1).map(String::as_str) {
        Some("serve") => return serve(Duration::from_millis(goal_ms), in_offset, out_offset),
        Some("check") => {}
        _ => {
            eprintln!("usage: bench-rust check [OP...] | serve");
            std::process::exit(2);
        }
    }
    let wanted = &args[2..];
    for w in wanted {
        if !OPS.iter().any(|o| o.0 == *w) {
            fail(&format!("unknown operation {w}"));
        }
    }
    let mut stdout = std::io::stdout().lock();
    for name in encodings() {
        let ops: Vec<usize> = (0..4)
            .filter(|&op| wanted.is_empty() || wanted.iter().any(|w| *w == OPS[op].0))
            .collect();
        let mut inputs = None;
        for op in ops {
            let e = match coder(&name, op) {
                Ok(e) => e,
                Err(why) => {
                    writeln!(stdout, "# SKIP Benchmark{}/{name}: {why}", OPS[op].1).unwrap();
                    continue;
                }
            };
            let inputs = inputs.get_or_insert_with(|| load(&name, in_offset));
            for input in inputs.iter() {
                let mut out = output(op, input, out_offset);
                let n = FNS[op](e, input.of(op), &mut out);
                // UTF-16 output is its bytes in memory, little endian here.
                writeln!(
                    stdout,
                    "{}/{name}/{}\tlen={n} fnv={:016x}",
                    OPS[op].1,
                    input.name,
                    fnv1a(&out.bytes()[..n])
                )
                .unwrap();
            }
        }
    }
}
