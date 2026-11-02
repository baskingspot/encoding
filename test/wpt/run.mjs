// The web-platform-tests harness (`just wpt`): runs the vendored encoding
// tests under Node against this package built as WebAssembly
// (test/wpt/wasm.zig, `zig build wpt-wasm`).
//
//   node test/wpt/run.mjs [--filter SUBSTRING] [--verbose] [--strict]
//
// Each test runs in a fresh VM context with testharness.js, a TextDecoder,
// TextEncoder, TextDecoderStream, and TextEncoderStream built on the
// package (installShim below), and for the HTML pages a small document:
// iframes whose documents are decoded by the package, forms whose
// submission and links whose URL queries are encoded by it in the page's
// encoding, as a browser does. test/wpt/expectations.txt lists the tests
// that cannot pass yet, and why; a failure it does not list fails the run,
// and with --strict so does a listed test that passes.

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const root = path.resolve(import.meta.dirname, "../..");
const wptRoot = path.join(root, "vendor/wpt");
const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const filter = option("--filter");
const verbose = flag("--verbose");
const strict = flag("--strict");

// The package.

const wasm = fs.readFileSync(path.join(root, "zig-out/bin/encoding.wasm"));
const X = (await WebAssembly.instantiate(wasm, {})).instance.exports;
const IN = Number(X.inPtr());
const OUT = Number(X.outPtr());
const IN_CAP = Number(X.inCap());
const OUT_CAP = Number(X.outCap());
const big = BigInt;
const bytesAt = (ptr, len) => new Uint8Array(X.memory.buffer, ptr, len);

// Handles the current test file has open, closed when it ends: a
// TextDecoder holds one between calls, and nothing tells it it is gone.
const open = { decoders: new Set(), encoders: new Set() };
function closeAll() {
  for (const h of open.decoders) X.decoderFree(h);
  for (const h of open.encoders) X.encoderFree(h);
  open.decoders.clear();
  open.encoders.clear();
}

const lib = {
  forLabel(label) {
    const b = Buffer.from(String(label), "utf8");
    if (b.length > IN_CAP) return -1;
    bytesAt(IN, b.length).set(b);
    return X.forLabel(big(b.length));
  },
  name(e) {
    const n = Number(X.name(e));
    return Buffer.from(bytesAt(OUT, n)).toString("latin1");
  },
  isImplemented: (e) => X.isImplemented(e) !== 0,
  outputEncoding: (e) => X.outputEncoding(e),
  decoderNew(e, fatal, bom) {
    if (!lib.isImplemented(e)) throw new Error(`${lib.name(e)} is not implemented yet`);
    const h = X.decoderNew(e, fatal ? 1 : 0, bom);
    if (h < 0) throw new Error("decoder pool exhausted");
    open.decoders.add(h);
    return h;
  },
  decoderFree(h) {
    X.decoderFree(h);
    open.decoders.delete(h);
  },
  // Decodes `bytes`; returns the text, and whether fatal mode hit an error.
  decode(h, bytes, last) {
    let text = "";
    let at = 0;
    const chunk = 1 << 20;
    do {
      const n = Math.min(chunk, bytes.length - at);
      const isLast = last && at + n === bytes.length;
      bytesAt(IN, n).set(bytes.subarray(at, at + n));
      const status = X.decode(h, big(n), isLast ? 1 : 0);
      const written = Number(X.lastWritten());
      text += Buffer.from(X.memory.buffer, OUT, written * 2).toString("utf16le");
      at += Number(X.lastRead());
      if (status === 2) return { text, error: true, rest: bytes.subarray(at) };
    } while (at < bytes.length);
    return { text, error: false };
  },
  encoderNew(e, fatal) {
    if (!lib.isImplemented(e)) throw new Error(`${lib.name(e)} is not implemented yet`);
    const h = X.encoderNew(e, fatal ? 1 : 0);
    if (h < 0) throw new Error("encoder pool exhausted");
    open.encoders.add(h);
    return h;
  },
  encoderFree(h) {
    X.encoderFree(h);
    open.encoders.delete(h);
  },
  // Encodes the UTF-16 units of `str` from `start`, with `room` bytes.
  encode(h, str, start, room, last) {
    const n = Math.min(str.length - start, IN_CAP / 2);
    const units = new Uint16Array(X.memory.buffer, IN, n);
    for (let i = 0; i < n; i++) units[i] = str.charCodeAt(start + i);
    const status = X.encode(h, big(n), big(Math.min(room, OUT_CAP)), last && start + n === str.length ? 1 : 0);
    const written = Number(X.lastWritten());
    return {
      status,
      read: Number(X.lastRead()),
      bytes: Uint8Array.from(bytesAt(OUT, written)),
      cp: X.lastCp(),
    };
  },
};

// Encodes `str` in `e`'s output encoding as a URL or a form does: each byte
// outside the percent-encode set as is, the rest %XX, a space as + when
// `spaceAsPlus`, and an unmappable character as %26%23N%3B (the URL
// standard's "percent-encode after encoding").
function percentEncodeAfterEncoding(e, str, inSet, spaceAsPlus) {
  const h = lib.encoderNew(lib.outputEncoding(e), true);
  let out = "";
  let at = 0;
  try {
    for (;;) {
      const r = lib.encode(h, str, at, OUT_CAP, true);
      for (const b of r.bytes) {
        if (spaceAsPlus && b === 0x20) out += "+";
        else if (b < 0x20 || b > 0x7e || inSet(b)) out += "%" + b.toString(16).toUpperCase().padStart(2, "0");
        else out += String.fromCharCode(b);
      }
      at += r.read;
      if (r.status === 2) out += `%26%23${r.cp}%3B`;
      else if (at >= str.length) break;
    }
  } finally {
    lib.encoderFree(h);
  }
  return out;
}

const specialQuerySet = (b) => ' "#<>\''.includes(String.fromCharCode(b));
const formSet = (b) => !/[A-Za-z0-9*\-._]/.test(String.fromCharCode(b));

// The shim, compiled inside each test's context so the objects it makes
// belong to that context's realm.
function installShim(g, lib) {
  // WebIDL reads a detached buffer as no bytes.
  const toBytes = (input) => {
    if (ArrayBuffer.isView(input)) {
      return input.buffer.detached ? new Uint8Array(0) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    }
    const tag = Object.prototype.toString.call(input);
    if (tag === "[object ArrayBuffer]" || tag === "[object SharedArrayBuffer]") {
      return input.detached ? new Uint8Array(0) : new Uint8Array(input);
    }
    throw new TypeError("The provided value is not of type '(ArrayBuffer or ArrayBufferView)'");
  };
  const dict = (o) => {
    if (o === undefined || o === null) return {};
    if (typeof o !== "object" && typeof o !== "function") throw new TypeError("The options are not a dictionary");
    return o;
  };
  const isUtf = (name) => name === "UTF-8" || name === "UTF-16LE" || name === "UTF-16BE";

  class TextDecoder {
    #enc;
    #name;
    #fatal;
    #ignoreBOM;
    #h = -1;
    #noFlush = false;
    // What a fatal error left unread in a streaming call, which the
    // standard keeps in the decoder's I/O queue for the next call.
    #queued = new Uint8Array(0);
    constructor(label = "utf-8", options = undefined) {
      const o = dict(options);
      const fatal = Boolean(o.fatal);
      const ignoreBOM = Boolean(o.ignoreBOM);
      const e = lib.forLabel(String(label));
      if (e < 0 || lib.name(e) === "replacement") {
        throw new RangeError(`Failed to construct 'TextDecoder': The encoding label provided ('${label}') is invalid.`);
      }
      this.#enc = e;
      this.#name = lib.name(e);
      this.#fatal = fatal;
      this.#ignoreBOM = ignoreBOM;
    }
    get encoding() {
      return this.#name.toLowerCase();
    }
    get fatal() {
      return this.#fatal;
    }
    get ignoreBOM() {
      return this.#ignoreBOM;
    }
    decode(input = undefined, options = undefined) {
      if (input !== undefined) toBytes(input);
      const stream = Boolean(dict(options).stream);
      // Read after the options, whose getters may detach the buffer.
      const bytes = input === undefined ? new Uint8Array(0) : toBytes(input);
      if (!this.#noFlush || this.#h < 0) {
        if (this.#h >= 0) lib.decoderFree(this.#h);
        // The standard's TextDecoder removes the encoding's own byte
        // order mark unless told to ignore it, and sniffs no other.
        this.#h = lib.decoderNew(this.#enc, this.#fatal, this.#ignoreBOM || !isUtf(this.#name) ? 2 : 1);
        this.#queued = new Uint8Array(0);
      }
      this.#noFlush = stream;
      const queued = new Uint8Array(this.#queued.length + bytes.length);
      queued.set(this.#queued);
      queued.set(bytes, this.#queued.length);
      this.#queued = new Uint8Array(0);
      let r;
      try {
        r = lib.decode(this.#h, queued, !stream);
      } finally {
        if (!stream) {
          lib.decoderFree(this.#h);
          this.#h = -1;
        }
      }
      if (r.error) {
        if (stream) this.#queued = r.rest.slice();
        throw new TypeError("The encoded data was not valid.");
      }
      return r.text;
    }
  }

  const utf8 = lib.forLabel("utf-8");
  const encodeAll = (str) => {
    const h = lib.encoderNew(utf8, false);
    const parts = [];
    let at = 0;
    let total = 0;
    try {
      do {
        const r = lib.encode(h, str, at, 3 * str.length + 16, true);
        parts.push(r.bytes);
        total += r.bytes.length;
        at += r.read;
      } while (at < str.length);
    } finally {
      lib.encoderFree(h);
    }
    const out = new Uint8Array(total);
    let o = 0;
    for (const p of parts) {
      out.set(p, o);
      o += p.length;
    }
    return out;
  };

  class TextEncoder {
    get encoding() {
      return "utf-8";
    }
    encode(input = "") {
      return encodeAll(String(input));
    }
    encodeInto(source, destination) {
      if (!(destination instanceof Uint8Array) && Object.prototype.toString.call(destination) !== "[object Uint8Array]") {
        throw new TypeError("The destination is not a Uint8Array");
      }
      const str = String(source);
      const h = lib.encoderNew(utf8, false);
      try {
        const r = lib.encode(h, str, 0, destination.length, true);
        if (r.bytes.length) destination.set(r.bytes);
        return { read: r.read, written: r.bytes.length };
      } finally {
        lib.encoderFree(h);
      }
    }
  }

  class TextDecoderStream {
    #decoder;
    #transform;
    constructor(label = "utf-8", options = undefined) {
      const decoder = new TextDecoder(label, options);
      this.#decoder = decoder;
      this.#transform = new g.TransformStream({
        transform(chunk, controller) {
          const s = decoder.decode(toBytes(chunk), { stream: true });
          if (s) controller.enqueue(s);
        },
        flush(controller) {
          const s = decoder.decode();
          if (s) controller.enqueue(s);
        },
      });
    }
    get encoding() {
      return this.#decoder.encoding;
    }
    get fatal() {
      return this.#decoder.fatal;
    }
    get ignoreBOM() {
      return this.#decoder.ignoreBOM;
    }
    get readable() {
      return this.#transform.readable;
    }
    get writable() {
      return this.#transform.writable;
    }
  }

  class TextEncoderStream {
    #transform;
    constructor() {
      let pending = null;
      const encoder = new TextEncoder();
      this.#transform = new g.TransformStream({
        transform(chunk, controller) {
          let s = String(chunk);
          if (pending !== null) {
            s = pending + s;
            pending = null;
          }
          const last = s.charCodeAt(s.length - 1);
          if (last >= 0xd800 && last <= 0xdbff) {
            pending = s.slice(-1);
            s = s.slice(0, -1);
          }
          if (s) controller.enqueue(encoder.encode(s));
        },
        flush(controller) {
          if (pending !== null) controller.enqueue(encoder.encode("\ufffd"));
        },
      });
    }
    get encoding() {
      return "utf-8";
    }
    get readable() {
      return this.#transform.readable;
    }
    get writable() {
      return this.#transform.writable;
    }
  }

  g.TextDecoder = TextDecoder;
  g.TextEncoder = TextEncoder;
  g.TextDecoderStream = TextDecoderStream;
  g.TextEncoderStream = TextEncoderStream;
}

// Expectations.

function globToRegExp(glob) {
  const re = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\u0000").replace(/\*/g, "[^/]*").replace(/\?/g, "\\?");
  return new RegExp("^" + re.replace(/\u0000/g, ".*") + "$");
}

const expectations = fs
  .readFileSync(path.join(root, "test/wpt/expectations.txt"), "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith("#"))
  .map((line) => {
    const [spec, why = ""] = line.split(" -- ");
    const [kind, rest] = [spec.slice(0, 4), spec.slice(5).trim()];
    const [glob, subtest] = rest.split(" :: ").map((x) => x.trim());
    const match = !subtest
      ? () => true
      : subtest.startsWith("/") && subtest.endsWith("/")
        ? (name, message) => new RegExp(subtest.slice(1, -1)).test(`${name}\n${message}`)
        : (name) => name.includes(subtest);
    return { kind, glob, file: globToRegExp(glob), subtest, match, why: why.trim(), used: 0 };
  });

const skipOf = (file) => expectations.find((e) => e.kind === "SKIP" && e.file.test(file));
// The FAIL line for a failure: its subtest is a name substring, or a
// /regular expression/ tested on the name and the message.
const failOf = (file, name, message = "") =>
  expectations.find((e) => e.kind === "FAIL" && e.file.test(file) && e.match(name, message ?? ""));

// Running tests.

function readMeta(source) {
  const meta = { scripts: [], variants: [] };
  for (const m of source.matchAll(/^\/\/ META: (\w+)=(.*)$/gm)) {
    if (m[1] === "script") meta.scripts.push(m[2].trim());
    if (m[1] === "variant") meta.variants.push(m[2].trim());
  }
  return meta;
}

function resolveScript(fromFile, src) {
  if (src.startsWith("/")) return path.join(wptRoot, src);
  return path.join(path.dirname(fromFile), src);
}

function makeContext(search, isWindow) {
  const ctx = {
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    queueMicrotask,
    structuredClone,
    MessageChannel,
    MessagePort,
    ReadableStream,
    WritableStream,
    TransformStream,
    location: { search, href: "https://web-platform.test/" + search },
    GLOBAL: { isWindow: () => isWindow, isWorker: () => !isWindow, isShadowRealm: () => false },
  };
  ctx.self = ctx;
  vm.createContext(ctx);
  return ctx;
}

function load(ctx, file) {
  if (!fs.existsSync(file)) throw new Error(`missing script ${path.relative(root, file)}`);
  vm.runInContext(fs.readFileSync(file, "utf8"), ctx, { filename: file });
}

// An exception no test catches ends the test file with a harness error, as
// window.onerror does in a browser.
let uncaught = null;
process.on("uncaughtException", (err) => uncaught?.(err));
process.on("unhandledRejection", (err) => uncaught?.(err));

// Starts testharness.js in `ctx` and returns a promise of the results.
function startHarness(ctx, timeoutMs) {
  load(ctx, path.join(wptRoot, "resources/testharness.js"));
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve({ status: "TIMEOUT", tests: [] }), timeoutMs);
    uncaught = (err) => {
      clearTimeout(timer);
      resolve({ status: "ERROR", message: `uncaught ${err?.stack ?? err}`, tests: [] });
    };
    ctx.__done = (tests, status) => {
      clearTimeout(timer);
      resolve({ status: ["OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"][status.status], message: status.message, tests });
    };
    vm.runInContext(
      `add_completion_callback(function (tests, status) {
         __done(tests.map(function (t) {
           return { name: t.name, status: ["PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION_FAILED"][t.status], message: t.message };
         }), status);
       });`,
      ctx,
    );
  });
}

async function runScriptTest(file, variant) {
  const source = fs.readFileSync(file, "utf8");
  const meta = readMeta(source);
  const ctx = makeContext(variant, true);
  const done = startHarness(ctx, 60_000);
  ctx.__lib = lib;
  vm.runInContext(`(${installShim})(globalThis, __lib); delete globalThis.__lib;`, ctx);
  ctx.XMLHttpRequest = makeXhr(file);
  const { loadListeners } = makeDocument(ctx, file, { text: "", encoding: lib.forLabel("utf-8"), charset: "utf-8" });
  try {
    for (const s of meta.scripts) load(ctx, resolveScript(file, s));
    load(ctx, file);
    for (const fn of loadListeners) fn();
  } catch (err) {
    return { status: "ERROR", message: String(err), tests: [] };
  }
  return done;
}

// A minimal document for the encoding pages: what their scripts and
// decode-common.js, encode-form-common.js, and encode-href-common.js use.

// What a server would answer for `url`, relative to the test `fromFile`:
// files with their .headers, the few Python handlers the encoding tests
// call, and data: URLs.
function fetchResource(fromFile, url) {
  if (url.startsWith("data:")) {
    const comma = url.indexOf(",");
    const body = url.slice(comma + 1);
    const bytes = [];
    for (let i = 0; i < body.length; i++) {
      if (body[i] === "%" && /^[0-9a-f]{2}$/i.test(body.slice(i + 1, i + 3))) {
        bytes.push(parseInt(body.slice(i + 1, i + 3), 16));
        i += 2;
      } else bytes.push(...Buffer.from(body[i], "utf8"));
    }
    return { bytes: Uint8Array.from(bytes), type: url.slice(5, comma) || "text/plain;charset=US-ASCII" };
  }
  const u = new URL(url, "https://web-platform.test/" + path.relative(wptRoot, fromFile));
  const file = path.join(wptRoot, decodeURIComponent(u.pathname));
  const label = u.searchParams.get("label");
  switch (path.basename(file)) {
    case "single-byte-raw.py":
      return { bytes: Uint8Array.from({ length: 255 }, (_, i) => i), type: `text/plain;charset=${label}` };
    case "text-plain-charset.py":
      return { bytes: new Uint8Array(Buffer.from("hello encoding")), type: `text/plain;charset=${label}` };
    case "text-html-meta-charset.py":
      return { bytes: new Uint8Array(Buffer.from(`<meta charset="${label}">hello encoding`)), type: "text/html" };
  }
  if (file.endsWith(".py")) throw new Error(`no stand-in for the server handler ${path.relative(wptRoot, file)}`);
  const h = file + ".headers";
  const m = fs.existsSync(h) ? /^Content-Type:\s*(.*)$/im.exec(fs.readFileSync(h, "latin1")) : null;
  const type = m ? m[1].trim() : { ".html": "text/html", ".xml": "application/xml" }[path.extname(file)] ?? "text/plain";
  return { bytes: new Uint8Array(fs.readFileSync(file)), type };
}

function mimeCharset(type) {
  const m = /;\s*charset=("([^"]*)"|[^;]*)/i.exec(type ?? "");
  return m ? (m[2] ?? m[1]).trim() : null;
}

function metaCharset(bytes) {
  const head = Buffer.from(bytes.subarray(0, 1024)).toString("latin1");
  const m = /<meta\s+charset=(?:"([^"]*)"|'([^']*)'|([^\s>/;]+))/i.exec(head);
  return m ? (m[1] ?? m[2] ?? m[3]) : null;
}

// Decodes a document as a browser does: a byte order mark first, then the
// label from its Content-Type, then for HTML its meta tag, then the
// fallback. Returns the text and the encoding used.
function decodeDocument(res, fallback = "windows-1252") {
  const b = res.bytes;
  let e;
  if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) e = lib.forLabel("utf-8");
  else if (b[0] === 0xfe && b[1] === 0xff) e = lib.forLabel("utf-16be");
  else if (b[0] === 0xff && b[1] === 0xfe) e = lib.forLabel("utf-16le");
  else {
    e = lib.forLabel(mimeCharset(res.type) ?? "");
    if (e < 0 && /html/.test(res.type)) {
      // The prescan's meta label: UTF-16 means UTF-8, and x-user-defined
      // windows-1252.
      e = lib.forLabel(metaCharset(b) ?? "");
      if (e >= 0 && lib.name(e).startsWith("UTF-16")) e = lib.forLabel("utf-8");
      if (e >= 0 && lib.name(e) === "x-user-defined") e = lib.forLabel("windows-1252");
    }
    if (e < 0) e = lib.forLabel(/xml/.test(res.type) ? "utf-8" : fallback);
  }
  // A page in an encoding not implemented yet still loads, its scripts
  // being ASCII, so that its tests run and fail one by one.
  const h = lib.decoderNew(lib.isImplemented(e) ? e : lib.forLabel("windows-1252"), false, 0);
  try {
    const text = lib.decode(h, b, true).text;
    return { text: /html/.test(res.type) ? text.replace(/\r\n?/g, "\n") : text, encoding: e };
  } finally {
    lib.decoderFree(h);
  }
}

// XMLHttpRequest, for responseText: the response decoded with the label
// from overrideMimeType or the response's Content-Type, UTF-8 otherwise.
function makeXhr(fromFile) {
  return class XMLHttpRequest {
    #url;
    #override = null;
    responseText = "";
    status = 0;
    open(method, url) {
      this.#url = String(url);
    }
    overrideMimeType(type) {
      this.#override = String(type);
    }
    send() {
      setTimeout(() => {
        try {
          const res = fetchResource(fromFile, this.#url);
          const label = mimeCharset(this.#override) ?? mimeCharset(res.type);
          let e = label === null ? -1 : lib.forLabel(label);
          if (e < 0) e = lib.forLabel("utf-8");
          const h = lib.decoderNew(e, false, 0);
          try {
            this.responseText = lib.decode(h, res.bytes, true).text;
          } finally {
            lib.decoderFree(h);
          }
          this.status = 200;
          this.onload?.();
        } catch (err) {
          this.statusText = String(err.message);
          if (this.onerror) this.onerror();
          else throw err;
        }
      }, 0);
    }
  };
}

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot);/gi, (m, e) => {
    if (e[0] === "#") return String.fromCodePoint(e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
    return { amp: "&", lt: "<", gt: ">", quot: '"' }[e.toLowerCase()];
  });
}

function attr(tag, name) {
  const m = new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
  return m ? (m[1] ?? m[2] ?? m[3]) : null;
}

function makeDocument(ctx, file, page) {
  const elements = [];
  const byId = new Map();
  const loadListeners = [];
  const element = (tagName, props = {}) => {
    const el = {
      tagName: tagName.toUpperCase(),
      children: [],
      style: {},
      appendChild(child) {
        this.children.push(child);
        register(child);
        if (child.tagName === "IFRAME" && child.src) setTimeout(() => child.onload?.(), 0);
        return child;
      },
      removeChild(child) {
        const i = elements.indexOf(child);
        if (i >= 0) elements.splice(i, 1);
        return child;
      },
      addEventListener(type, fn) {
        if (type === "load") this.onload = fn;
      },
      append(...nodes) {
        for (const n of nodes) this.appendChild(n);
      },
      remove() {
        const i = elements.indexOf(this);
        if (i >= 0) elements.splice(i, 1);
      },
      ...props,
    };
    if (el.tagName === "IFRAME") makeIframe(el);
    if (el.tagName === "FORM") el.submit = () => submit(el);
    if (el.tagName === "A") makeAnchor(el);
    return el;
  };
  const register = (el) => {
    if (!elements.includes(el)) elements.push(el);
    if (el.id) byId.set(el.id, el);
    for (const c of el.children ?? []) register(c);
  };
  function makeIframe(el) {
    let doc = null;
    el.contentWindow = { location: { search: "", href: "" } };
    Object.defineProperty(el, "contentDocument", {
      get() {
        if (doc || !el.src) return doc;
        const res = fetchResource(file, el.src);
        const d = decodeDocument(res, lib.name(page.encoding));
        if (!lib.isImplemented(d.encoding)) throw new Error(`${lib.name(d.encoding)} is not implemented yet`);
        const nodes = [...d.text.matchAll(/<span\b([^>]*)>([\s\S]*?)<\/span>/g)].map((m) => ({
          dataset: { cp: attr(m[1], "data-cp"), bytes: attr(m[1], "data-bytes") },
          textContent: decodeEntities(m[2]),
        }));
        const name = lib.name(d.encoding);
        doc = {
          querySelectorAll: (sel) => (sel === "span" ? nodes : []),
          characterSet: name,
          inputEncoding: name,
          contentType: res.type.split(";")[0].trim(),
          documentElement: {},
          body: { textContent: decodeEntities(d.text.replace(/<!doctype[^>]*>|<[^>]*>/gi, "")) },
        };
        return doc;
      },
    });
    Object.defineProperty(el.contentWindow, "document", { get: () => el.contentDocument });
    el.contentWindow.window = el.contentWindow;
  }
  function submit(form) {
    const enc = lib.forLabel(form.acceptCharset || lib.name(page.encoding));
    const query = form.children
      .filter((c) => c.tagName === "INPUT")
      .map((c) => percentEncodeAfterEncoding(enc, c.name, formSet, true) + "=" + percentEncodeAfterEncoding(enc, c.value ?? "", formSet, true))
      .join("&");
    const frame = byId.get(form.target);
    setTimeout(() => {
      frame.contentWindow.location = { search: "?" + query, href: form.action + "?" + query };
      frame.onload?.();
    }, 0);
  }
  function makeAnchor(el) {
    let href = "";
    let search = "";
    Object.defineProperty(el, "href", {
      get: () => href,
      set(v) {
        const s = String(v).replace(/[\t\n\r]/g, "");
        href = s;
        const q = s.indexOf("?");
        if (q < 0) {
          search = "";
          return;
        }
        let query = s.slice(q + 1);
        const hash = query.indexOf("#");
        if (hash >= 0) query = query.slice(0, hash);
        const encoded = percentEncodeAfterEncoding(page.encoding, query, specialQuerySet, false);
        search = encoded ? "?" + encoded : "";
      },
    });
    Object.defineProperty(el, "search", { get: () => search });
  }
  const body = element("body");
  const document = {
    body,
    documentElement: element("html"),
    characterSet: lib.name(page.encoding),
    createElement: (tag) => element(tag),
    getElementById: (id) => byId.get(id) ?? null,
    getElementsByTagName: (tag) => elements.filter((e) => e.tagName === tag.toUpperCase()),
    querySelector: (sel) => (sel === "meta[charset]" ? { getAttribute: () => page.charset } : null),
    addEventListener() {},
  };
  ctx.document = document;
  ctx.window = ctx;
  ctx.addEventListener = (type, fn) => {
    if (type === "load") loadListeners.push(fn);
  };
  // The iframes in the markup, and the text of the elements with an id.
  const frames = [];
  for (const m of page.text.matchAll(/<iframe\b[^>]*>/gi)) {
    const el = element("iframe", { src: attr(m[0], "src"), id: attr(m[0], "id") ?? attr(m[0], "name") ?? "" });
    el.name = attr(m[0], "name");
    body.children.push(el);
    register(el);
    frames.push(el.contentWindow);
  }
  ctx.frames = frames;
  for (const m of page.text.matchAll(/<(div|span|p)\b([^>]*)>([^<]*)<\/\1>/gi)) {
    const id = attr(m[2], "id");
    if (id) register(element(m[1], { id, textContent: decodeEntities(m[3]) }));
  }
  return { loadListeners };
}

async function runPageTest(file) {
  const page = decodeDocument(fetchResource(file, path.basename(file)));
  page.charset = metaCharset(fs.readFileSync(file)) ?? "utf-8";
  const ctx = makeContext("", true);
  const done = startHarness(ctx, 60_000);
  ctx.__lib = lib;
  vm.runInContext(`(${installShim})(globalThis, __lib); delete globalThis.__lib;`, ctx);
  ctx.XMLHttpRequest = makeXhr(file);
  const { loadListeners } = makeDocument(ctx, file, page);
  try {
    for (const m of page.text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      const src = attr(m[1], "src");
      if (src === "/resources/testharness.js" || src === "/resources/testharnessreport.js") continue;
      if (src) load(ctx, resolveScript(file, src));
      else vm.runInContext(m[2], ctx, { filename: file });
    }
    for (const fn of loadListeners) fn();
    const onload = /<body\b[^>]*\bonload="([^"]*)"/i.exec(page.text.replace(/<script\b[\s\S]*?<\/script>/gi, ""));
    if (onload) vm.runInContext(onload[1], ctx, { filename: file + " (onload)" });
  } catch (err) {
    return { status: "ERROR", message: String(err.stack ?? err), tests: [] };
  }
  return done;
}

// Which files are tests, and how to run each.
function listTests() {
  const out = [];
  const walk = (dir) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (ent.name !== "resources") walk(p);
        continue;
      }
      const rel = path.relative(wptRoot, p);
      if (/\.any\.js$|\.window\.js$/.test(ent.name)) out.push({ rel, file: p, kind: "script" });
      else if (/\.html$/.test(ent.name) && /<script src="?\/resources\/testharness\.js/.test(fs.readFileSync(p, "latin1"))) {
        out.push({ rel, file: p, kind: "page" });
      } else if (/\.html$/.test(ent.name) && !/(_chars|_errors|-ref)(-[\w-]+)?\.html$/.test(ent.name)) {
        out.push({ rel, file: p, kind: "other" });
      }
    }
  };
  walk(path.join(wptRoot, "encoding"));
  return out;
}

let pass = 0;
let fail = 0;
let expectedFail = 0;
let unexpectedPass = 0;
let skipped = 0;
let bad = 0;
const problems = [];

for (const t of listTests()) {
  if (filter && !t.rel.includes(filter)) continue;
  const variants = t.kind === "script" ? readMeta(fs.readFileSync(t.file, "utf8")).variants : [];
  for (const variant of variants.length ? variants : [""]) {
    const id = t.rel + variant;
    const skip = skipOf(id) ?? (t.kind === "other" ? { why: "not a testharness.js test (a reftest or a manual page)", used: 0 } : null);
    if (skip) {
      skip.used++;
      skipped++;
      if (verbose) console.log(`SKIP ${id} -- ${skip.why}`);
      continue;
    }
    const started = Date.now();
    let result;
    try {
      result = t.kind === "page" ? await runPageTest(t.file) : await runScriptTest(t.file, variant);
    } catch (err) {
      result = { status: "ERROR", message: String(err.stack ?? err), tests: [] };
    }
    closeAll();
    let filePass = 0;
    let fileFail = 0;
    let fileExpected = 0;
    const harnessOk = result.status === "OK";
    if (!harnessOk) {
      const e = failOf(id, "", result.message);
      if (e) {
        e.used++;
        expectedFail++;
      } else {
        bad++;
        problems.push(`${id}: harness ${result.status}: ${result.message ?? ""}`);
      }
    }
    for (const s of result.tests) {
      const e = failOf(id, s.name, s.status === "PASS" ? "" : s.message);
      if (s.status === "PASS") {
        pass++;
        filePass++;
        if (e) {
          e.used++;
          unexpectedPass++;
          if (verbose || strict) problems.push(`${id} :: ${s.name}: passes, but expectations.txt lists it (${e.why})`);
        }
      } else if (e) {
        e.used++;
        expectedFail++;
        fileExpected++;
      } else {
        fail++;
        fileFail++;
        problems.push(`${id} :: ${s.name}: ${s.status} ${s.message ?? ""}`);
      }
    }
    const unexpected = fileFail || (!harnessOk && !failOf(id, "", result.message));
    console.log(
      `${unexpected ? "FAIL" : "ok  "} ${id}: ${filePass} passed, ${fileFail} failed, ${fileExpected} expected to fail` +
        `${harnessOk ? "" : ` (harness ${result.status})`} in ${Date.now() - started} ms`,
    );
  }
}

for (const e of expectations) {
  if (!e.used && !filter) problems.push(`expectations.txt: nothing matched ${e.kind} ${e.glob}${e.subtest ? " :: " + e.subtest : ""}`);
}
console.log(
  `\nwpt: ${pass} passed, ${fail} failed, ${expectedFail} failed as expected, ${unexpectedPass} passed though listed, ${skipped} files skipped, ${bad} harness errors`,
);
const failing = fail + bad + (strict ? unexpectedPass : 0) + (filter ? 0 : expectations.filter((e) => !e.used).length);
if (problems.length) console.log(problems.slice(0, 200).join("\n"));
process.exit(failing ? 1 : 0);
