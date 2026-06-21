// workedit/nested — real inner-language highlighting for `do…end` block bodies (P5). For each top-level
// block it picks the language (from the opener's `<lang> do`, default elixir), parses the body with that
// language's real CodeMirror parser, and emits decorations via highlightTree. Languages without a
// package fall back to the approximate `.work` tokenizer (lang-stream), so nothing goes unhighlighted.
//
// Pure highlightTree over the host view's namespace — the parsers/highlighter are standalone (not
// installed as editor facets), so there's no cross-package state-singleton trap. Parsers load lazily
// (only when a block of that language is visible) and trigger a redraw when ready.

import { highlightTree, classHighlighter } from 'https://esm.sh/@lezer/highlight@1';
import { token, startState, Stream } from './lang-stream.js';

// Registry: language key → loader returning its Lezer parser. Wrapped so a missing/renamed export or a
// 404 just disables that language (its bodies fall back to the approximate tokenizer).
const PARSERS = {
  elixir: () => import('https://esm.sh/codemirror-lang-elixir@4').then((m) => (m.elixirLanguage || m.elixir().language).parser),
  javascript: () => import('https://esm.sh/@codemirror/lang-javascript@6').then((m) => m.javascriptLanguage.parser),
  jsx: () => import('https://esm.sh/@codemirror/lang-javascript@6').then((m) => m.jsxLanguage.parser),
  tsx: () => import('https://esm.sh/@codemirror/lang-javascript@6').then((m) => m.tsxLanguage.parser),
  typescript: () => import('https://esm.sh/@codemirror/lang-javascript@6').then((m) => (m.typescriptLanguage || m.javascriptLanguage).parser),
  rust: () => import('https://esm.sh/@codemirror/lang-rust@6').then((m) => m.rustLanguage.parser),
  python: () => import('https://esm.sh/@codemirror/lang-python@6').then((m) => m.pythonLanguage.parser),
  cpp: () => import('https://esm.sh/@codemirror/lang-cpp@6').then((m) => m.cppLanguage.parser),
  go: () => import('https://esm.sh/@codemirror/lang-go@6').then((m) => m.goLanguage.parser),
  svelte: () => import('https://esm.sh/@replit/codemirror-lang-svelte@6').then((m) => m.svelteLanguage.parser),
};
// `.work` lang tag → registry key. Unmapped tags (zig, wit, …) use the approximate fallback.
const ALIAS = {
  elixir: 'elixir', ex: 'elixir', js: 'javascript', javascript: 'javascript', ts: 'typescript',
  typescript: 'typescript', jsx: 'jsx', tsx: 'tsx', solid: 'jsx', rust: 'rust', rs: 'rust',
  python: 'python', py: 'python', c: 'cpp', cpp: 'cpp', go: 'go', svelte: 'svelte',
};

// classHighlighter emits `tok-*` classes; map them to the shared --wke-* palette (with hex fallbacks).
const NESTED_CSS = `
.cm-content .tok-keyword,.cm-content .tok-controlKeyword,.cm-content .tok-moduleKeyword,.cm-content .tok-operatorKeyword{color:var(--wke-kw,#7c63cf)}
.cm-content .tok-string,.cm-content .tok-string2,.cm-content .tok-regexp,.cm-content .tok-special{color:var(--wke-str,#149157)}
.cm-content .tok-comment,.cm-content .tok-lineComment,.cm-content .tok-blockComment{color:var(--wke-comment,#8a8f88);font-style:italic}
.cm-content .tok-number,.cm-content .tok-integer,.cm-content .tok-float,.cm-content .tok-bool,.cm-content .tok-null{color:var(--wke-num,#c2861f)}
.cm-content .tok-atom,.cm-content .tok-labelName{color:var(--wke-atom,#2f6fa8)}
.cm-content .tok-typeName,.cm-content .tok-className,.cm-content .tok-namespace,.cm-content .tok-tagName,.cm-content .tok-standard{color:var(--wke-type,#b06a1f)}
.cm-content .tok-propertyName,.cm-content .tok-attributeName{color:var(--wke-type,#b06a1f)}
.cm-content .tok-function,.cm-content .tok-macroName,.cm-content .tok-definition{color:var(--wke-atom,#2f6fa8)}
.cm-content .tok-operator,.cm-content .tok-derefOperator,.cm-content .tok-punctuation,.cm-content .tok-bracket{color:var(--wke-op,#6a6f68)}
`;
function injectNestedStyle() {
  if (document.getElementById('wke-style-nested')) return;
  const s = document.createElement('style'); s.id = 'wke-style-nested'; s.textContent = NESTED_CSS; document.head.appendChild(s);
}

// The language declared on an opener line (the word right before `do`), if it's one we know.
function langOf(text) {
  const m = /\b([a-z][a-z0-9+]*)\s+do\s*(#.*)?$/.exec(text);
  if (m && (ALIAS[m[1]] || PARSERS[m[1]])) return m[1];
  return 'elixir'; // default — most .work blocks are Elixir
}

// Top-level blocks: openers/closers sit at column 0 (bodies are indented), so we don't need to count
// inner do/end. Returns [{from, to, lang}] body ranges.
function scanBlocks(doc) {
  const blocks = [];
  let open = null, lang = null;
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i), t = line.text;
    if (open === null) {
      if (/^[a-z]\w*\b.*\bdo\s*(#.*)?$/.test(t) && !/\bdo:/.test(t)) { open = line; lang = langOf(t); }
    } else if (/^end\b/.test(t)) {
      if (line.from > open.to + 1) blocks.push({ from: open.to + 1, to: line.from, lang });
      open = null; lang = null;
    }
  }
  return blocks;
}

export function workNestedFromView(view, state) {
  injectNestedStyle();
  const { Decoration, ViewPlugin } = view;
  const Redraw = state.StateEffect.define();
  const parserCache = new Map();   // key → parser | null (null = unavailable)
  const loading = new Set();
  const markCache = new Map();
  const mark = (cls) => { let m = markCache.get(cls); if (!m) { m = Decoration.mark({ class: cls }); markCache.set(cls, m); } return m; };

  // Returns parser | null (no package) | undefined (still loading).
  function ensureParser(key, v) {
    if (parserCache.has(key)) return parserCache.get(key);
    if (!PARSERS[key]) { parserCache.set(key, null); return null; }
    if (!loading.has(key)) {
      loading.add(key);
      PARSERS[key]()
        .then((p) => { parserCache.set(key, p || null); loading.delete(key); v.dispatch({ effects: Redraw.of(null) }); })
        .catch(() => { parserCache.set(key, null); loading.delete(key); });
    }
    return undefined;
  }

  // Approximate body highlight (lang-stream tokenizer primed into code context) — the fallback.
  function approxBody(text, base, decos) {
    const st = startState(); st.inBlock = true; st.depth = 1;
    let off = 0;
    for (const ln of text.split('\n')) {
      const s = new Stream(ln);
      let g = 0;
      while (!s.eol() && g++ < 5000) {
        const before = s.pos;
        const tok = token(s, st);
        if (s.pos === before) { s.next(); continue; }
        if (tok) decos.push(mark('wke-t-' + tok).range(base + off + before, base + off + s.pos));
      }
      off += ln.length + 1;
    }
  }

  function build(v) {
    const decos = [];
    for (const b of scanBlocks(v.state.doc)) {
      if (!v.visibleRanges.some((r) => b.from <= r.to && b.to >= r.from)) continue; // off-screen
      const bodyText = v.state.doc.sliceString(b.from, b.to);
      const key = ALIAS[b.lang] || (PARSERS[b.lang] ? b.lang : null);
      if (key) {
        const parser = ensureParser(key, v);
        if (parser === undefined) continue;             // loading; a redraw will follow
        if (parser) {
          try {
            highlightTree(parser.parse(bodyText), classHighlighter, (from, to, cls) => {
              if (cls) decos.push(mark(cls).range(b.from + from, b.from + to));
            });
            continue;
          } catch (_) { /* parse failed → approximate */ }
        }
      }
      approxBody(bodyText, b.from, decos);
    }
    return Decoration.set(decos, true);
  }

  return [ViewPlugin.fromClass(
    class {
      constructor(v) { this.decorations = build(v); }
      update(u) {
        if (u.docChanged || u.viewportChanged || u.transactions.some((tr) => tr.effects.some((e) => e.is(Redraw)))) {
          this.decorations = build(u.view);
        }
      }
    },
    { decorations: (v) => v.decorations },
  )];
}
