import { isBlockOpener } from './lang-stream.js';
// workedit/live — the Live (WYSIWYG) layer (P4). NOT a second editor: a decoration layer over the
// SAME CodeMirror surface (Obsidian "Live Preview" model). It styles headings and renders inline refs
// ([[backlinks]], #tags, work:// links) as chips, while REVEALING the raw syntax on whatever line the
// cursor/selection touches — so the text stays source-of-truth and editing is never blocked. Built as a
// ViewPlugin over the host's @codemirror/view namespace (one state instance, like the P1 highlighter).
// Toggled by the island's `mode` compartment; default off (Source).

const LIVE_CSS = `
.wke-h1{font-size:1.55em;font-weight:700;line-height:1.3}
.wke-h2{font-size:1.35em;font-weight:700;line-height:1.3}
.wke-h3{font-size:1.18em;font-weight:700}
.wke-h4{font-size:1.06em;font-weight:700}
.wke-h5,.wke-h6{font-weight:700}
/* Chips: inline-block + vertical-align:middle gives a consistent baseline across a row
   (inline-flex synthesizes an inconsistent baseline, so chips drifted up/down). Fixed line-height
   + box-sizing keeps every chip the same height regardless of its text. */
.wke-chip{display:inline-block;box-sizing:border-box;height:1.5em;line-height:calc(1.5em - 2px);
  border-radius:999px;padding:0 8px;margin:0 1px;vertical-align:middle;white-space:nowrap;
  font:600 .82em var(--read,system-ui);cursor:default;border:1px solid transparent}
.wke-chip-link{color:var(--wke-link,#2f6fa8);background:color-mix(in srgb, var(--wke-link,#2f6fa8) 12%, transparent)}
.wke-chip-tag{color:var(--wke-meta,#2f6fa8);background:color-mix(in srgb, var(--wke-meta,#2f6fa8) 12%, transparent)}
.wke-chip-work{color:var(--wke-lang,#9a6a3a);background:color-mix(in srgb, var(--wke-lang,#9a6a3a) 12%, transparent)}
.wke-chip::before{content:attr(data-pre);opacity:.5;margin-right:2px;font-weight:500}
/* Inline markdown rendered live (markers hidden). */
.wke-md-bold{font-weight:700}
.wke-md-italic{font-style:italic}
.wke-md-strike{text-decoration:line-through;opacity:.75}
.wke-md-code{font-family:var(--mono,ui-monospace,monospace);font-size:.92em;background:color-mix(in srgb,var(--wke-op,#6a6f68) 13%,transparent);border-radius:4px;padding:0 4px}
.wke-md-link{color:var(--wke-link,#2f6fa8);text-decoration:underline;text-underline-offset:2px;cursor:pointer}
/* Block-level: bullets, blockquote bar, horizontal rule. */
.wke-bullet{color:var(--wke-op,#6a6f68);font-weight:700}
.wke-bq{border-left:3px solid color-mix(in srgb,var(--wke-op,#6a6f68) 55%,transparent);padding-left:10px;color:var(--wke-comment,#8a8f88)}
.wke-hr{display:inline-block;width:96%;border:0;border-top:2px solid color-mix(in srgb,var(--wke-op,#6a6f68) 45%,transparent);vertical-align:middle}
/* Blank the line number on a live-rendered heading line (revealed again when the cursor's on it). */
.cm-lineNumbers .wke-gutter-blank{color:transparent}
`;
function injectLiveStyle() {
  if (document.getElementById('wke-style-live')) return;
  const s = document.createElement('style'); s.id = 'wke-style-live'; s.textContent = LIVE_CSS; document.head.appendChild(s);
}

// Scan one PROSE line into inline tokens (refs + markdown), left to right, non-overlapping. Each token:
// { s, e, kind, ... }. `ml` = marker length to hide on each side (bold/italic/code/strike). Higher-
// priority constructs (code, links, refs) are matched before emphasis so e.g. a URL isn't italicized.
function scanInline(text) {
  const out = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const rest = text.slice(i);
    let m;
    if ((m = /^`([^`\n]+)`/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'code', ml: 1 }); i += m[0].length; continue; }
    if ((m = /^\[\[([^\]\n]+)\]\]/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'reflink', label: m[1] }); i += m[0].length; continue; }
    if ((m = /^\[([^\]\n]+)\]\(([^)\s]+)\)/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'link', label: m[1], url: m[2] }); i += m[0].length; continue; }
    if ((m = /^work:\/\/[^\s)]*[A-Za-z0-9_/#-]/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'work', label: m[0] }); i += m[0].length; continue; }
    if ((i === 0 || !/\w/.test(text[i - 1])) && (m = /^#([a-z][\w-]*)/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'tag', label: m[1] }); i += m[0].length; continue; }
    if ((m = /^(\*\*|__)(?=\S)([\s\S]+?\S)\1/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'bold', ml: 2 }); i += m[0].length; continue; }
    if ((m = /^~~(?=\S)([\s\S]+?\S)~~/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'strike', ml: 2 }); i += m[0].length; continue; }
    if ((m = /^(\*|_)(?=\S)([^*_\n]+?\S?)\1/.exec(rest))) { out.push({ s: i, e: i + m[0].length, kind: 'italic', ml: 1 }); i += m[0].length; continue; }
    i++;
  }
  return out;
}

// Line numbers (1-based) that are part of a top-level `do…end` block (opener, body, end) — bodies are
// highlighted by nested.js, NOT treated as markdown prose. Openers/closers sit at column 0.
function blockLines(doc) {
  const set = new Set();
  let open = 0;
  for (let i = 1; i <= doc.lines; i++) {
    const t = doc.line(i).text;
    if (!open) {
      if (isBlockOpener(t)) { open = i; set.add(i); }
    } else {
      set.add(i);
      if (/^end\b/.test(t)) open = 0;
    }
  }
  return set;
}

export function workLiveFromView(view, state) {
  injectLiveStyle();
  const { Decoration, ViewPlugin, WidgetType, EditorView, GutterMarker, gutterLineClass } = view;
  const RangeSet = state.RangeSet;

  // A gutter marker that blanks the line number (CSS .wke-gutter-blank) — used on live headings.
  const blankGutter = new (class extends GutterMarker { })();
  blankGutter.elementClass = 'wke-gutter-blank';

  class Chip extends WidgetType {
    constructor(label, kind, pre) { super(); this.label = label; this.kind = kind; this.pre = pre; }
    eq(o) { return o.label === this.label && o.kind === this.kind && o.pre === this.pre; }
    toDOM() {
      const s = document.createElement('span');
      s.className = 'wke-chip wke-chip-' + this.kind;
      if (this.pre) s.setAttribute('data-pre', this.pre);
      s.textContent = this.label;
      return s;
    }
    ignoreEvent() { return true; }
  }

  // A real anchor for [text](url) — clickable, opens in a new tab.
  class LinkW extends WidgetType {
    constructor(label, url) { super(); this.label = label; this.url = url; }
    eq(o) { return o.label === this.label && o.url === this.url; }
    toDOM() {
      const a = document.createElement('a');
      a.className = 'wke-md-link'; a.textContent = this.label; a.href = this.url;
      a.target = '_blank'; a.rel = 'noopener noreferrer'; a.title = this.url;
      return a;
    }
    ignoreEvent() { return true; }
  }

  // A list bullet glyph (replaces the raw -/*/+ marker) and a horizontal rule.
  class BulletW extends WidgetType {
    eq() { return true; }
    toDOM() { const s = document.createElement('span'); s.className = 'wke-bullet'; s.textContent = '•'; return s; }
  }
  class HrW extends WidgetType {
    eq() { return true; }
    toDOM() { const s = document.createElement('span'); s.className = 'wke-hr'; return s; }
    ignoreEvent() { return true; }
  }

  // Reusable marks/hides for inline markdown.
  const hide = Decoration.replace({});
  const markCache = {};
  const styleMark = (cls) => markCache[cls] || (markCache[cls] = Decoration.mark({ class: cls }));

  // Emit decorations for one inline token (already known not to be touched by the selection).
  function emitInline(sp, base, decos) {
    const s = base + sp.s, e = base + sp.e;
    switch (sp.kind) {
      case 'reflink': decos.push(Decoration.replace({ widget: new Chip(sp.label, 'link', '') }).range(s, e)); break;
      case 'tag': decos.push(Decoration.replace({ widget: new Chip(sp.label, 'tag', '#') }).range(s, e)); break;
      case 'work': decos.push(Decoration.replace({ widget: new Chip(sp.label, 'work', '') }).range(s, e)); break;
      case 'link': decos.push(Decoration.replace({ widget: new LinkW(sp.label, sp.url) }).range(s, e)); break;
      default: { // code / bold / italic / strike — hide the markers, style the inner text
        const cls = sp.kind === 'code' ? 'wke-md-code' : sp.kind === 'bold' ? 'wke-md-bold' : sp.kind === 'italic' ? 'wke-md-italic' : 'wke-md-strike';
        const ml = sp.ml;
        if (e - ml > s + ml) {
          decos.push(hide.range(s, s + ml));
          decos.push(styleMark(cls).range(s + ml, e - ml));
          decos.push(hide.range(e - ml, e));
        }
      }
    }
  }

  // Heading lines rendered live (cursor off them) get their gutter number blanked. Computed from state
  // (not the view) so it's a valid gutterLineClass RangeSet value — provided via .compute below.
  function buildGutter(st) {
    const doc = st.doc, sel = st.selection.main, marks = [];
    for (let i = 1; i <= doc.lines; i++) {
      const line = doc.line(i);
      if (/^#{1,6}\s/.test(line.text) && !(sel.from <= line.to && sel.to >= line.from)) {
        marks.push(blankGutter.range(line.from));
      }
    }
    return RangeSet.of(marks, true);
  }

  function build(v) {
    const decos = [];
    const sel = v.state.selection.main;
    const touches = (from, to) => sel.from <= to && sel.to >= from;
    const doc = v.state.doc;
    const inBlock = blockLines(doc); // lines inside a do…end block — not prose, skip markdown there

    for (const { from, to } of v.visibleRanges) {
      let lineNo = doc.lineAt(from).number;
      const lastLine = doc.lineAt(to).number;
      for (; lineNo <= lastLine; lineNo++) {
        if (inBlock.has(lineNo)) continue;
        const line = doc.line(lineNo);
        const text = line.text;

        // Heading: style the line; when rendered live (cursor not on it) hide the leading `#`s AND
        // blank its line number (cleaner). Both revert when the cursor is on the line.
        const h = /^(#{1,6})\s/.exec(text);
        if (h) {
          decos.push(Decoration.line({ class: 'wke-h' + h[1].length }).range(line.from));
          if (!touches(line.from, line.to)) {
            decos.push(Decoration.replace({}).range(line.from, line.from + h[1].length + 1));
          }
          continue; // don't run inline markdown inside a heading line
        }

        const onLine = touches(line.from, line.to);

        // Horizontal rule — a line of only --- / *** / ___ → render an <hr>.
        if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(text)) {
          if (!onLine && line.to > line.from) decos.push(Decoration.replace({ widget: new HrW() }).range(line.from, line.to));
          continue;
        }

        // Blockquote — `> ` (one or more). Keep a left bar always; hide the marker when not editing.
        const bq = /^(\s*)(>+)(\s?)/.exec(text);
        if (bq) {
          decos.push(Decoration.line({ class: 'wke-bq' }).range(line.from));
          if (!onLine) decos.push(Decoration.replace({}).range(line.from + bq[1].length, line.from + bq[0].length));
        } else {
          // Unordered list — replace the -/*/+ marker with a bullet glyph (ordered lists keep their number).
          const ul = /^(\s*)([-+*])(\s+)/.exec(text);
          if (ul && !onLine) {
            const mStart = line.from + ul[1].length;
            decos.push(Decoration.replace({ widget: new BulletW() }).range(mStart, mStart + 1));
          }
        }

        // Inline markdown + refs (markers like -/>/digits aren't matched by scanInline, so a full
        // scan is safe for list/quote lines too). Revealed when the selection touches the token.
        for (const sp of scanInline(text)) {
          const start = line.from + sp.s, end = line.from + sp.e;
          if (touches(start, end)) continue; // cursor here → show raw syntax
          emitInline(sp, line.from, decos);
        }
      }
    }
    // Decoration.set sorts; line decos and inline replaces can share a position safely.
    return Decoration.set(decos, true);
  }

  const plugin = ViewPlugin.fromClass(
    class {
      constructor(v) { this.decorations = build(v); }
      update(u) { if (u.docChanged || u.viewportChanged || u.selectionSet) this.decorations = build(u.view); }
    },
    {
      decorations: (v) => v.decorations,
      // Make chips behave as atomic units so the caret steps over them instead of into them.
      provide: (p) => EditorView.atomicRanges.of((v) => v.plugin(p)?.decorations || Decoration.none),
    },
  );
  // gutterLineClass wants a RangeSet VALUE (not a fn) — compute it from state, reactive to doc/selection.
  return [plugin, gutterLineClass.compute(['doc', 'selection'], buildGutter)];
}
