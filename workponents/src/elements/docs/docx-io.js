// docs/docx-io.js — the docx ↔ document-view I/O adapter (Phase 4a, floor-first).
//
// document-view's truth is its org/markdown SOURCE (preview ≡ source). docx is not a
// new document model — it is an I/O adapter on top: read a .docx INTO that source,
// and emit the current source back out AS a .docx. The render path is untouched.
//
// FLOOR (this file): pure JS libs, lazy-loaded from a pinned CDN ESM (mirrors
// plot-tier / sqlite-wasm — nothing bundled, no `bun install`), overridable for
// tests / offline hosts via window globals:
//   • read  — mammoth.js (docx → semantic HTML) → turndown (HTML → markdown).
//             override: window.__WB_MAMMOTH__ / window.__WB_TURNDOWN__
//   • write — docx (dolanmiu) builds an OOXML Document from document-view's parsed
//             block model (headings / paragraphs / lists / bold / italic / code).
//             override: window.__WB_DOCX__
//
// HOST (max fidelity, documented — not required to wire here): when a runtime is
// docked, document-view routes doc.export through `this.host` → pandoc.wasm (already in
// runtime/host/pallet.ex). pandoc is GPL, so it is invoked AS A TOOL over the Dock,
// never linked into this floor. The floor is the always-available default.
//
// Degradation: if the lib / CDN is unavailable, the import/export functions throw
// a clear, catchable error so document-view can surface a note instead of failing hard.

const MAMMOTH_CDN  = "https://esm.sh/mammoth@1.8.0";
const TURNDOWN_CDN = "https://esm.sh/turndown@7.2.0";
const DOCX_CDN     = "https://esm.sh/docx@9.0.2";

let _mammothP = null, _turndownP = null, _docxP = null;

// single-flight lazy import, override-first, retryable on failure (mirrors loadPlot)
function lazy(globalKey, cdn, holderName) {
  const win = typeof window !== "undefined" ? window : {};
  const override = win[globalKey];
  if (override) return Promise.resolve(override);
  const slot = { __WB_MAMMOTH__: "_m", __WB_TURNDOWN__: "_t", __WB_DOCX__: "_d" }[globalKey];
  if (!lazy[slot]) {
    lazy[slot] = import(/* @vite-ignore */ cdn)
      .then((m) => m.default || m)
      .catch((e) => { lazy[slot] = null; throw new Error(`docx-io: ${holderName} unavailable (${e.message || e})`); });
  }
  return lazy[slot];
}

const loadMammoth  = () => lazy("__WB_MAMMOTH__",  MAMMOTH_CDN,  "mammoth");
const loadTurndown = () => lazy("__WB_TURNDOWN__", TURNDOWN_CDN, "turndown");
const loadDocx     = () => lazy("__WB_DOCX__",     DOCX_CDN,     "docx");

/**
 * Import a .docx → org/markdown source string (the document-view truth).
 * mammoth (docx → semantic HTML) → turndown (HTML → GitHub-flavored markdown).
 * @param {ArrayBuffer} arrayBuffer  the raw .docx bytes
 * @returns {Promise<string>} markdown source ready to feed document-view
 */
export async function importDocx(arrayBuffer) {
  if (!arrayBuffer) throw new Error("docx-io: importDocx needs an ArrayBuffer");
  const [mammoth, Turndown] = await Promise.all([loadMammoth(), loadTurndown()]);
  const { value: htmlBody } = await mammoth.convertToHtml({ arrayBuffer });
  const td = new Turndown({
    headingStyle: "atx",       // # H1 — matches document-view's renderDoc heading grammar
    bulletListMarker: "-",
    codeBlockStyle: "fenced",
    emDelimiter: "*",          // *italic*  (renderDoc reads */_ for em)
    strongDelimiter: "**",     // **bold**
  });
  return td.turndown(htmlBody || "").trim() + "\n";
}

/**
 * Export org/markdown source → a .docx Blob, from document-view's parsed block model.
 * Pure floor: parses the source into blocks, maps each to a docx paragraph with
 * inline runs (bold / italic / code), and packs to a Blob (no native exec).
 * @param {string} orgSource  the document source (org or markdown)
 * @returns {Promise<Blob>} an application/vnd.openxmlformats-…wordprocessingml.document
 */
export async function exportDocx(orgSource) {
  const docx = await loadDocx();
  const { Document, Packer, Paragraph, TextRun, HeadingLevel } = docx;
  const blocks = parseBlocks(String(orgSource || ""));
  const HEADING = [
    HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3,
    HeadingLevel.HEADING_4, HeadingLevel.HEADING_5, HeadingLevel.HEADING_6,
  ];

  const children = [];
  for (const b of blocks) {
    if (b.type === "heading") {
      children.push(new Paragraph({ heading: HEADING[Math.min(b.level, 6) - 1], children: runs(b.text, TextRun) }));
    } else if (b.type === "list-item") {
      children.push(new Paragraph({
        children: runs(b.text, TextRun),
        bullet: b.ordered ? undefined : { level: 0 },
        numbering: b.ordered ? { reference: "wb-ol", level: 0 } : undefined,
      }));
    } else if (b.type === "code") {
      // each code line a monospace run on its own paragraph (round-trips as a block)
      for (const ln of b.text.split("\n"))
        children.push(new Paragraph({ children: [new TextRun({ text: ln, font: "Consolas" })] }));
    } else if (b.type === "quote") {
      children.push(new Paragraph({ children: runs(b.text, TextRun), style: "IntenseQuote" }));
    } else {
      children.push(new Paragraph({ children: runs(b.text, TextRun) }));
    }
  }

  const doc = new Document({
    numbering: { config: [{ reference: "wb-ol", levels: [{ level: 0, format: "decimal", text: "%1.", alignment: "start" }] }] },
    sections: [{ children: children.length ? children : [new Paragraph({ children: [new TextRun("")] })] }],
  });
  return Packer.toBlob(doc);
}

// ── block parse — a focused subset mirroring render.js's grammar, but emitting a
// structured model (not HTML) so the docx writer can build native runs/headings.
function parseBlocks(src) {
  const lines = src.replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let i = 0, para = [];
  const flush = () => { if (para.length) { blocks.push({ type: "para", text: para.join(" ") }); para = []; } };

  while (i < lines.length) {
    const line = lines[i], t = line.trim();

    // org export/meta (#+TITLE: …) — skip, but not src fences
    if (/^#\+/i.test(t) && !/^#\+begin_src/i.test(t)) { i++; continue; }

    // fenced / org src code block
    const fence = t.match(/^```/) || t.match(/^#\+begin_src/i);
    if (fence) {
      flush();
      const closeRe = t.startsWith("```") ? /^```\s*$/ : /^#\+end_src/i;
      const code = []; i++;
      while (i < lines.length && !closeRe.test(lines[i].trim())) { code.push(lines[i]); i++; }
      i++;
      blocks.push({ type: "code", text: code.join("\n") });
      continue;
    }

    // heading — markdown ATX (#) or org headline (*); strip an org TODO/tag tail
    let h = line.match(/^(#{1,6})\s+(.*)$/) || line.match(/^(\*{1,6})\s+(.*)$/);
    if (h) {
      flush();
      let text = h[2].trim()
        .replace(/\s+:([\w@:-]+):\s*$/, "")                       // org :tags:
        .replace(/^(TODO|NEXT|IN_PROGRESS|WAIT|DONE|CANCELLED|BLOCKED)\s+/, ""); // org state
      blocks.push({ type: "heading", level: h[1].length, text });
      i++; continue;
    }

    // horizontal rule — drop (no clean docx analog in the floor)
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) { flush(); i++; continue; }

    // blockquote
    if (/^>\s?/.test(t)) {
      flush();
      const q = [];
      while (i < lines.length && /^>\s?/.test(lines[i].trim())) { q.push(lines[i].trim().replace(/^>\s?/, "")); i++; }
      blocks.push({ type: "quote", text: q.join(" ") });
      continue;
    }

    // list item (unordered - * + / ordered 1. 1)) — flatten a leading checkbox
    const ul = line.match(/^\s*[-*+]\s+(.*)$/);
    const ol = line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (ul || ol) {
      flush();
      let txt = (ul ? ul[1] : ol[1]).replace(/^\[([ xX-])\]\s+/, (m, c) => (/[xX]/.test(c) ? "✓ " : "□ "));
      blocks.push({ type: "list-item", ordered: !!ol, text: txt });
      i++; continue;
    }

    if (t === "") { flush(); i++; continue; }
    para.push(t); i++;
  }
  flush();
  return blocks;
}

// ── inline runs — split a line into docx TextRuns honoring **bold**, *org-bold*,
// /italic/, _italic_, `code` / =code= / ~code~. Markers are consumed; nesting is
// flat (the floor's render.js is likewise single-pass). Returns ≥1 TextRun.
function runs(text, TextRun) {
  const out = [];
  // tokenizer: a single regex over the supported markers, in precedence order.
  const re = /(\*\*[^*]+\*\*)|(`[^`]+`)|(=[^=]+=)|(~[^~]+~)|(\*[^*\s][^*]*?\*)|(\/[^/\s][^/]*?\/)|(_[^_\s][^_]*?_)/g;
  let last = 0, m;
  const push = (t, opts) => { if (t) out.push(new TextRun({ text: t, ...opts })); };
  while ((m = re.exec(text))) {
    if (m.index > last) push(text.slice(last, m.index), {});
    const tok = m[0];
    if (tok.startsWith("**"))      push(tok.slice(2, -2), { bold: true });
    else if (tok.startsWith("`"))  push(tok.slice(1, -1), { font: "Consolas" });
    else if (tok.startsWith("="))  push(tok.slice(1, -1), { font: "Consolas" });
    else if (tok.startsWith("~"))  push(tok.slice(1, -1), { font: "Consolas" });
    else if (tok.startsWith("*"))  push(tok.slice(1, -1), { bold: true });
    else if (tok.startsWith("/"))  push(tok.slice(1, -1), { italics: true });
    else if (tok.startsWith("_"))  push(tok.slice(1, -1), { italics: true });
    last = re.lastIndex;
  }
  if (last < text.length) push(text.slice(last), {});
  return out.length ? out : [new TextRun({ text: "" })];
}

/** Sniff whether bytes look like a .docx (a ZIP container — PK\x03\x04 magic). */
export function looksLikeDocx(arrayBuffer) {
  if (!arrayBuffer || arrayBuffer.byteLength < 4) return false;
  const b = new Uint8Array(arrayBuffer, 0, 4);
  return b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05 || b[2] === 0x07);
}
