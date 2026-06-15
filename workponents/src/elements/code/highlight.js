// Token-only syntax highlight — the zero-dep FLOOR for <wb-editor>.
//
// Deliberately minimal: a lightweight tokenizer that wraps comments, strings,
// numbers, and a per-language keyword set in <span class="tok-*"> spans styled
// from --wb-* tokens. It is NOT a parser and makes no correctness claims — it is
// the readable floor. The powered tier swaps in CodeMirror behind the same
// <wb-editor> public API (see editor seam in wb-editor.js); this module is then
// simply not used. Output is HTML-escaped first, so it is safe to set as innerHTML.

const KEYWORDS = {
  js: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
    "switch", "case", "break", "continue", "new", "class", "extends", "super", "this",
    "import", "export", "from", "default", "async", "await", "yield", "try", "catch",
    "finally", "throw", "typeof", "instanceof", "in", "of", "delete", "void", "null",
    "undefined", "true", "false", "static", "get", "set"],
  c: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
    "struct", "union", "enum", "typedef", "const", "static", "extern", "return", "if",
    "else", "for", "while", "do", "switch", "case", "break", "continue", "sizeof",
    "include", "define", "ifdef", "ifndef", "endif", "goto", "default"],
  rust: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl",
    "pub", "use", "mod", "match", "if", "else", "for", "while", "loop", "return",
    "break", "continue", "self", "Self", "as", "ref", "move", "async", "await",
    "dyn", "where", "type", "unsafe", "true", "false"],
  zig: ["const", "var", "fn", "pub", "return", "if", "else", "for", "while", "switch",
    "struct", "enum", "union", "comptime", "try", "catch", "defer", "errdefer",
    "test", "import", "export", "extern", "inline", "true", "false", "null", "undefined"],
  go: ["package", "import", "func", "var", "const", "type", "struct", "interface",
    "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch",
    "case", "default", "select", "break", "continue", "nil", "true", "false"],
};

// Languages that share C-ish comment/string syntax cover everything we tokenize.
const ALIASES = { javascript: "js", typescript: "js", ts: "js", golang: "go", "c++": "c", cpp: "c", h: "c" };

export function normalizeLang(lang) {
  const l = (lang || "js").toLowerCase();
  return ALIASES[l] || l;
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
}

// Tokenize one already-escaped line. We scan char-by-char so spans never nest or
// cross HTML-escape boundaries. Strings/comments win over keywords/numbers.
export function highlightLine(rawLine, lang) {
  const kw = new Set(KEYWORDS[normalizeLang(lang)] || KEYWORDS.js);
  const src = rawLine;
  let out = "";
  let i = 0;
  const n = src.length;

  const wrap = (cls, text) => `<span class="tok-${cls}">${escapeHtml(text)}</span>`;

  while (i < n) {
    const c = src[i];
    const rest = src.slice(i);

    // line comment  // ... or # ... (covers C preproc-ish + scripting)
    if (rest.startsWith("//") || c === "#") {
      out += wrap("comment", rest);
      break;
    }
    // block comment  /* ... */ (single-line slice only; multi-line handled by caller state)
    if (rest.startsWith("/*")) {
      const end = rest.indexOf("*/");
      const seg = end >= 0 ? rest.slice(0, end + 2) : rest;
      out += wrap("comment", seg);
      i += seg.length;
      continue;
    }
    // strings  " ' `
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < n && src[j] !== c) { if (src[j] === "\\") j++; j++; }
      const seg = src.slice(i, Math.min(j + 1, n));
      out += wrap("str", seg);
      i = j + 1;
      continue;
    }
    // numbers
    if (/[0-9]/.test(c) && (i === 0 || /[^A-Za-z0-9_]/.test(src[i - 1]))) {
      const m = rest.match(/^0x[0-9a-fA-F]+|^[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?/);
      if (m) { out += wrap("num", m[0]); i += m[0].length; continue; }
    }
    // identifiers / keywords
    if (/[A-Za-z_]/.test(c)) {
      const m = rest.match(/^[A-Za-z_][A-Za-z0-9_]*/);
      const word = m[0];
      out += kw.has(word) ? wrap("kw", word) : escapeHtml(word);
      i += word.length;
      continue;
    }
    // everything else, escaped
    out += escapeHtml(c);
    i++;
  }
  return out;
}

// Highlight a whole document, line by line, tracking /* */ block-comment state
// across lines. Returns one HTML string with \n preserved (the overlay is a <pre>).
export function highlight(code, lang) {
  const lines = String(code).split("\n");
  let inBlock = false;
  const html = lines.map((line) => {
    if (inBlock) {
      const end = line.indexOf("*/");
      if (end < 0) return `<span class="tok-comment">${escapeHtml(line)}</span>`;
      const seg = line.slice(0, end + 2);
      inBlock = false;
      return `<span class="tok-comment">${escapeHtml(seg)}</span>` + highlightLine(line.slice(end + 2), lang);
    }
    // open an unterminated block comment?
    const open = line.lastIndexOf("/*");
    const close = line.lastIndexOf("*/");
    if (open >= 0 && close < open) {
      inBlock = true;
      return highlightLine(line.slice(0, open), lang) + `<span class="tok-comment">${escapeHtml(line.slice(open))}</span>`;
    }
    return highlightLine(line, lang);
  });
  return html.join("\n");
}
