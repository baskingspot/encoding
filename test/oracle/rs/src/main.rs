//! The encoding_rs oracle: reads a batch of requests on stdin and answers
//! each with what encoding_rs does, for test/oracle/compare.zig (`just
//! oracle`), which holds this package's results against them.
//!
//! Every number is little endian. A request is
//!
//!     u8 op, u8 flags, u8 name length, name, u32 input length, input
//!
//! and a response is
//!
//!     u32 output length, output, u32 event count,
//!     events of (u64 input offset, u64 output offset, u32 code point)
//!
//! The ops:
//!
//!   1  decode to UTF-8      flags: bit 0 fatal, bits 1-2 BOM handling
//!   2  decode to UTF-16       (0 sniff, 1 remove, 2 keep); output is
//!                             UTF-16 code units, little endian
//!   3  encode from UTF-8    flags: bit 0 fatal; ill-formed input is read
//!   4  encode from UTF-16     with U+FFFD per maximal subpart (UTF-8) or
//!                             per unpaired surrogate (UTF-16, little endian)
//!   5  label                the input is a label; the output is the name
//!                             of its encoding, or empty
//!
//! A fatal decode goes on after each error and records an event at the
//! input offset where the malformed sequence ends (encoding_rs's read
//! minus the bytes it read after it) and the output written before it; a
//! fatal encode records each unmappable character the same way. The
//! oracle reads all of stdin before it writes.

use encoding_rs::{CoderResult, DecoderResult, EncoderResult, Encoding};
use std::io::{Read, Write};

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

struct Out {
    bytes: Vec<u8>,
    events: Vec<(u64, u64, u32)>,
}

fn decoder(enc: &'static Encoding, bom: u8) -> encoding_rs::Decoder {
    match bom {
        0 => enc.new_decoder(),
        1 => enc.new_decoder_with_bom_removal(),
        _ => enc.new_decoder_without_bom_handling(),
    }
}

fn decode_utf8(enc: &'static Encoding, flags: u8, input: &[u8]) -> Out {
    let mut d = decoder(enc, flags >> 1);
    let mut events = Vec::new();
    let mut out = vec![0u8; d.max_utf8_buffer_length(input.len()).unwrap() + 16];
    let mut read = 0;
    let mut written = 0;
    if flags & 1 == 0 {
        let (r, n, w, _) = d.decode_to_utf8(input, &mut out, true);
        assert!(matches!(r, CoderResult::InputEmpty));
        read += n;
        written += w;
    } else {
        loop {
            let (r, n, w) =
                d.decode_to_utf8_without_replacement(&input[read..], &mut out[written..], true);
            read += n;
            written += w;
            match r {
                DecoderResult::InputEmpty => break,
                DecoderResult::OutputFull => panic!("output full"),
                DecoderResult::Malformed(_, after) => {
                    events.push(((read - after as usize) as u64, written as u64, 0))
                }
            }
        }
    }
    assert_eq!(read, input.len());
    out.truncate(written);
    Out { bytes: out, events }
}

fn decode_utf16(enc: &'static Encoding, flags: u8, input: &[u8]) -> Out {
    let mut d = decoder(enc, flags >> 1);
    let mut events = Vec::new();
    let mut out = vec![0u16; d.max_utf16_buffer_length(input.len()).unwrap() + 16];
    let mut read = 0;
    let mut written = 0;
    if flags & 1 == 0 {
        let (r, n, w, _) = d.decode_to_utf16(input, &mut out, true);
        assert!(matches!(r, CoderResult::InputEmpty));
        read += n;
        written += w;
    } else {
        loop {
            let (r, n, w) =
                d.decode_to_utf16_without_replacement(&input[read..], &mut out[written..], true);
            read += n;
            written += w;
            match r {
                DecoderResult::InputEmpty => break,
                DecoderResult::OutputFull => panic!("output full"),
                DecoderResult::Malformed(_, after) => {
                    events.push(((read - after as usize) as u64, written as u64, 0))
                }
            }
        }
    }
    assert_eq!(read, input.len());
    let bytes = out[..written]
        .iter()
        .flat_map(|u| u.to_le_bytes())
        .collect();
    Out { bytes, events }
}

enum Text<'a> {
    Utf8(&'a str),
    Utf16(&'a [u16]),
}

fn encode(enc: &'static Encoding, flags: u8, text: Text) -> Out {
    let mut e = enc.new_encoder();
    let len = match text {
        Text::Utf8(s) => s.len(),
        Text::Utf16(u) => u.len(),
    };
    let mut out = vec![0u8; 10 * len + 64];
    let mut events = Vec::new();
    let mut read = 0;
    let mut written = 0;
    loop {
        if flags & 1 == 0 {
            let (r, n, w, _) = match text {
                Text::Utf8(s) => e.encode_from_utf8(s, &mut out, true),
                Text::Utf16(u) => e.encode_from_utf16(u, &mut out, true),
            };
            assert!(matches!(r, CoderResult::InputEmpty) && n == len);
            written = w;
            break;
        }
        let (r, n, w) = match text {
            Text::Utf8(s) => {
                e.encode_from_utf8_without_replacement(&s[read..], &mut out[written..], true)
            }
            Text::Utf16(u) => {
                e.encode_from_utf16_without_replacement(&u[read..], &mut out[written..], true)
            }
        };
        read += n;
        written += w;
        match r {
            EncoderResult::InputEmpty => break,
            EncoderResult::OutputFull => panic!("output full"),
            EncoderResult::Unmappable(c) => events.push((read as u64, written as u64, c as u32)),
        }
    }
    out.truncate(written);
    Out { bytes: out, events }
}

fn main() {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).unwrap();
    let mut output = Vec::new();
    let mut at = 0;
    while at < input.len() {
        let op = input[at];
        let flags = input[at + 1];
        let name_len = input[at + 2] as usize;
        let name = &input[at + 3..at + 3 + name_len];
        at += 3 + name_len;
        let len = le_u32(&input[at..]) as usize;
        let data = &input[at + 4..at + 4 + len];
        at += 4 + len;
        let out = if op == 5 {
            let name = Encoding::for_label(data).map_or("", |e| e.name());
            Out {
                bytes: name.as_bytes().to_vec(),
                events: Vec::new(),
            }
        } else {
            // Every name is also a label.
            let enc = Encoding::for_label(name).unwrap();
            match op {
                1 => decode_utf8(enc, flags, data),
                2 => decode_utf16(enc, flags, data),
                3 => encode(enc, flags, Text::Utf8(&String::from_utf8_lossy(data))),
                4 => {
                    let units: Vec<u16> = data
                        .chunks_exact(2)
                        .map(|c| u16::from_le_bytes([c[0], c[1]]))
                        .collect();
                    encode(enc, flags, Text::Utf16(&units))
                }
                _ => panic!("unknown op {op}"),
            }
        };
        output.extend_from_slice(&(out.bytes.len() as u32).to_le_bytes());
        output.extend_from_slice(&out.bytes);
        output.extend_from_slice(&(out.events.len() as u32).to_le_bytes());
        for (a, b, c) in out.events {
            output.extend_from_slice(&a.to_le_bytes());
            output.extend_from_slice(&b.to_le_bytes());
            output.extend_from_slice(&c.to_le_bytes());
        }
    }
    std::io::stdout().write_all(&output).unwrap();
}
