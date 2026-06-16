// docs/render.js — the standalone markdown + basic-org → HTML renderer.
//
// The reinvention: the document IS its source, rendered directly (preview ≡
// source). For the seed this is a small dependency-free renderer covering the
// common block + inline grammar shared by markdown and org: headings, lists,
// code, emphasis, links, tables, rules, blockquotes, checkboxes, org TODO
// pills + tags. It is deliberately a SUBSET — for full org fidelity (property
// drawers, #+EXEC cells, citations, footnotes) an element reaches the OQL
// kernel (oql.wasm) through `this.host` (see the note in work-doc.js). The
// visual contract is kept aligned with the desktop org-renderer
// (desktop/src/lib/org-renderer/*).

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// --- inline grammar (markdown + org emphasis, code, links) ----------------
function inline(text) {
  let s = escapeHtml(text);
  // inline code: `code` (md), =code= / ~code~ (org verbatim)
  s = s.replace(/`([^`]+)`/g, (_m, c) => `<code>${c}</code>`);
  s = s.replace(/(^|[\s(])=([^=\s][^=]*?)=(?=[\s).,;:]|$)/g, (_m, p, c) => `${p}<code>${c}</code>`);
  s = s.replace(/(^|[\s(])~([^~\s][^~]*?)~(?=[\s).,;:]|$)/g, (_m, p, c) => `${p}<code>${c}</code>`);
  // links: [text](url) markdown, [[url][text]] / [[url]] org
  s = s.replace(/\[\[([^\]]+)\]\[([^\]]+)\]\]/g, (_m, url, t) => `<a href="${url}">${t}</a>`);
  s = s.replace(/\[\[([^\]]+)\]\]/g, (_m, url) => `<a href="${url}">${url}</a>`);
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_m, t, url) => `<a href="${url}">${t}</a>`);
  // bold: **md** then *org single-star*
  s = s.replace(/\*\*([^*]+)\*\*/g, (_m, t) => `<strong>${t}</strong>`);
  s = s.replace(/(^|[\s(])\*([^*\s][^*]*?)\*(?=[\s).,;:]|$)/g, (_m, p, t) => `${p}<strong>${t}</strong>`);
  // italic: /org/ then _md/org_
  s = s.replace(/(^|[\s(])\/([^/\s][^/]*?)\/(?=[\s).,;:]|$)/g, (_m, p, t) => `${p}<em>${t}</em>`);
  s = s.replace(/(^|[\s(])_([^_\s][^_]*?)_(?=[\s).,;:]|$)/g, (_m, p, t) => `${p}<em>${t}</em>`);
  return s;
}

function tableCells(line) {
  return line
    .replace(/^\s*\|/, "")
    .replace(/\|\s*$/, "")
    .split("|")
    .map((c) => c.trim());
}

function isTableSep(line) {
  return /^\s*\|?[\s:|+-]+\|[\s:|+-]*$/.test(line) && /-/.test(line);
}

// A heading in either grammar; returns {level, text} or null.
function headingOf(line) {
  let m = line.match(/^(#{1,6})\s+(.*)$/); // markdown ATX
  if (m) return { level: m[1].length, text: m[2].trim() };
  m = line.match(/^(\*{1,6})\s+(.*)$/); // org headline
  if (m) return { level: m[1].length, text: m[2].trim() };
  return null;
}

const TODO_KW = /^(TODO|NEXT|IN_PROGRESS|WAIT|DONE|CANCELLED|BLOCKED)\s+/;

function slugify(text) {
  return String(text)
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .slice(0, 64);
}

// Split a heading's raw text into { state, tags, text }.
function splitHeading(raw) {
  let text = raw;
  let tags = [];
  const tagm = text.match(/\s+:([\w@:-]+):\s*$/);
  if (tagm) { tags = tagm[1].split(":").filter(Boolean); text = text.slice(0, tagm.index).trim(); }
  let state = null;
  const km = text.match(TODO_KW);
  if (km) { state = km[1]; text = text.slice(km[0].length); }
  return { state, tags, text };
}

// The heading outline (used by work-doc-outline + work-doc cross-sync).
export function parseOutline(src) {
  const out = [];
  let inFence = false;
  for (const raw of String(src).replace(/\r\n?/g, "\n").split("\n")) {
    const t = raw.trim();
    if (/^```/.test(t) || /^#\+(begin|end)_src/i.test(t)) { inFence = !inFence; continue; }
    if (inFence) continue;
    const h = headingOf(raw);
    if (!h) continue;
    const { state, text } = splitHeading(h.text);
    out.push({ level: h.level, text, state, id: slugify(text) });
  }
  return out;
}

// The core: markdown/org source → HTML string. Fenced/src blocks whose lang is
// a known compute language are handed to `onCell` so work-doc can mount a live
// <work-doc-cell>; everything else renders as a <pre>.
export function renderDoc(src, { onCell } = {}) {
  const lines = String(src).replace(/\r\n?/g, "\n").split("\n");
  const html = [];
  let i = 0;
  let listStack = []; // 'ul' | 'ol'
  let para = [];

  const closeList = () => { while (listStack.length) html.push(`</${listStack.pop()}>`); };
  const flushPara = () => {
    if (para.length) { html.push(`<p>${inline(para.join(" "))}</p>`); para = []; }
  };
  const breakBlocks = () => { flushPara(); closeList(); };

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // org export/meta lines (#+TITLE:, #+AUTHOR:, …) — skip, but NOT src blocks
    if (/^#\+/i.test(trimmed) && !/^#\+(begin|end)_src/i.test(trimmed)) { i++; continue; }

    // fenced code / org src block (possibly a live cell)
    const fence = trimmed.match(/^```(\w+)?/) || trimmed.match(/^#\+begin_src\s*(\w+)?/i);
    if (fence) {
      breakBlocks();
      const lang = (fence[1] || "").toLowerCase();
      const closeRe = trimmed.startsWith("```") ? /^```\s*$/ : /^#\+end_src/i;
      const code = [];
      i++;
      while (i < lines.length && !closeRe.test(lines[i].trim())) { code.push(lines[i]); i++; }
      i++; // consume closing fence
      const body = code.join("\n");
      const isCell = onCell && /^(sql|polars|duckdb|py|python|js|chart)$/.test(lang);
      if (isCell) html.push(onCell({ lang, code: body }));
      else html.push(`<pre data-lang="${escapeHtml(lang)}"><code>${escapeHtml(body)}</code></pre>`);
      continue;
    }

    // headings
    const h = headingOf(line);
    if (h) {
      breakBlocks();
      const { state, tags, text } = splitHeading(h.text);
      const lvl = Math.min(6, h.level);
      const id = slugify(text);
      const pill = state
        ? `<span class="doc-state doc-state-${state.toLowerCase()}">${escapeHtml(state.replace("_", " "))}</span>`
        : "";
      const tagHtml = tags.length
        ? `<span class="doc-tags">${tags.map((tg) => `<span class="doc-tag">${escapeHtml(tg)}</span>`).join("")}</span>`
        : "";
      html.push(`<h${lvl} id="${id}">${pill}${inline(text)}${tagHtml}</h${lvl}>`);
      i++;
      continue;
    }

    // horizontal rule
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) { breakBlocks(); html.push("<hr />"); i++; continue; }

    // blockquote
    if (/^>\s?/.test(trimmed)) {
      breakBlocks();
      const quote = [];
      while (i < lines.length && /^>\s?/.test(lines[i].trim())) {
        quote.push(lines[i].trim().replace(/^>\s?/, "")); i++;
      }
      html.push(`<blockquote>${inline(quote.join(" "))}</blockquote>`);
      continue;
    }

    // table
    if (/^\s*\|/.test(line) && line.includes("|")) {
      breakBlocks();
      const rows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) { rows.push(lines[i]); i++; }
      const hasSep = rows.length > 1 && isTableSep(rows[1]);
      const headRow = hasSep ? rows[0] : null;
      const bodyRows = hasSep ? rows.slice(2) : rows;
      let t = "<table>";
      if (headRow) t += "<thead><tr>" + tableCells(headRow).map((c) => `<th>${inline(c)}</th>`).join("") + "</tr></thead>";
      t += "<tbody>";
      for (const r of bodyRows) {
        if (isTableSep(r)) continue; // org table rule "|---|"
        t += "<tr>" + tableCells(r).map((c) => `<td>${inline(c)}</td>`).join("") + "</tr>";
      }
      t += "</tbody></table>";
      html.push(t);
      continue;
    }

    // lists (markdown - * + and ordered 1.) — single level for the seed
    const ulm = line.match(/^(\s*)[-*+]\s+(.*)$/);
    const olm = line.match(/^(\s*)\d+[.)]\s+(.*)$/);
    if (ulm || olm) {
      flushPara();
      const want = olm ? "ol" : "ul";
      if (listStack[listStack.length - 1] !== want) { closeList(); listStack = [want]; html.push(`<${want}>`); }
      const content = ulm ? ulm[2] : olm[2];
      const cb = content.match(/^\[([ xX-])\]\s+(.*)$/);
      if (cb) {
        const checked = /[xX]/.test(cb[1]) ? " checked" : "";
        html.push(`<li class="doc-task"><input type="checkbox" disabled${checked} />${inline(cb[2])}</li>`);
      } else {
        html.push(`<li>${inline(content)}</li>`);
      }
      i++;
      continue;
    }

    // blank line ends a paragraph / list
    if (trimmed === "") { breakBlocks(); i++; continue; }

    // default: accumulate paragraph text
    para.push(trimmed);
    i++;
  }

  breakBlocks();
  return html.join("\n");
}
