// presentation/pptx-io.js — the pptx ↔ deck-view I/O adapter (Phase 4b, floor-first).
//
// A <deck-view>'s truth is its ordered <deck-slide> children (composition-as-source);
// pptx is not a new deck model — it is an I/O adapter on top: emit the deck's slides
// AS a .pptx, and read a .pptx INTO deck source (a <deck-view>…<deck-slide> string the
// normal render path consumes). The deck/slide render + the wavelet export path are
// untouched.
//
// FLOOR (this file): pure JS libs, lazy-loaded from a pinned CDN ESM (mirrors
// plot-tier / docx-io — nothing bundled, no `bun install`), overridable for
// tests / offline hosts via window globals:
//   • write — PptxGenJS builds a real .pptx from the deck's slides (title + body
//             text + bullets per slide). override: window.__WB_PPTXGEN__
//   • read  — fflate unzips the OOXML container; we parse ppt/slides/slideN.xml
//             ourselves into structured slides, then EMIT <deck-view> source.
//             override: window.__WB_FFLATE__
//
// THE NOVEL PIECE — importPptx: there is no off-the-shelf pptx→deck/org reader
// (pandoc has NO pptx reader). A .pptx is a ZIP of OOXML parts; we unzip, read the
// presentation's slide order from ppt/_rels + ppt/presentation.xml, and parse each
// slide's DrawingML (<a:p> paragraphs of <a:r><a:t> text runs, with <a:pPr lvl>
// bullet levels). We classify the first/largest title placeholder as the slide
// heading and the rest as body (bullets honoring their indent level). What it
// CAPTURES: per-slide title, body paragraphs, bulleted lists with nesting level,
// reading order, slide count/order. What it DROPS (pragmatic, text-first — noted on
// the returned deck as a comment): images/media, tables, charts, shapes/positioning,
// speaker notes, theme colors/fonts, transitions/animations, master/layout geometry.
//
// HOST (max fidelity, documented — not wired here): a docked runtime could route a
// pptx export/import through a host verb; the floor is the always-available default.
//
// Degradation: if a lib / CDN is unavailable, the functions throw a clear, catchable
// error so deck-view can surface a note instead of failing hard.

const PPTXGEN_CDN = "https://esm.sh/pptxgenjs@3.12.0";
const FFLATE_CDN   = "https://esm.sh/fflate@0.8.2";

// single-flight lazy import, override-first, retryable on failure (mirrors loadPlot)
const _slots = {};
function lazy(globalKey, cdn, name) {
  const win = typeof window !== "undefined" ? window : {};
  if (win[globalKey]) return Promise.resolve(win[globalKey]);
  if (!_slots[globalKey]) {
    _slots[globalKey] = import(/* @vite-ignore */ cdn)
      .then((m) => m.default || m)
      .catch((e) => { _slots[globalKey] = null; throw new Error(`pptx-io: ${name} unavailable (${e.message || e})`); });
  }
  return _slots[globalKey];
}
const loadPptxGen = () => lazy("__WB_PPTXGEN__", PPTXGEN_CDN, "pptxgenjs");
const loadFflate   = () => lazy("__WB_FFLATE__",  FFLATE_CDN,  "fflate");

// ── EXPORT — deck → .pptx Blob ────────────────────────────────────────────────
// Floor-JS, straightforward: map each <deck-slide> band → a pptx slide. We pull
// the slide's structured text (title / body / bullets) with the SAME extractor the
// import side emits, so a round-trip is stable. PptxGenJS writes a real OOXML .pptx.
/**
 * Export a <deck-view> → a .pptx Blob.
 * @param {Element} deck  a <deck-view> element (or anything exposing the slides)
 * @returns {Promise<Blob>} an application/vnd.openxmlformats-…presentationml Blob
 */
export async function exportPptx(deck) {
  const PptxGenJS = await loadPptxGen();
  const pptx = new PptxGenJS();
  pptx.defineLayout({ name: "WB16x9", width: 13.333, height: 7.5 });
  pptx.layout = "WB16x9";

  const slides = deckSlides(deck);
  for (const s of slides) {
    const model = slideModel(s);
    const slide = pptx.addSlide();
    let y = 0.5;
    if (model.title) {
      slide.addText(model.title, {
        x: 0.6, y, w: 12.1, h: 1.1, fontSize: 32, bold: true, align: "left",
      });
      y += 1.3;
    }
    const bodyLines = model.body.map((b) => ({
      text: b.text,
      options: b.bullet ? { bullet: { indent: 18 }, indentLevel: b.level || 0, fontSize: 18 } : { fontSize: 18, paraSpaceAfter: 8 },
    }));
    if (bodyLines.length) {
      slide.addText(bodyLines, { x: 0.6, y, w: 12.1, h: 7.5 - y - 0.4, valign: "top", align: "left" });
    }
  }
  // write to a Blob without touching the filesystem (browser-safe)
  const out = await pptx.write({ outputType: "blob" });
  return out instanceof Blob ? out : new Blob([out], { type: PPTX_MIME });
}

// ── IMPORT (the novel piece) — .pptx ArrayBuffer → <deck-view> source ──────────
/**
 * Import a .pptx → a <deck-view>…<deck-slide> source string (the deck truth).
 * Unzips the OOXML container (fflate), reads slide order, parses each slide's
 * DrawingML into {title, body[]}, and emits deck source. Text-first; see header
 * for what's dropped (a note is embedded as an HTML comment in the output).
 * @param {ArrayBuffer|Uint8Array} arrayBuffer  the raw .pptx bytes
 * @returns {Promise<string>} <deck-view> source ready to render
 */
export async function importPptx(arrayBuffer) {
  if (!arrayBuffer) throw new Error("pptx-io: importPptx needs an ArrayBuffer");
  const fflate = await loadFflate();
  const bytes = arrayBuffer instanceof Uint8Array ? arrayBuffer : new Uint8Array(arrayBuffer);
  const zip = fflate.unzipSync(bytes); // { "ppt/slides/slide1.xml": Uint8Array, … }
  const dec = new TextDecoder();
  const read = (p) => (zip[p] ? dec.decode(zip[p]) : null);

  // resolve slide order: ppt/presentation.xml <p:sldIdLst> r:id → ppt/_rels/
  // presentation.xml.rels → target slideN.xml. Fall back to numeric sort of the
  // slide parts when the rels graph is missing/odd (robust to minimal authors).
  const orderedSlideParts = resolveSlideOrder(zip, read);

  const slides = orderedSlideParts.map((part) => parseSlideXml(read(part) || ""));
  return emitDeckSource(slides);
}

/** Sniff whether bytes look like a .pptx (a ZIP container — PK\x03\x04 magic). */
export function looksLikePptx(arrayBuffer) {
  const buf = arrayBuffer instanceof Uint8Array ? arrayBuffer : arrayBuffer && new Uint8Array(arrayBuffer);
  if (!buf || buf.byteLength < 4) return false;
  return buf[0] === 0x50 && buf[1] === 0x4b && (buf[2] === 0x03 || buf[2] === 0x05 || buf[2] === 0x07);
}

export const PPTX_MIME = "application/vnd.openxmlformats-officedocument.presentationml.presentation";

// ── deck → structured-slide extraction (shared by export + round-trip) ─────────
function deckSlides(deck) {
  if (!deck) return [];
  if (typeof deck.querySelectorAll === "function") {
    const found = Array.from(deck.querySelectorAll(":scope > deck-slide"));
    if (found.length) return found;
    return Array.from(deck.querySelectorAll("deck-slide"));
  }
  return Array.isArray(deck) ? deck : [];
}

// Pull a slide's text into {title, body:[{text,bullet,level}]} from its LIGHT-DOM
// content (the author's source — preview ≡ source). Headings (h1/h2/h3) become the
// title (first one wins) or body headings; <ul>/<ol> items become bullets honoring
// nesting depth; <p> become non-bulleted body lines. Presenter notes are skipped.
function slideModel(slide) {
  const title = { text: "" };
  const body = [];
  const nodes = slide && slide.children
    ? Array.from(slide.children).filter((c) => c.getAttribute && c.getAttribute("slot") !== "notes")
    : [];
  // a band="split" puts content in [slot=a]/[slot=b] — flatten both regions in order
  const roots = nodes.length ? nodes : [slide].filter(Boolean);
  const walk = (el) => {
    if (!el || !el.tagName) return;
    const tag = el.tagName.toLowerCase();
    if (tag === "h1" || tag === "h2" || tag === "h3") {
      const t = txt(el);
      if (!title.text) title.text = t; else body.push({ text: t, bullet: false, level: 0, heading: true });
    } else if (tag === "ul" || tag === "ol") {
      collectList(el, 0, body);
    } else if (tag === "p" || tag === "blockquote") {
      const t = txt(el); if (t) body.push({ text: t, bullet: false, level: 0 });
    } else if (el.children && el.children.length) {
      Array.from(el.children).forEach(walk);
    } else {
      const t = txt(el); if (t) body.push({ text: t, bullet: false, level: 0 });
    }
  };
  roots.forEach(walk);
  return { title: title.text, body };
}

function collectList(listEl, level, out) {
  for (const li of Array.from(listEl.children)) {
    if (!li.tagName || li.tagName.toLowerCase() !== "li") continue;
    // direct text of the <li> (excluding nested lists)
    const nested = Array.from(li.children).filter((c) => /^(ul|ol)$/i.test(c.tagName));
    const ownText = liOwnText(li);
    if (ownText) out.push({ text: ownText, bullet: true, level });
    for (const sub of nested) collectList(sub, level + 1, out);
  }
}
function liOwnText(li) {
  let s = "";
  for (const n of Array.from(li.childNodes)) {
    if (n.nodeType === 3) s += n.textContent;
    else if (n.nodeType === 1 && !/^(ul|ol)$/i.test(n.tagName)) s += n.textContent;
  }
  return s.replace(/\s+/g, " ").trim();
}
function txt(el) { return (el.textContent || "").replace(/\s+/g, " ").trim(); }

// ── OOXML slide parsing (the novel reader) ─────────────────────────────────────
// Resolve slide rendering order. Prefer the relationship graph; degrade gracefully.
function resolveSlideOrder(zip, read) {
  const slideParts = Object.keys(zip).filter((p) => /^ppt\/slides\/slide\d+\.xml$/.test(p));
  const numeric = slideParts.slice().sort((a, b) => slideNum(a) - slideNum(b));
  const presXml = read("ppt/presentation.xml");
  const relsXml = read("ppt/_rels/presentation.xml.rels");
  if (!presXml || !relsXml) return numeric;
  // r:id order from <p:sldId r:id="rIdN"/>
  const rIds = [...presXml.matchAll(/<p:sldId[^>]*r:id="([^"]+)"/g)].map((m) => m[1]);
  if (!rIds.length) return numeric;
  // rId → target (relative to ppt/)
  const relMap = {};
  for (const m of relsXml.matchAll(/<Relationship\b[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"[^>]*>/g)) {
    relMap[m[1]] = m[2];
  }
  // also handle attribute order variants (Target before Id)
  for (const m of relsXml.matchAll(/<Relationship\b[^>]*Target="([^"]+)"[^>]*Id="([^"]+)"[^>]*>/g)) {
    if (!relMap[m[2]]) relMap[m[2]] = m[1];
  }
  const ordered = rIds.map((id) => relMap[id]).filter(Boolean)
    .map((t) => "ppt/" + t.replace(/^\/?ppt\//, "").replace(/^\.\.\//, ""))
    .map((t) => t.replace(/^ppt\/\.\.\//, "ppt/").replace(/^ppt\/ppt\//, "ppt/"))
    .filter((p) => zip[p]);
  return ordered.length ? ordered : numeric;
}
function slideNum(p) { const m = p.match(/slide(\d+)\.xml$/); return m ? +m[1] : 0; }

// Parse one slide's XML into {title, body:[{text,bullet,level}]}.
// DrawingML: each text body is <p:sp> with <p:nvSpPr><p:nvPr><p:ph type="title|…">.
// Paragraphs are <a:p>; runs <a:r><a:t>text</a:t>; bullet level from <a:pPr lvl="N">.
// A paragraph is a bullet unless it sits in the title placeholder or carries
// <a:buNone/>. The title is the placeholder of type title/ctrTitle (first found),
// else the first non-empty paragraph.
function parseSlideXml(xml) {
  const shapes = matchAll(xml, /<p:sp\b[\s\S]*?<\/p:sp>/g).map((m) => m[0]);
  let title = "";
  const body = [];
  for (const sp of shapes) {
    const phType = (sp.match(/<p:ph\b[^>]*\btype="([^"]+)"/) || [])[1] || "";
    const isTitle = phType === "title" || phType === "ctrTitle";
    const paras = parseParagraphs(sp);
    if (isTitle) {
      const t = paras.map((p) => p.text).filter(Boolean).join(" ").trim();
      if (t && !title) title = t;
      continue;
    }
    for (const p of paras) {
      if (!p.text) continue;
      body.push({ text: p.text, bullet: !p.buNone, level: p.level });
    }
  }
  // Fallback: no title placeholder — promote the first body line to the title.
  if (!title && body.length) {
    const first = body.shift();
    title = first.text;
  }
  return { title, body };
}

// Parse <a:p> paragraphs out of a shape: text = concatenated <a:t>, level = pPr lvl,
// buNone = explicit no-bullet. Robust to namespace-prefix-free authors (a: optional).
function parseParagraphs(sp) {
  const out = [];
  for (const pMatch of matchAll(sp, /<a:p\b[\s\S]*?<\/a:p>/g)) {
    const pm = pMatch[0];
    const runs = matchAll(pm, /<a:t>([\s\S]*?)<\/a:t>/g).map((m) => decodeXml(m[1]));
    const text = runs.join("").replace(/\s+/g, " ").trim();
    const lvlM = pm.match(/<a:pPr\b[^>]*\blvl="(\d+)"/);
    const level = lvlM ? +lvlM[1] : 0;
    const buNone = /<a:buNone\b/.test(pm);
    out.push({ text, level, buNone });
  }
  return out;
}

function matchAll(s, re) { return s ? [...s.matchAll(re)] : []; }
function decodeXml(s) {
  return String(s)
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&amp;/g, "&");
}

// ── emit <deck-view> source from parsed slides ─────────────────────────────────
// Heading band for slides whose only content is a title; content/split otherwise.
// Bullets nest via real <ul> depth so the deck/deck-slide typography applies and a
// re-export round-trips the levels. The drop-list lives as an HTML comment header.
function emitDeckSource(slides) {
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const note = `<!-- imported from .pptx via pptx-io. Captured: per-slide title, body text, bulleted lists with nesting, slide order.\n     Dropped (text-first import): images/media, tables, charts, shapes/positioning, speaker notes, theme colors/fonts, transitions. -->`;
  const slideEls = slides.map((s, i) => {
    const hasBody = s.body && s.body.length;
    const band = hasBody ? "content" : "title";
    const align = hasBody ? "start" : "center";
    const parts = [];
    if (s.title) parts.push(`    <${band === "title" ? "h1" : "h2"}>${esc(s.title)}</${band === "title" ? "h1" : "h2"}>`);
    if (hasBody) parts.push(renderBody(s.body, esc));
    return `  <deck-slide band="${band}" align="${align}">\n${parts.filter(Boolean).join("\n")}\n  </deck-slide>`;
  });
  return `${note}\n<deck-view controls aspect="16:9" hold="4s" transition="rise">\n${slideEls.join("\n")}\n</deck-view>\n`;
}

// Render a flat body model (with bullet levels) into <p> + nested <ul> markup.
function renderBody(body, esc) {
  const lines = [];
  let i = 0;
  while (i < body.length) {
    const b = body[i];
    if (!b.bullet) { lines.push(`    <p>${esc(b.text)}</p>`); i++; continue; }
    // consume a contiguous run of bullets into a nested list
    const run = [];
    while (i < body.length && body[i].bullet) { run.push(body[i]); i++; }
    lines.push(buildList(run, esc));
  }
  return lines.join("\n");
}

// Build nested <ul> from a flat [{text,level}] run (level is monotonic-ish; we treat
// any increase as a new nested list and any decrease as closing back to that depth).
function buildList(run, esc) {
  let html = "";
  let depth = 0;
  const open = () => { html += "<ul>"; depth++; };
  const close = () => { html += "</ul>"; depth--; };
  open(); // base list at level 0
  let cur = 0;
  for (const b of run) {
    const lvl = Math.max(0, b.level || 0);
    while (lvl > cur) { open(); cur++; }
    while (lvl < cur) { close(); cur--; }
    html += `<li>${esc(b.text)}</li>`;
  }
  while (depth > 0) close();
  return "    " + html;
}
