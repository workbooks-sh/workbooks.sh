// <work-diff> — themed before/after diff, computed IN JS (no external dep).
//
// The reinvention: version control's diff without git's vocabulary. The element
// is handed two SOURCES (`a`/`b` attrs, or two slotted <template>/text children)
// and renders a diff2html-grade view, themed entirely from --work-*. Two engines:
//   • SEMANTIC org-block diff (the goal) — splits org-mode source into blocks
//     (headings, :PROPERTIES: drawers, src/example blocks, paragraphs) and diffs
//     at the block level, so a moved/edited section reads as one semantic change.
//   • LINE diff (the fallback) — an LCS line diff for non-org / plain text.
// `mode="split|inline"`. Standalone: it computes the diff itself, no runtime.
import { WbElement, html, css, define } from "../../core/element.js";
import { unsafeHTML } from "lit/directives/unsafe-html.js";
import { defineVariants, variantAttrs, resolveVariant } from "../../core/variants.js";

const VARIANTS = defineVariants({
  mode: { options: ["split", "inline"], default: "split" },
  diff: { options: ["semantic", "lines", "auto"], default: "auto" },
});

// ── LCS line diff ──────────────────────────────────────────────────────────
// Classic dynamic-programming longest-common-subsequence over arrays of lines.
// Returns a flat op list: {type: "eq"|"del"|"add", text, an, bn} with the
// originating line numbers (an = a-side, bn = b-side; null when not present).
export function lcsDiff(aLines, bLines) {
  const n = aLines.length, m = bLines.length;
  // dp[i][j] = LCS length of a[i..], b[j..]
  const dp = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = aLines[i] === bLines[j]
        ? dp[i + 1][j + 1] + 1
        : Math.max(dp[i + 1][j], dp[i][j + 1]);

  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (aLines[i] === bLines[j]) {
      ops.push({ type: "eq", text: aLines[i], an: i + 1, bn: j + 1 }); i++; j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.push({ type: "del", text: aLines[i], an: i + 1, bn: null }); i++;
    } else {
      ops.push({ type: "add", text: bLines[j], an: null, bn: j + 1 }); j++;
    }
  }
  while (i < n) ops.push({ type: "del", text: aLines[i], an: ++i, bn: null });
  while (j < m) ops.push({ type: "add", text: bLines[j], an: null, bn: ++j });
  return ops;
}

// ── Semantic org-block segmentation ──────────────────────────────────────────
// Split org-mode source into addressable blocks. A heading starts a block; a
// #+begin_…/#+end_… pair is one atomic block; a :PROPERTIES:…:END: drawer is one
// block; blank-line-separated runs are paragraph blocks. Each block keeps a kind
// + a stable key (heading text / first line) so the block-level diff is semantic.
export function orgBlocks(src) {
  const lines = src.split("\n");
  const blocks = [];
  let buf = [], kind = "para";
  const flush = () => {
    if (buf.length && buf.join("").trim() !== "") {
      const text = buf.join("\n");
      blocks.push({ kind, text, key: blockKey(kind, buf) });
    }
    buf = []; kind = "para";
  };
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    if (/^\*+\s/.test(ln)) {                       // heading → its own block
      flush(); blocks.push({ kind: "heading", text: ln, key: ln.replace(/^\*+\s*/, "").trim() });
      continue;
    }
    if (/^\s*#\+begin_/i.test(ln)) {               // block: gobble to #+end_
      flush(); const start = i;
      while (i < lines.length && !/^\s*#\+end_/i.test(lines[i])) i++;
      const text = lines.slice(start, i + 1).join("\n");
      blocks.push({ kind: "block", text, key: lines[start].trim() });
      continue;
    }
    if (/^\s*:PROPERTIES:\s*$/i.test(ln)) {         // drawer
      flush(); const start = i;
      while (i < lines.length && !/^\s*:END:\s*$/i.test(lines[i])) i++;
      const text = lines.slice(start, i + 1).join("\n");
      blocks.push({ kind: "drawer", text, key: ":PROPERTIES:" });
      continue;
    }
    if (ln.trim() === "") { flush(); continue; }    // blank → paragraph boundary
    buf.push(ln);
  }
  flush();
  return blocks;
}
function blockKey(kind, buf) {
  return (buf[0] || "").trim().slice(0, 80) || kind;
}
function looksOrg(s) {
  return /^\*+\s/m.test(s) || /^\s*#\+(begin_|title:|property:)/im.test(s) || /^\s*:PROPERTIES:/im.test(s);
}

// Diff org sources at the block level (LCS over block keys), then within each
// changed block fall back to a line diff so edits inside a section still show.
export function semanticDiff(aSrc, bSrc) {
  const A = orgBlocks(aSrc), B = orgBlocks(bSrc);
  const aKeys = A.map((b) => b.kind + " " + b.text);
  const bKeys = B.map((b) => b.kind + " " + b.text);
  const ops = lcsDiff(aKeys, bKeys);
  // Coalesce an adjacent del+add of the SAME semantic key into a "changed" block
  // (its inner line diff explains what moved), otherwise emit add/del/eq blocks.
  const out = [];
  for (let k = 0; k < ops.length; k++) {
    const op = ops[k], next = ops[k + 1];
    if (op.type === "del" && next && next.type === "add") {
      const ab = A[op.an - 1], bb = B[next.bn - 1];
      if (ab && bb && ab.key === bb.key && ab.kind === bb.kind) {
        out.push({ type: "chg", kind: ab.kind, key: ab.key,
                   lines: lcsDiff(ab.text.split("\n"), bb.text.split("\n")) });
        k++; continue;
      }
    }
    const blk = op.type === "del" ? A[op.an - 1] : B[op.bn - 1];
    out.push({ type: op.type, kind: blk?.kind || "para", key: blk?.key || "",
               text: blk?.text || "" });
  }
  return out;
}

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

export class WorkDiff extends WbElement {
  static variants = VARIANTS;
  static props = [...variantAttrs(VARIANTS), "a", "b"];

  static styles = css`
    :host { display: block; font-family: var(--work-font-mono); font-size: var(--work-text-sm); color: var(--work-fg); }
    .frame { border: 1px solid var(--work-border); border-radius: var(--work-radius); overflow: hidden; background: var(--work-surface); box-shadow: var(--work-shadow-sm); }
    .head { display: flex; align-items: center; gap: var(--work-space-2); padding: var(--work-space-2) var(--work-space-3); border-bottom: 1px solid var(--work-border); background: var(--work-surface-soft); font: 700 10px var(--work-font-mono); letter-spacing: .14em; text-transform: uppercase; color: var(--work-fg-subtle); }
    .head .grow { flex: 1; }
    .stat { font-weight: 700; letter-spacing: .04em; }
    .stat .add { color: var(--work-diff-add-ink, var(--work-ok)); }
    .stat .del { color: var(--work-diff-del-ink, var(--work-err)); }

    table { width: 100%; border-collapse: collapse; }
    td { padding: 1px var(--work-space-3); vertical-align: top; white-space: pre-wrap; word-break: break-word; line-height: 1.55; }
    td.gut { width: 1%; text-align: right; color: var(--work-fg-subtle); user-select: none; background: var(--work-surface-soft); border-right: 1px solid var(--work-border); font-variant-numeric: tabular-nums; padding-right: var(--work-space-2); }
    td.sign { width: 1%; text-align: center; user-select: none; color: var(--work-fg-subtle); padding: var(--work-space-px) 0; }

    tr.add td.code { background: var(--work-diff-add-bg, var(--work-diff-add)); }
    tr.del td.code { background: var(--work-diff-del-bg, var(--work-diff-del)); }
    tr.add td.sign { color: var(--work-diff-add-ink, var(--work-ok)); }
    tr.del td.sign { color: var(--work-diff-del-ink, var(--work-err)); }
    tr.empty td { background: var(--work-diff-empty-bg, var(--work-surface-soft)); }

    /* semantic block markers */
    .blockhdr { padding: var(--work-space-2) var(--work-space-3); font: 700 10px var(--work-font-mono); letter-spacing: .1em; text-transform: uppercase; color: var(--work-fg-muted); background: var(--work-surface-soft); border-top: 1px solid var(--work-border); display: flex; gap: var(--work-space-2); align-items: center; }
    .pill { padding: var(--work-space-px) var(--work-space-7px); border-radius: var(--work-radius-pill); font-size: var(--work-text-3xs); letter-spacing: .08em; }
    .pill.add { background: var(--work-diff-add-bg, var(--work-diff-add-strong)); color: var(--work-diff-add-ink, var(--work-ok)); }
    .pill.del { background: var(--work-diff-del-bg, var(--work-diff-del-strong)); color: var(--work-diff-del-ink, var(--work-err)); }
    .pill.chg { background: var(--work-brand-soft); color: var(--work-brand-ink, var(--work-brand)); }
    .pill.kind { background: var(--work-surface); border: 1px solid var(--work-border); color: var(--work-fg-subtle); }
    .key { color: var(--work-fg); font-weight: 600; text-transform: none; letter-spacing: 0; }

    /* split layout: two synced columns */
    .split { display: grid; grid-template-columns: 1fr 1fr; }
    .split .col { border-right: 1px solid var(--work-border); }
    .split .col:last-child { border-right: 0; }
  `;

  // Resolve a source: attribute first, else a slotted child with [slot="a"|"b"].
  _src(side) {
    const a = this.attr(side);
    if (a != null) return a;
    const el = this.querySelector(`[slot="${side}"]`);
    if (el) return (el.tagName === "TEMPLATE" ? el.innerHTML : el.textContent) || "";
    return "";
  }

  render() {
    const mode = resolveVariant(this, VARIANTS, "mode");
    const aSrc = this._src("a"), bSrc = this._src("b");
    const want = resolveVariant(this, VARIANTS, "diff");
    const semantic = want === "semantic" || (want === "auto" && (looksOrg(aSrc) || looksOrg(bSrc)));

    let body, adds = 0, dels = 0;
    if (semantic) {
      const blocks = semanticDiff(aSrc, bSrc);
      for (const b of blocks) {
        if (b.type === "add") adds++; else if (b.type === "del") dels++;
        else if (b.type === "chg") for (const l of b.lines) { if (l.type === "add") adds++; else if (l.type === "del") dels++; }
      }
      body = this._renderSemantic(blocks, mode);
    } else {
      const ops = lcsDiff(aSrc.split("\n"), bSrc.split("\n"));
      for (const o of ops) { if (o.type === "add") adds++; else if (o.type === "del") dels++; }
      body = mode === "split" ? this._renderSplit(ops) : this._renderInline(ops);
    }

    // body is pre-escaped, trusted markup (every cell goes through esc()).
    return html`
      <div class="frame" part="frame">
        <div class="head">
          <span>diff</span>
          <span class="pill kind">${semantic ? "semantic · org-block" : "line"}</span>
          <span class="pill kind">${mode}</span>
          <span class="grow"></span>
          <span class="stat"><span class="add">+${adds}</span> <span class="del">−${dels}</span></span>
        </div>
        ${unsafeHTML(body)}
      </div>`;
  }

  // Inline: one column, +/- signs, both line numbers.
  _renderInline(ops) {
    const rows = ops.map((o) => {
      const cls = o.type === "eq" ? "" : o.type;
      const sign = o.type === "add" ? "+" : o.type === "del" ? "−" : "";
      return `<tr class="${cls}"><td class="gut">${o.an ?? ""}</td><td class="gut">${o.bn ?? ""}</td><td class="sign">${sign}</td><td class="code">${esc(o.text)}</td></tr>`;
    }).join("");
    return `<table part="diff">${rows}</table>`;
  }

  // Split: two columns, a-side (deletions) | b-side (additions), aligned.
  _renderSplit(ops) {
    // Pair each op into [left, right] rows: eq → both; del → left only; add → right.
    const pairs = [];
    for (let k = 0; k < ops.length; k++) {
      const o = ops[k];
      if (o.type === "eq") pairs.push([o, o]);
      else if (o.type === "del") {
        // try to pair with the next add for an aligned change row
        const nx = ops[k + 1];
        if (nx && nx.type === "add") { pairs.push([o, nx]); k++; }
        else pairs.push([o, null]);
      } else pairs.push([null, o]);
    }
    const cell = (o, kind) => o == null
      ? `<tr class="empty"><td class="gut"></td><td class="sign"></td><td class="code"></td></tr>`
      : `<tr class="${o.type === "eq" ? "" : kind}"><td class="gut">${kind === "del" ? (o.an ?? "") : (o.bn ?? "")}</td><td class="sign">${o.type === "eq" ? "" : kind === "del" ? "−" : "+"}</td><td class="code">${esc(o.text)}</td></tr>`;
    const lrows = pairs.map((p) => cell(p[0], "del")).join("");
    const rrows = pairs.map((p) => cell(p[1], "add")).join("");
    return `<div class="split" part="diff"><div class="col"><table>${lrows}</table></div><div class="col"><table>${rrows}</table></div></div>`;
  }

  // Semantic: a header per block (kind + key + change pill), and for changed
  // blocks the inner line diff (rendered inline — block context is the story).
  _renderSemantic(blocks, mode) {
    return blocks.map((b) => {
      if (b.type === "eq") return ""; // unchanged blocks collapse — focus on change
      const pill = b.type === "chg" ? "chg" : b.type;
      const label = b.type === "add" ? "added" : b.type === "del" ? "removed" : "changed";
      const hdr = `<div class="blockhdr"><span class="pill ${pill}">${label}</span><span class="pill kind">${b.kind}</span><span class="key">${esc(b.key || "")}</span></div>`;
      if (b.type === "chg") return hdr + (mode === "split" ? this._renderSplit(b.lines) : this._renderInline(b.lines));
      // add/del whole block
      const ops = b.text.split("\n").map((t) => ({ type: b.type, text: t, an: null, bn: null }));
      return hdr + (mode === "split" ? this._renderSplit(ops) : this._renderInline(ops));
    }).join("");
  }
}

define("work-diff", WorkDiff);
