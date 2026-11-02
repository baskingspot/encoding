//! `just bench-corpus`'s generator (bench/README.md): every encoding in
//! bench/encodings.tsv gets realistic and synthetic inputs at each size,
//! encoded by encoding_rs (the standard's encoders), or for IBM437 and
//! IBM850 by Unicode's vendor tables in vendor/unicode/.
//!
//! Run from the repository root after the sources are fetched into
//! bench/corpus-gen/sources/. For each encoding it writes
//! bench/corpus-gen/<name>/<shape>-<size>.bin, the input in that encoding,
//! and <shape>-<size>.utf8, the same text as the standard decodes it, which
//! the encode rows read. Everything is deterministic, so
//! bench/corpus/SHA256SUMS pins the output.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::Path;

use encoding_rs::{CoderResult, EncoderResult, Encoding};
use unicode_normalization::UnicodeNormalization;

const OUT: &str = "bench/corpus-gen";
const SIZES: &[usize] = &[16, 64, 256, 4096, 65536, 1048576];

/// Shapes, and whether each goes up to the largest size.
const SHAPES: &[(&str, bool)] = &[
    ("web", true),
    ("mail", false),
    ("subtitles", false),
    ("csv", false),
    ("ascii", true),
    ("nonascii", true),
    ("mixed", true),
    ("invalid", false),
];

fn fail(message: &str) -> ! {
    eprintln!("bench-corpus: {message}");
    std::process::exit(1);
}

/// An encoding's encoder and decoder: encoding_rs's, UTF-16's (which
/// encoding_rs decodes but does not encode), or a vendor table's.
enum Codec {
    Rs(&'static Encoding),
    Utf16 {
        big: bool,
    },
    Table {
        decode: Vec<char>,
        encode: HashMap<char, u8>,
    },
}

impl Codec {
    fn new(name: &str) -> Codec {
        match name {
            "UTF-16LE" => Codec::Utf16 { big: false },
            "UTF-16BE" => Codec::Utf16 { big: true },
            "IBM437" | "IBM850" => {
                let file = format!("vendor/unicode/CP{}.TXT", &name[3..]);
                let text = std::fs::read_to_string(&file)
                    .unwrap_or_else(|e| fail(&format!("{file}: {e}")));
                let mut decode = vec!['\u{FFFD}'; 256];
                for line in text.lines().filter(|l| l.starts_with("0x")) {
                    let mut fields = line.split('\t');
                    let byte = u32::from_str_radix(&fields.next().unwrap()[2..], 16).unwrap();
                    let cp = u32::from_str_radix(&fields.next().unwrap()[2..], 16).unwrap();
                    decode[byte as usize] = char::from_u32(cp).unwrap();
                }
                let encode = decode
                    .iter()
                    .enumerate()
                    .map(|(b, &c)| (c, b as u8))
                    .collect();
                Codec::Table { decode, encode }
            }
            _ => Codec::Rs(
                Encoding::for_label(name.as_bytes())
                    .unwrap_or_else(|| fail(&format!("encoding_rs has no {name}"))),
            ),
        }
    }

    fn can_encode(&self, c: char) -> bool {
        match self {
            Codec::Rs(e) => {
                let mut encoder = e.new_encoder();
                let mut buf = [0u8; 16];
                let s = c.to_string();
                let (r, _, _) = encoder.encode_from_utf8_without_replacement(&s, &mut buf, true);
                r == EncoderResult::InputEmpty
            }
            Codec::Utf16 { .. } => true,
            Codec::Table { encode, .. } => encode.contains_key(&c),
        }
    }

    /// The longest prefix of `text` whose encoding takes at most `limit`
    /// bytes, encoded, with a stateful encoder's closing escape.
    fn encode_prefix(&self, text: &str, limit: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(limit);
        match self {
            Codec::Rs(e) => {
                let mut encoder = e.new_encoder();
                // ISO-2022-JP's return to ASCII at the end.
                let reserve = if *e == encoding_rs::ISO_2022_JP { 3 } else { 0 };
                let mut buf = [0u8; 16];
                let mut s = [0u8; 4];
                for c in text.chars() {
                    let (r, _, n) = encoder.encode_from_utf8_without_replacement(
                        c.encode_utf8(&mut s),
                        &mut buf,
                        false,
                    );
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
            }
            Codec::Utf16 { big } => {
                let mut units = [0u16; 2];
                for c in text.chars() {
                    let u = c.encode_utf16(&mut units);
                    if out.len() + 2 * u.len() > limit {
                        break;
                    }
                    for &unit in u.iter() {
                        out.extend_from_slice(&if *big {
                            unit.to_be_bytes()
                        } else {
                            unit.to_le_bytes()
                        });
                    }
                }
            }
            Codec::Table { encode, .. } => {
                for c in text.chars().take(limit) {
                    out.push(encode[&c]);
                }
            }
        }
        out
    }

    /// The standard's decode without BOM handling, with replacement.
    fn decode(&self, bytes: &[u8]) -> String {
        match self {
            Codec::Rs(e) => e.decode_without_bom_handling(bytes).0.into_owned(),
            Codec::Utf16 { big } => {
                let e = if *big {
                    encoding_rs::UTF_16BE
                } else {
                    encoding_rs::UTF_16LE
                };
                let mut decoder = e.new_decoder_without_bom_handling();
                let mut s = String::with_capacity(bytes.len() * 3 / 2 + 16);
                let (r, _, _) = decoder.decode_to_string(bytes, &mut s, true);
                assert_eq!(r, CoderResult::InputEmpty);
                s
            }
            Codec::Table { decode, .. } => bytes.iter().map(|&b| decode[b as usize]).collect(),
        }
    }
}

/// The prose of a page of wikitext: no templates, tables, references,
/// tags, or link targets; one paragraph per line.
fn prose(wikitext: &str) -> Vec<String> {
    let mut s = String::with_capacity(wikitext.len());
    let b = wikitext.as_bytes();
    let mut i = 0;
    // Removes nested {{ }} and {| |} blocks, comments, and <ref> elements.
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
    // Links: [[target|text]] to text, [[target]] to target, and namespaced
    // ones ([[File:...]], [[Category:...]]) removed with what they nest.
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
        // External links' URLs: "[http://x text]" left "http://x text".
        let p: Vec<&str> = p
            .split_whitespace()
            .filter(|w| !w.starts_with("http"))
            .collect();
        let p = p.join(" ").replace("&nbsp;", " ");
        if p.chars().filter(|c| c.is_alphabetic()).count() >= 20 {
            paragraphs.push(p);
        }
    }
    paragraphs
}

/// `text` with every character the codec cannot encode replaced the way a
/// writer in that encoding would have written it: decomposed, with the
/// base and first mark recomposed where the encoding has that (as
/// windows-1258 writes Vietnamese), or dropped.
fn fit(codec: &Codec, cache: &mut HashMap<char, bool>, text: &str) -> String {
    let mut ok = |c: char| *cache.entry(c).or_insert_with(|| codec.can_encode(c));
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if ok(c) {
            out.push(c);
            continue;
        }
        let d: Vec<char> = c.to_string().nfd().collect();
        // The base with one of its marks, where the encoding has that.
        let mut used = None;
        for j in 1..d.len() {
            let pair: String = [d[0], d[j]].iter().collect::<String>().nfc().collect();
            let mut it = pair.chars();
            if let (Some(p), None) = (it.next(), it.next()) {
                if ok(p) {
                    out.push(p);
                    used = Some(j);
                    break;
                }
            }
        }
        for (j, &m) in d.iter().enumerate() {
            if (used.is_none() || (j != 0 && Some(j) != used)) && ok(m) {
                out.push(m);
            }
        }
    }
    out
}

/// A deterministic xorshift generator.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The text's words, and whether spaces separate them; text without
/// spaces, as Chinese and Japanese are written, in runs of three
/// characters.
fn words(text: &str) -> (Vec<String>, bool) {
    let ws: Vec<String> = text.split_whitespace().map(String::from).collect();
    if ws.len() * 12 >= text.chars().count() {
        return (ws, true);
    }
    let chars: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    (chars.chunks(3).map(|c| c.iter().collect()).collect(), false)
}

/// Lines of at most `width` characters, broken at spaces, or anywhere in
/// text without them.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = String::new();
    let (ws, spaced) = words(text);
    for w in ws {
        if !line.is_empty() && line.chars().count() + w.chars().count() + 1 > width {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() && spaced {
            line.push(' ');
        }
        line.push_str(&w);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// Text of a shape at least `chars` characters long (four bytes of UTF-8
/// each at most), from the paragraphs,
/// which repeat as needed.
fn shape(
    kind: &str,
    name: &str,
    lang: &str,
    paragraphs: &[String],
    ascii: &[String],
    chars: usize,
) -> String {
    let mut s = String::new();
    let mut p = paragraphs.iter().cycle();
    let mut i = 0usize;
    match kind {
        "web" => {
            let title: String = paragraphs[0].chars().take(40).collect();
            write!(
                s,
                "<!DOCTYPE html>\n<html lang=\"{lang}\">\n<head>\n<meta charset=\"{name}\">\n<title>{}</title>\n\
                 <link rel=\"stylesheet\" href=\"/static/site.css\">\n<script src=\"/static/site.js\" defer></script>\n</head>\n\
                 <body class=\"article\">\n<header><nav><a href=\"/\">Home</a> | <a href=\"/news/\">News</a> | \
                 <a href=\"/about/\">About</a></nav></header>\n<main id=\"content\">\n<h1>{}</h1>\n",
                escape_html(&title),
                escape_html(&title)
            )
            .unwrap();
            while s.len() < 4 * chars {
                if i % 5 == 4 {
                    let h: String = p.next().unwrap().chars().take(30).collect();
                    writeln!(s, "<h2 id=\"s{i}\">{}</h2>", escape_html(&h)).unwrap();
                }
                write!(s, "<p class=\"p{}\">", i % 3).unwrap();
                for (j, w) in p.next().unwrap().split(' ').enumerate() {
                    if j > 0 {
                        s.push(' ');
                    }
                    if j % 11 == 5 {
                        write!(
                            s,
                            "<a href=\"/wiki/{i}-{j}\" title=\"{}\">{}</a>",
                            escape_html(w),
                            escape_html(w)
                        )
                        .unwrap();
                    } else {
                        s.push_str(&escape_html(w));
                    }
                }
                s.push_str("</p>\n");
                i += 1;
            }
            s.push_str("</main>\n<footer><p>&copy; 2026</p></footer>\n</body>\n</html>\n");
        }
        "mail" => {
            while s.len() < 4 * chars {
                let subject: String = p.next().unwrap().chars().take(50).collect();
                write!(
                    s,
                    "From user{i}@example.org Mon Nov  2 10:{:02}:00 2026\r\nFrom: User {i} <user{i}@example.org>\r\n\
                     To: list@example.org\r\nSubject: {subject}\r\nDate: Mon, 2 Nov 2026 10:{:02}:00 +0000\r\n\
                     Message-ID: <{i}.{lang}@example.org>\r\nMIME-Version: 1.0\r\n\
                     Content-Type: text/plain; charset={name}\r\nContent-Transfer-Encoding: 8bit\r\n\r\n",
                    i % 60,
                    i % 60
                )
                .unwrap();
                for line in wrap(p.next().unwrap(), 72) {
                    write!(s, "{line}\r\n").unwrap();
                }
                write!(s, "\r\nOn Sunday, User {} wrote:\r\n", i + 1).unwrap();
                for line in wrap(p.next().unwrap(), 70) {
                    write!(s, "> {line}\r\n").unwrap();
                }
                write!(s, "\r\n-- \r\nUser {i}\r\n\r\n").unwrap();
                i += 1;
            }
        }
        "subtitles" => {
            let mut cue = 1;
            while s.len() < 4 * chars {
                for pair in wrap(p.next().unwrap(), 42).chunks(2) {
                    let t = cue * 3;
                    write!(
                        s,
                        "{cue}\r\n{:02}:{:02}:{:02},{:03} --> {:02}:{:02}:{:02},{:03}\r\n{}\r\n\r\n",
                        t / 3600,
                        t / 60 % 60,
                        t % 60,
                        cue * 37 % 1000,
                        (t + 2) / 3600,
                        (t + 2) / 60 % 60,
                        (t + 2) % 60,
                        cue * 53 % 1000,
                        pair.join("\r\n")
                    )
                    .unwrap();
                    cue += 1;
                }
            }
        }
        "csv" => {
            s.push_str("id,date,name,city,amount,note\r\n");
            while s.len() < 4 * chars {
                let ws = words(p.next().unwrap()).0;
                let note: String = p.next().unwrap().chars().take(80).collect();
                write!(
                    s,
                    "{i},2026-{:02}-{:02},{} {},{},{}.{:02},\"{}\"\r\n",
                    i % 12 + 1,
                    i % 28 + 1,
                    ws[0].replace([',', '"'], ""),
                    ws.get(1).map_or("", |w| w.as_str()).replace([',', '"'], ""),
                    ws.get(2).map_or("", |w| w.as_str()).replace([',', '"'], ""),
                    i * 7919 % 100000,
                    i % 100,
                    note.replace('"', "\"\"")
                )
                .unwrap();
                i += 1;
            }
        }
        "ascii" => {
            let mut a = ascii.iter().cycle();
            while s.len() < chars {
                s.push_str(a.next().unwrap());
                s.push('\n');
            }
        }
        "nonascii" | "mixed" => {
            let non: Vec<char> = paragraphs
                .iter()
                .flat_map(|p| p.chars())
                .filter(|c| !c.is_ascii())
                .collect();
            if non.is_empty() {
                fail(&format!("{name}: no non-ASCII text in {lang}"));
            }
            let a: Vec<char> = ascii.iter().flat_map(|p| p.chars()).collect();
            let mut k = 0;
            while s.len() < 4 * chars {
                if kind == "mixed" {
                    s.push(a[k % a.len()]);
                }
                s.push(non[k % non.len()]);
                k += 1;
            }
        }
        _ => unreachable!(),
    }
    s
}

fn main() {
    let list = std::fs::read_to_string("bench/encodings.tsv").unwrap_or_else(|e| {
        fail(&format!(
            "bench/encodings.tsv: {e} (run from the repository root)"
        ))
    });
    let source = |lang: &str| {
        let path = format!("{OUT}/sources/{lang}");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| fail(&format!("{path}: {e} (run `just bench-corpus`)")));
        prose(&text)
    };
    let english = source("en");
    let ascii: Vec<String> = english
        .iter()
        .map(|p| p.chars().filter(|c| c.is_ascii()).collect::<String>())
        .collect();
    for line in list
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
    {
        let mut fields = line.split('\t');
        let (name, lang) = (fields.next().unwrap(), fields.next().unwrap());
        let codec = Codec::new(name);
        let mut cache = HashMap::new();
        let paragraphs: Vec<String> = if name == "x-user-defined" {
            // Its upper half decodes to U+F780..U+F7FF; no language writes it.
            (0..64)
                .map(|i| {
                    (0..80)
                        .map(|j| char::from_u32(0xF780 + (i * 80 + j) * 37 % 128).unwrap())
                        .collect()
                })
                .collect()
        } else {
            source(lang)
                .iter()
                .map(|p| fit(&codec, &mut cache, p))
                .filter(|p| p.chars().count() >= 20)
                .collect()
        };
        let dir = Path::new(OUT).join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let mut rng = Rng(name.bytes().fold(0x9E3779B97F4A7C15u64, |h, b| {
            (h ^ b as u64).wrapping_mul(0x100000001B3)
        }));
        for &(kind, large) in SHAPES {
            let max = if large {
                SIZES[SIZES.len() - 1]
            } else {
                SIZES[SIZES.len() - 2]
            };
            // Text for the largest size; each smaller size is a prefix.
            let text = if kind == "invalid" {
                String::new()
            } else {
                shape(kind, name, lang, &paragraphs, &ascii, max)
            };
            for &size in SIZES.iter().filter(|&&n| n <= max) {
                let bytes = if kind == "invalid" {
                    (0..size).map(|_| rng.next() as u8).collect()
                } else {
                    codec.encode_prefix(&text, size)
                };
                let stem = dir.join(format!("{kind}-{size}"));
                std::fs::write(stem.with_extension("bin"), &bytes).unwrap();
                std::fs::write(stem.with_extension("utf8"), codec.decode(&bytes)).unwrap();
            }
        }
        eprintln!("bench-corpus: {name} ({lang})");
    }
}
