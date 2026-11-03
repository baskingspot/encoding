//! The detection corpus (test/detect/README.md), run from the repository
//! root:
//!
//!     detect-corpus select INFO.json     revisions of articles of 6000
//!                                        bytes or more, in the API's order
//!     detect-corpus zh-split CONTENT.json...
//!                                        `hans REVID` or `hant REVID` for
//!                                        each Chinese article written in
//!                                        one script
//!     detect-corpus unpack CONTENT.json DIR
//!                                        each revision's wikitext to
//!                                        DIR/REVID.wiki
//!     detect-corpus build                the training text and the test
//!                                        samples, from zig-out/detect/wiki/
//!
//! `build` is deterministic: of each language's articles in
//! gen/detect/sources.tsv, the first two of every three are training text,
//! written as UTF-8 prose fitted to the group's first encoding to
//! zig-out/detect/train/LANG.txt, and the third is test text, encoded in
//! every encoding of the group into zig-out/detect/samples.txt.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::io::Write as _;

use detect_harness::{fail, groups, sources, OUT};
use encoding_rs::{EncoderResult, Encoding};
use unicode_normalization::UnicodeNormalization;

/// Window sizes, in bytes.
const WINDOWS: &[usize] = &[16, 32, 64, 128, 256, 1024, 4096];
/// Windows per test article and size.
const PER_ARTICLE: usize = 5;
/// Where a whole article is also cut, for the bytes a detector needs.
const CUTS: &[usize] = &[
    16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192,
    12288, 16384, 24576, 32768, 49152, 65536,
];
/// Articles are cut to this many bytes of prose.
const MAX_ARTICLE: usize = 96 * 1024;

fn json(path: &str) -> serde_json::Value {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(&format!("{path}: {e}")));
    serde_json::from_str(&text).unwrap_or_else(|e| fail(&format!("{path}: {e}")))
}

/// Every revision in a `prop=revisions` answer: its id and wikitext.
fn revisions(v: &serde_json::Value) -> Vec<(u64, String)> {
    if let Some(bad) = v["query"].get("badrevids") {
        fail(&format!("revisions missing: {bad}"));
    }
    let mut out = Vec::new();
    for page in v["query"]["pages"].as_array().into_iter().flatten() {
        for rev in page["revisions"].as_array().into_iter().flatten() {
            let id = rev["revid"].as_u64().unwrap();
            let text = rev["slots"]["main"]["content"]
                .as_str()
                .unwrap_or_else(|| fail(&format!("revision {id} has no content")));
            out.push((id, text.to_string()));
        }
    }
    out
}

/// The prose of a page of wikitext: no templates, tables, references,
/// tags, or link targets; one paragraph per line. bench-corpus's reading,
/// which detection's corpus shares.
fn prose(wikitext: &str) -> Vec<String> {
    let mut s = String::with_capacity(wikitext.len());
    let b = wikitext.as_bytes();
    let mut i = 0;
    let mut depth = 0usize;
    while i < b.len() {
        let rest = &wikitext[i..];
        if rest.starts_with("{{") || rest.starts_with("{|") {
            depth += 1;
            i += 2;
        } else if depth > 0 && (rest.starts_with("}}") || rest.starts_with("|}")) {
            depth -= 1;
            i += 2;
        } else if rest.starts_with("<!--") {
            i += rest.find("-->").map_or(rest.len(), |n| n + 3);
        } else if rest.starts_with("<ref") {
            let open_end = rest.find('>').unwrap_or(rest.len() - 1);
            if rest[..open_end].ends_with('/') {
                i += open_end + 1;
            } else {
                i += rest.find("</ref>").map_or(open_end + 1, |n| n + 6);
            }
        } else {
            let c = rest.chars().next().unwrap();
            if depth == 0 {
                s.push(c);
            }
            i += c.len_utf8();
        }
    }
    let mut t = String::with_capacity(s.len());
    let mut rest = s.as_str();
    while let Some(start) = rest.find("[[") {
        t.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let mut depth = 1;
        let mut end = None;
        let mut j = 0;
        while j < after.len() {
            if after[j..].starts_with("[[") {
                depth += 1;
                j += 2;
            } else if after[j..].starts_with("]]") {
                depth -= 1;
                if depth == 0 {
                    end = Some(j);
                    break;
                }
                j += 2;
            } else {
                j += after[j..].chars().next().unwrap().len_utf8();
            }
        }
        let Some(end) = end else { break };
        let inner = &after[..end];
        let target = inner.split('|').next().unwrap_or("");
        if !target.contains(':') {
            t.push_str(inner.rsplit('|').next().unwrap_or(""));
        }
        rest = &after[end + 2..];
    }
    t.push_str(rest);
    let mut paragraphs = Vec::new();
    for line in t.lines() {
        let mut line = line.trim();
        if line.starts_with('|') || line.starts_with('!') || line.starts_with("__") {
            continue;
        }
        line = line
            .trim_start_matches(['*', '#', ':', ';', '='])
            .trim_end_matches('=');
        let mut p = String::with_capacity(line.len());
        let mut in_tag = false;
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '<' => in_tag = true,
                '>' if in_tag => in_tag = false,
                _ if in_tag => {}
                '\'' if chars.peek() == Some(&'\'') => {
                    while chars.peek() == Some(&'\'') {
                        chars.next();
                    }
                }
                '[' | ']' | '{' | '}' => {}
                _ => p.push(c),
            }
        }
        let p: Vec<&str> = p
            .split_whitespace()
            .filter(|w| !w.starts_with("http"))
            .collect();
        let p = p.join(" ").replace("&nbsp;", " ");
        // Chinese conversion markup, -{...}-.
        let p = p.replace("-{", "").replace("}-", "");
        if p.chars().filter(|c| c.is_alphabetic()).count() >= 20 {
            paragraphs.push(p);
        }
    }
    paragraphs
}

/// An encoding_rs encoder's verdict on characters, cached.
struct Fitter {
    encoding: &'static Encoding,
    cache: HashMap<char, bool>,
}

impl Fitter {
    fn new(encoding: &'static Encoding) -> Fitter {
        Fitter {
            encoding,
            cache: HashMap::new(),
        }
    }

    fn ok(&mut self, c: char) -> bool {
        let e = self.encoding;
        *self.cache.entry(c).or_insert_with(|| {
            let mut encoder = e.new_encoder();
            let mut buf = [0u8; 16];
            let (r, _, _) =
                encoder.encode_from_utf8_without_replacement(&c.to_string(), &mut buf, true);
            r == EncoderResult::InputEmpty
        })
    }

    /// `text` with every character the encoding cannot encode written the
    /// way a writer in that encoding would have: decomposed, with the base
    /// and first mark recomposed where the encoding has that (as
    /// windows-1258 writes Vietnamese), or dropped. bench-corpus's `fit`.
    fn fit(&mut self, text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        for c in text.chars() {
            if self.ok(c) {
                out.push(c);
                continue;
            }
            let d: Vec<char> = c.to_string().nfd().collect();
            let mut used = None;
            for j in 1..d.len() {
                let pair: String = [d[0], d[j]].iter().collect::<String>().nfc().collect();
                let mut it = pair.chars();
                if let (Some(p), None) = (it.next(), it.next()) {
                    if self.ok(p) {
                        out.push(p);
                        used = Some(j);
                        break;
                    }
                }
            }
            for (j, &m) in d.iter().enumerate() {
                if (used.is_none() || (j != 0 && Some(j) != used)) && self.ok(m) {
                    out.push(m);
                }
            }
        }
        out
    }
}

/// `chars` encoded, stopping before the first character that would take
/// the output past `limit` bytes, with ISO-2022-JP's closing escape.
fn encode_prefix(e: &'static Encoding, chars: &[char], limit: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut encoder = e.new_encoder();
    let reserve = if e == encoding_rs::ISO_2022_JP { 3 } else { 0 };
    let mut buf = [0u8; 16];
    let mut s = [0u8; 4];
    for &c in chars {
        let (r, _, n) =
            encoder.encode_from_utf8_without_replacement(c.encode_utf8(&mut s), &mut buf, false);
        assert_eq!(
            r,
            EncoderResult::InputEmpty,
            "{} cannot encode {c:?}",
            e.name()
        );
        if out.len() + n + reserve > limit {
            break;
        }
        out.extend_from_slice(&buf[..n]);
    }
    let (_, _, n) = encoder.encode_from_utf8_without_replacement("", &mut buf, true);
    out.extend_from_slice(&buf[..n]);
    out
}

/// The whole of `chars` encoded, and the byte offset after each character
/// (an ISO-2022-JP prefix cut there lacks the closing escape, which the
/// standard's decoder does not need).
fn encode_all(e: &'static Encoding, chars: &[char]) -> (Vec<u8>, Vec<usize>) {
    let mut out = Vec::new();
    let mut ends = Vec::with_capacity(chars.len());
    let mut encoder = e.new_encoder();
    let mut buf = [0u8; 16];
    let mut s = [0u8; 4];
    for &c in chars {
        let (r, _, n) =
            encoder.encode_from_utf8_without_replacement(c.encode_utf8(&mut s), &mut buf, false);
        assert_eq!(r, EncoderResult::InputEmpty);
        out.extend_from_slice(&buf[..n]);
        ends.push(out.len());
    }
    let (_, _, n) = encoder.encode_from_utf8_without_replacement("", &mut buf, true);
    out.extend_from_slice(&buf[..n]);
    if let Some(last) = ends.last_mut() {
        *last = out.len();
    }
    (out, ends)
}

/// A deterministic xorshift generator.
struct Rng(u64);

impl Rng {
    fn new(seed: &str) -> Rng {
        // FNV-1a of the seed, never zero.
        let mut h: u64 = 0xcbf29ce484222325;
        for b in seed.bytes() {
            h = (h ^ b as u64).wrapping_mul(0x100000001b3);
        }
        Rng(h | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

/// The text of an article as ISO-8859-8 carries it: visual order, each
/// line reversed.
fn visual(text: &str) -> String {
    text.lines()
        .map(|l| l.chars().rev().collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

fn article(lang: &str, revid: u64) -> String {
    let path = format!("{OUT}/wiki/{lang}/{revid}.wiki");
    let wiki = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| fail(&format!("{path}: {e} (run `just detect-corpus`)")));
    let mut text = prose(&wiki).join("\n");
    if text.len() > MAX_ARTICLE {
        let mut end = MAX_ARTICLE;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

fn header(out: &mut Vec<u8>, kind: char, lang: &str, enc: &str, length: usize, cuts: &[usize]) {
    let mut h = format!("{kind} {lang} {enc} {length} {}", cuts.len());
    for c in cuts {
        write!(h, " {c}").unwrap();
    }
    h.push('\n');
    out.extend_from_slice(h.as_bytes());
}

fn build() {
    let groups: HashMap<String, Vec<String>> = groups().into_iter().collect();
    std::fs::create_dir_all(format!("{OUT}/train")).unwrap();
    let mut samples = Vec::new();
    let (mut windows, mut docs) = (0usize, 0usize);
    for src in sources() {
        let encs = groups
            .get(&src.group)
            .unwrap_or_else(|| fail(&format!("{}: no group {}", src.lang, src.group)));
        let encodings: Vec<&'static Encoding> = encs
            .iter()
            .map(|n| Encoding::for_label(n.as_bytes()).unwrap_or_else(|| fail(n)))
            .collect();
        let mut train_fitter = Fitter::new(encodings[0]);
        let mut train = String::new();
        let mut fitters: Vec<Fitter> = encodings.iter().map(|&e| Fitter::new(e)).collect();
        for (i, &revid) in src.revids.iter().enumerate() {
            let text = article(&src.lang, revid);
            if i % 3 != 2 {
                train.push_str(&train_fitter.fit(&text));
                train.push('\n');
                continue;
            }
            for (k, fitter) in fitters.iter_mut().enumerate() {
                let name = &encs[k];
                let e = fitter.encoding;
                let mut fitted = fitter.fit(&text);
                if name == "ISO-8859-8" {
                    fitted = visual(&fitted);
                }
                let chars: Vec<char> = fitted.chars().collect();
                if chars.is_empty() {
                    continue;
                }
                // Windows: a run of characters from a random start, of
                // at most the size in bytes, with a byte outside ASCII.
                for &size in WINDOWS {
                    let mut rng = Rng::new(&format!("{} {name} {revid} {size}", src.lang));
                    let mut got = 0;
                    for _ in 0..PER_ARTICLE * 20 {
                        if got == PER_ARTICLE {
                            break;
                        }
                        let start = (rng.next() % chars.len() as u64) as usize;
                        let bytes = encode_prefix(e, &chars[start..], size);
                        if bytes.len() < size / 2 || !bytes.iter().any(|&b| b >= 0x80 || b == 0x1b)
                        {
                            continue;
                        }
                        header(&mut samples, 'w', &src.lang, name, size, &[bytes.len()]);
                        samples.extend_from_slice(&bytes);
                        samples.push(b'\n');
                        got += 1;
                        windows += 1;
                    }
                }
                // The whole article, cut at each size it reaches.
                let (bytes, ends) = encode_all(e, &chars);
                let mut cuts = Vec::new();
                for &c in CUTS.iter().filter(|&&c| c < bytes.len()) {
                    let n = ends.partition_point(|&end| end <= c);
                    if n > 0 && cuts.last() != Some(&ends[n - 1]) {
                        cuts.push(ends[n - 1]);
                    }
                }
                cuts.push(bytes.len());
                header(&mut samples, 'd', &src.lang, name, bytes.len(), &cuts);
                samples.extend_from_slice(&bytes);
                samples.push(b'\n');
                docs += 1;
            }
        }
        std::fs::write(format!("{OUT}/train/{}.txt", src.lang), train).unwrap();
    }
    std::fs::write(format!("{OUT}/samples.txt"), samples).unwrap();
    eprintln!("detect-corpus: {windows} windows, {docs} articles");
}

/// Han characters of a Chinese article only Big5 can encode, as GBK writes
/// them outside GB2312 (traditional), and only GBK can (simplified).
fn zh_script(text: &str) -> Option<&'static str> {
    let (mut trad, mut simp) = (0usize, 0usize);
    let mut buf = [0u8; 8];
    for c in text
        .chars()
        .filter(|&c| ('\u{4E00}'..='\u{9FFF}').contains(&c))
    {
        let s = c.to_string();
        let (r, _, n) = encoding_rs::BIG5
            .new_encoder()
            .encode_from_utf8_without_replacement(&s, &mut buf, true);
        if r != EncoderResult::InputEmpty {
            simp += 1;
            continue;
        }
        let _ = n;
        let (_, _, n) = encoding_rs::GBK
            .new_encoder()
            .encode_from_utf8_without_replacement(&s, &mut buf, true);
        let gb2312 = n == 2 && (0xA1..=0xF7).contains(&buf[0]) && buf[1] >= 0xA1;
        if !gb2312 {
            trad += 1;
        }
    }
    if simp >= 50 && simp >= 20 * trad {
        Some("hans")
    } else if trad >= 50 && trad >= 20 * simp {
        Some("hant")
    } else {
        None
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out = std::io::stdout();
    let mut out = out.lock();
    match args.get(1).map(String::as_str) {
        Some("select") if args.len() == 3 => {
            let v = json(&args[2]);
            for page in v["query"]["pages"].as_array().into_iter().flatten() {
                if page["length"].as_u64().unwrap_or(0) >= 6000 && page["contentmodel"] == "wikitext" {
                    writeln!(out, "{}", page["lastrevid"]).unwrap();
                }
            }
        }
        Some("zh-split") if args.len() >= 3 => {
            for path in &args[2..] {
                for (id, wiki) in revisions(&json(path)) {
                    if let Some(s) = zh_script(&prose(&wiki).join("\n")) {
                        writeln!(out, "{s} {id}").unwrap();
                    }
                }
            }
        }
        Some("unpack") if args.len() == 4 => {
            std::fs::create_dir_all(&args[3]).unwrap();
            for (id, wiki) in revisions(&json(&args[2])) {
                std::fs::write(format!("{}/{id}.wiki", args[3]), wiki).unwrap();
            }
        }
        Some("build") => build(),
        _ => fail("usage: detect-corpus select INFO.json | zh-split CONTENT.json... | unpack CONTENT.json DIR | build"),
    }
}
