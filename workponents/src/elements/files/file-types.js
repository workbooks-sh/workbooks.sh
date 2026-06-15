// files · shared type helpers — pure, zero-dep, DOM-free. Both <wb-drive> and
// <wb-file> classify a file by its mime/type or extension into a small kind set
// (image | video | audio | text | pdf | archive | code | font | file), pick a
// typed glyph, and format size/timestamps. One home, no copy-paste.

const EXT_KIND = {
  // images
  png: "image", jpg: "image", jpeg: "image", gif: "image", webp: "image",
  svg: "image", avif: "image", bmp: "image", ico: "image", heic: "image",
  // video
  mp4: "video", webm: "video", mov: "video", mkv: "video", avi: "video", m4v: "video",
  // audio
  mp3: "audio", wav: "audio", ogg: "audio", flac: "audio", m4a: "audio", aac: "audio",
  // text / docs
  txt: "text", md: "text", org: "text", rst: "text", log: "text", csv: "text",
  // pdf
  pdf: "pdf",
  // code
  js: "code", mjs: "code", ts: "code", jsx: "code", tsx: "code", json: "code",
  html: "code", css: "code", py: "code", rs: "code", go: "code", c: "code",
  cpp: "code", h: "code", ex: "code", exs: "code", sh: "code", sql: "code",
  yaml: "code", yml: "code", toml: "code", xml: "code",
  // archives
  zip: "archive", tar: "archive", gz: "archive", tgz: "archive", rar: "archive",
  "7z": "archive", bz2: "archive",
  // fonts
  woff: "font", woff2: "font", ttf: "font", otf: "font",
};

const GLYPH = {
  image: "🖼", video: "🎞", audio: "♪", text: "📄", pdf: "📕",
  code: "{ }", archive: "🗜", font: "Aa", file: "📦",
};

/** Lowercase extension (no dot) from a name or "image/png" → "png". */
export function extOf(s) {
  if (!s) return "";
  s = String(s);
  if (s.includes("/")) return s.split("/").pop().split("+")[0].toLowerCase(); // a mime subtype
  const dot = s.lastIndexOf(".");
  return dot >= 0 ? s.slice(dot + 1).toLowerCase() : "";
}

/** Classify into a kind from a mime/type string and/or a filename. */
export function fileKind(type, name) {
  const t = String(type || "").toLowerCase();
  if (t.startsWith("image/")) return "image";
  if (t.startsWith("video/")) return "video";
  if (t.startsWith("audio/")) return "audio";
  if (t === "application/pdf") return "pdf";
  if (t.startsWith("text/")) return "text";
  if (/(zip|x-tar|gzip|x-7z|x-rar)/.test(t)) return "archive";
  if (t.startsWith("font/")) return "font";
  if (/(javascript|json|html|xml|x-sh|x-python)/.test(t)) return "code";
  // fall back to the extension of name (or a bare ext in `type`)
  const ext = extOf(name) || (t && !t.includes("/") ? t : "");
  return EXT_KIND[ext] || "file";
}

/** A typed glyph for a kind (text-only; renders in any theme). */
export function kindGlyph(kind) { return GLYPH[kind] || GLYPH.file; }

/** Human byte size: 1536 → "1.5 KB". Accepts number or numeric string. */
export function fmtBytes(n) {
  n = Number(n);
  if (!isFinite(n) || n < 0) return "—";
  if (n < 1024) return `${n} B`;
  const u = ["KB", "MB", "GB", "TB"];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
}

/** Friendly timestamp: ISO/epoch → "Nov 3, 2024". Best-effort, never throws. */
export function fmtWhen(v) {
  if (v == null || v === "") return "—";
  let d;
  if (typeof v === "number") d = new Date(v < 1e12 ? v * 1000 : v); // s vs ms epoch
  else d = new Date(v);
  if (isNaN(d.getTime())) return String(v);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/** Short content-hash for display: "sha256:abcd…1234" → "abcd…1234". */
export function shortHash(h) {
  if (!h) return "";
  h = String(h).replace(/^[a-z0-9]+:/i, "");
  return h.length > 14 ? `${h.slice(0, 8)}…${h.slice(-4)}` : h;
}
