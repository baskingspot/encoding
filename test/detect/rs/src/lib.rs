//! What the detection harness's Rust programs share: the corpus sources
//! (gen/detect/sources.tsv and groups.tsv) and the samples file every arm
//! reads (test/detect/README.md).

use std::io::{BufRead, Read};

pub const OUT: &str = "zig-out/detect";

pub fn fail(message: &str) -> ! {
    eprintln!("detect: {message}");
    std::process::exit(1);
}

/// A language of the corpus: its Wikipedia, its group of encodings, and the
/// revisions of its articles, in the order the first two thirds of each
/// three train and the third tests.
pub struct Source {
    pub lang: String,
    pub wiki: String,
    pub group: String,
    pub revids: Vec<u64>,
}

fn rows(path: &str) -> Vec<Vec<String>> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("{path}: {e}")));
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .map(|l| l.split('\t').map(String::from).collect())
        .collect()
}

pub fn sources() -> Vec<Source> {
    rows("gen/detect/sources.tsv")
        .into_iter()
        .map(|r| Source {
            lang: r[0].clone(),
            wiki: r[1].clone(),
            group: r[2].clone(),
            revids: r
                .get(3)
                .map(|s| {
                    s.split(',')
                        .filter(|x| !x.is_empty())
                        .map(|x| x.parse().unwrap())
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect()
}

/// Each group's encodings, by the standard's names, its training encoding
/// first.
pub fn groups() -> Vec<(String, Vec<String>)> {
    rows("gen/detect/groups.tsv")
        .into_iter()
        .map(|r| (r[0].clone(), r[1].split(',').map(String::from).collect()))
        .collect()
}

/// One sample: a window of a test article (`w`, `length` its target size),
/// or a whole article (`d`) cut at each of `cuts`.
pub struct Sample {
    pub kind: char,
    pub lang: String,
    pub encoding: String,
    pub length: usize,
    pub cuts: Vec<usize>,
    pub bytes: Vec<u8>,
}

/// Every sample in the samples file: a header line, `KIND LANG ENCODING
/// LENGTH NCUTS CUT...`, then the bytes and a newline.
pub fn read_samples(path: &str) -> Vec<Sample> {
    let f = std::fs::File::open(path).unwrap_or_else(|e| fail(&format!("{path}: {e}")));
    let mut r = std::io::BufReader::new(f);
    let mut out = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line).unwrap() == 0 {
            break;
        }
        let f: Vec<&str> = line.split_whitespace().collect();
        let ncuts: usize = f[4].parse().unwrap();
        let cuts: Vec<usize> = f[5..5 + ncuts].iter().map(|c| c.parse().unwrap()).collect();
        let len = *cuts.last().unwrap();
        let mut bytes = vec![0u8; len + 1];
        r.read_exact(&mut bytes).unwrap();
        bytes.pop();
        out.push(Sample {
            kind: f[0].chars().next().unwrap(),
            lang: f[1].to_string(),
            encoding: f[2].to_string(),
            length: f[3].parse().unwrap(),
            cuts,
            bytes,
        });
    }
    out
}
