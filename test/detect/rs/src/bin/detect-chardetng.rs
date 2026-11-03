//! The chardetng arm of the detection scoring harness
//! (test/detect/README.md), run from the repository root:
//!
//!     detect-chardetng guess SAMPLES     one line per sample: chardetng's
//!                                        guess for each of its cuts
//!     detect-chardetng bench SAMPLES     the whole articles' bytes per
//!                                        second, then the time per call on
//!                                        the 32-byte windows, each over at
//!                                        least BENCH_MS
//!
//! Each guess is a fresh detector fed the bytes up to the cut with `last`
//! set, asked for its guess with no top-level domain and UTF-8 allowed.

use std::io::Write as _;
use std::time::Instant;

use chardetng::EncodingDetector;
use detect_harness::{fail, read_samples};

fn guess(bytes: &[u8]) -> &'static encoding_rs::Encoding {
    let mut d = EncodingDetector::new();
    d.feed(bytes, true);
    d.guess(None, true)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        fail("usage: detect-chardetng guess|bench SAMPLES");
    }
    let samples = read_samples(&args[2]);
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    match args[1].as_str() {
        "guess" => {
            for s in &samples {
                let names: Vec<&str> = s
                    .cuts
                    .iter()
                    .map(|&c| guess(&s.bytes[..c]).name())
                    .collect();
                writeln!(out, "{}", names.join(" ")).unwrap();
            }
        }
        "bench" => {
            let ms: u128 = std::env::var("BENCH_MS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(2000);
            let docs: Vec<&[u8]> = samples
                .iter()
                .filter(|s| s.kind == 'd')
                .map(|s| &s.bytes[..])
                .collect();
            let total: usize = docs.iter().map(|d| d.len()).sum();
            let start = Instant::now();
            let mut rounds = 0u64;
            let mut sink = 0usize;
            while rounds == 0 || start.elapsed().as_millis() < ms {
                for d in &docs {
                    sink ^= guess(d).name().len();
                }
                rounds += 1;
            }
            let secs = start.elapsed().as_secs_f64();
            writeln!(
                out,
                "chardetng\t{} bytes x {rounds}\t{:.1} MB/s\t(sink {sink})",
                total,
                total as f64 * rounds as f64 / secs / 1e6
            )
            .unwrap();
            // The cost of a call on short input: a fresh detector per
            // 32-byte window.
            let wins: Vec<&[u8]> = samples
                .iter()
                .filter(|s| s.kind == 'w' && s.length == 32)
                .map(|s| &s.bytes[..])
                .collect();
            let start = Instant::now();
            let mut calls = 0u64;
            while calls == 0 || start.elapsed().as_millis() < ms {
                for w in &wins {
                    sink ^= guess(w).name().len();
                }
                calls += wins.len() as u64;
            }
            writeln!(
                out,
                "chardetng\t32-byte windows x {calls}\t{:.0} ns per call\t(sink {sink})",
                start.elapsed().as_secs_f64() * 1e9 / calls as f64
            )
            .unwrap();
        }
        _ => fail("usage: detect-chardetng guess|bench SAMPLES"),
    }
}
