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
.wke-chip{display:inline-flex;align-items:center;border-radius:999px;padding:0 8px;margin:0 1px;
  font:600 .85em var(--read,system-ui);line-height:1.7;cursor:default;vertical-align:baseline;
  border:1px solid transparent}
.wke-chip-link{color:var(--wke-link,#2f6fa8);background:color-mix(in srgb, var(--wke-link,#2f6fa8) 12%, transparent)}
.wke-chip-tag{color:var(--wke-meta,#2f6fa8);background:color-mix(in srgb, var(--wke-meta,#2f6fa8) 12%, transparent)}
.wke-chip-work{color:var(--wke-lang,#9a6a3a);background:color-mix(in srgb, var(--wke-lang,#9a6a3a) 12%, transparent)}
.wke-chip::before{content:attr(data-pre);opacity:.5;margin-right:2px;font-weight:500}
`;
function injectLiveStyle() {
  if (document.getElementById('wke-style-live')) return;
  const s = document.createElement('style'); s.id = 'wke-style-live'; s.textContent = LIVE_CSS; document.head.appendChild(s);
}

// Inline ref patterns → chip kind + the "marker" prefix shown faintly on the chip.
const REFS = [
  { re: /\[\[([^\]\n]+)\]\]/g, kind: 'link', pre: '', label: (m) => m[1] },
  { re: /\bwork:\/\/[^\s)]*[A-Za-z0-9_/#-]/g, kind: 'work', pre: '', label: (m) => m[0] },
  { re: /(^|[^\w&])#([a-z][\w-]*)/g, kind: 'tag', pre: '#', label: (m) => m[2], at: (m) => m.index + m[1].length },
];

export function workLiveFromView(view) {
  injectLiveStyle();
  const { Decoration, ViewPlugin, WidgetType, EditorView } = view;

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

  function build(v) {
    const decos = [];
    const sel = v.state.selection.main;
    const touches = (from, to) => sel.from <= to && sel.to >= from;
    const doc = v.state.doc;

    for (const { from, to } of v.visibleRanges) {
      let lineNo = doc.lineAt(from).number;
      const lastLine = doc.lineAt(to).number;
      for (; lineNo <= lastLine; lineNo++) {
        const line = doc.line(lineNo);
        const text = line.text;

        // Heading: style the line; hide the leading `#`s unless the cursor is on the line.
        const h = /^(#{1,6})\s/.exec(text);
        if (h) {
          decos.push(Decoration.line({ class: 'wke-h' + h[1].length }).range(line.from));
          if (!touches(line.from, line.to)) {
            decos.push(Decoration.replace({}).range(line.from, line.from + h[1].length + 1));
          }
          continue; // don't chip inside a heading line
        }

        // Inline refs → chips, revealed (left raw) when the selection touches them.
        for (const spec of REFS) {
          spec.re.lastIndex = 0;
          let m;
          while ((m = spec.re.exec(text)) !== null) {
            const start = line.from + (spec.at ? spec.at(m) : m.index);
            const full = spec.label(m);
            const matched = spec.at ? m[0].slice(m[1].length) : m[0];
            const end = start + matched.length;
            if (end <= start) continue;
            if (touches(start, end)) continue; // cursor here → show raw syntax
            decos.push(Decoration.replace({ widget: new Chip(full, spec.kind, spec.pre) }).range(start, end));
          }
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
  return [plugin];
}
