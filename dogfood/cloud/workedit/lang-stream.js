// workedit/lang-stream — a zero-build StreamLanguage highlighter for `.work` files.
// This is P1 of the workedit island (bd wb-u0yz): a runtime-only CodeMirror 6 language (no Lezer
// compile step, so it ships on the dashboard's no-build/esm.sh path). It tokenizes the OUTER `.work`
// structure — prose lanes + `<kind> :name <lang> do … end` code blocks + inline refs — and applies a
// theme-aware HighlightStyle keyed to `--wke-*` CSS vars (light + dark). It deliberately does NOT do
// deep per-language parsing inside a block (that's P5: a real Lezer grammar with parseMixed nesting);
// it gives an Elixir-leaning tokenization that reads well for our blocks.
//
// Self-contained, island convention (mirrors wbchat): one async export returning CM6 extensions, own
// CSS injected once. Consume from any host that already has @codemirror/state + view loaded — import
// the SAME @6 majors so esm.sh dedupes the singletons (duplicate state/view silently break facets).

// The `.work` block kinds (first word of a `do … end` opener) + flat declaration keywords.
const KINDS = new Set([
  'data', 'def', 'server', 'client', 'flow', 'agent', 'record', 'resource', 'sandbox', 'hook',
  'check', 'toolkit', 'test', 'design', 'app', 'auth', 'task', 'user', 'type', 'deps', 'checks',
  'theme', 'show', 'query', 'workbook', 'nexus', 'grant', 'route', 'trigger', 'step', 'match',
]);
// Inner-language keywords (Elixir-leaning) so block bodies read sensibly until P5's real nesting.
const KW = new Set([
  'do', 'end', 'fn', 'defp', 'defmodule', 'defstruct', 'defmacro', 'if', 'else', 'unless', 'case',
  'cond', 'when', 'with', 'for', 'try', 'rescue', 'catch', 'after', 'receive', 'import', 'alias',
  'require', 'use', 'quote', 'unquote', 'and', 'or', 'not', 'in', 'raise', 'throw',
]);
const BOOLS = new Set(['nil', 'true', 'false']);
// Inner-language tags after the kind in an opener (`server :x elixir do`).
const LANGS = new Set(['elixir', 'rust', 'zig', 'python', 'svelte', 'solid', 'js', 'ts', 'c', 'cpp', 'go', 'wit']);

// Exported for tests (and reuse by P5's grammar work) — not part of the host-facing surface.
export function startState() { return { inBlock: false, depth: 0, pendingOpen: false, lineStart: false }; }

// A line opens a `do` block only if its FIRST WORD is a known kind AND it ends with `do` — so prose
// that happens to end in "do" ("…what to do") is NOT a false opener. Shared by nested.js/live.js.
export function isBlockOpener(text) {
  const m = /^([a-z]\w*)\b[^\n]*\bdo\s*(#.*)?$/.exec(text);
  return !!(m && KINDS.has(m[1]) && !/\bdo:/.test(text));
}

export function token(stream, state) {
  if (stream.sol()) state.lineStart = true;
  if (stream.eatSpace()) return null;

  const atLineStart = state.lineStart;
  // Decide block transitions from the *logical* line start (before consuming its first token).
  if (atLineStart && !state.inBlock) {
    const rest = stream.string.slice(stream.pos);
    // Heading (prose lane) — whole line.
    if (/^#{1,6}\s/.test(rest)) { stream.skipToEnd(); state.lineStart = false; return 'heading'; }
    if (isBlockOpener(rest)) state.pendingOpen = true;
  }
  state.lineStart = false;

  // Code context = inside a block, OR on the opener line (so its kind/:name/lang/do highlight).
  const code = state.inBlock || state.pendingOpen;

  // Inline refs are meaningful in BOTH lanes: :atom / @type are refs in prose and atoms in code.
  if (stream.match(/:[a-zA-Z_]\w*[?!]?/)) return 'atom';                      // :atom / :name
  if (stream.match(/@[a-z]\w*/)) return 'typeName';                          // @type / @attr

  // Prose-only refs + markdown (markers kept in Source mode; Live mode hides them). The `#` is a
  // comment in code, a #tag in prose.
  if (!code) {
    if (stream.match(/\[\[[^\]\n]+\]\]/)) return 'link';                       // [[backlink]]
    if (stream.match(/\[[^\]\n]+\]\([^)\s]+\)/)) return 'mdlink';              // [text](url)
    if (stream.match(/work:\/\/[^\s)]*[A-Za-z0-9_/#-]/)) return 'link';        // work:// link
    if (stream.match(/#[a-z][\w-]*/)) return 'meta';                          // #tag
    if (stream.match(/`[^`\n]+`/)) return 'mdcode';                           // `inline code`
    if (stream.match(/(\*\*|__)(?=\S)[\s\S]+?\S\1/)) return 'strong';         // **bold**
    if (stream.match(/~~(?=\S)[\s\S]+?\S~~/)) return 'strike';                // ~~strike~~
    if (stream.match(/(\*|_)(?=\S)[^*_\n]+?\S?\1/)) return 'em';              // *italic*
    stream.next();                                                            // plain prose — no styling
    return null;
  }

  // ── code lane ──
  if (stream.peek() === '#') { stream.skipToEnd(); return 'comment'; }
  if (stream.match(/"(?:[^"\\]|\\.)*"/) || stream.match(/'(?:[^'\\]|\\.)*'/)) return 'string';
  if (stream.match(/\d[\d_]*(\.\d+)?/)) return 'number';

  const w = stream.match(/[A-Za-z_]\w*[?!]?/);
  if (w) {
    const word = w[0];
    // `do:` is keyword-list shorthand (`def f, do: x`), NOT a block opener — don't open a block.
    if (word === 'do') {
      if (stream.peek() === ':') return 'keyword';
      // A nested opener inside a block deepens the `do…end` count so the wrong `end` can't close it.
      if (state.pendingOpen) { state.inBlock = true; state.pendingOpen = false; }
      state.depth += 1; return 'keyword';
    }
    if (word === 'end') { state.depth -= 1; if (state.depth <= 0) { state.inBlock = false; state.depth = 0; } return 'keyword'; }
    if (KINDS.has(word) || KW.has(word)) return 'keyword';
    if (BOOLS.has(word)) return 'bool';
    if (LANGS.has(word)) return 'lang';
    if (/^[A-Z]/.test(word)) return 'typeName';                              // Module / Record name
    return null;
  }

  if (stream.match(/[=<>!&|+\-*/%~^]+/)) return 'operator';
  stream.next();
  return null;
}

// Token name → CSS color var. Classes are `wke-t-<name>`.
const TOKEN_CSS = {
  keyword: 'color:var(--wke-kw);font-weight:600', atom: 'color:var(--wke-atom)',
  string: 'color:var(--wke-str)', comment: 'color:var(--wke-comment);font-style:italic',
  number: 'color:var(--wke-num)', bool: 'color:var(--wke-bool)', typeName: 'color:var(--wke-type)',
  link: 'color:var(--wke-link);text-decoration:underline', meta: 'color:var(--wke-meta)',
  heading: 'color:var(--wke-heading);font-weight:700', operator: 'color:var(--wke-op)',
  lang: 'color:var(--wke-lang)',
  // markdown emphasis (Source mode keeps the markers, just styles the run)
  strong: 'font-weight:700', em: 'font-style:italic', strike: 'text-decoration:line-through;opacity:.8',
  mdcode: 'font-family:var(--mono,ui-monospace,monospace);background:color-mix(in srgb,var(--wke-op,#6a6f68) 12%,transparent);border-radius:4px',
  mdlink: 'color:var(--wke-link);text-decoration:underline',
};
const CSS = `
:root{
  --wke-kw:#7c63cf; --wke-atom:#2f6fa8; --wke-str:#149157; --wke-comment:#8a8f88;
  --wke-num:#c2861f; --wke-type:#b06a1f; --wke-link:#2f6fa8; --wke-meta:#2f6fa8;
  --wke-heading:#1a1b1e; --wke-op:#6a6f68; --wke-lang:#9a6a3a; --wke-bool:#c2861f;
}
[data-theme="dark"]{
  --wke-kw:#b9a6f0; --wke-atom:#88c0f0; --wke-str:#7fd6a0; --wke-comment:#7c8178;
  --wke-num:#e0b24f; --wke-type:#e0b87f; --wke-link:#88c0f0; --wke-meta:#88c0f0;
  --wke-heading:#ecebe5; --wke-op:#9aa097; --wke-lang:#d9b48f; --wke-bool:#e0b24f;
}
` + Object.keys(TOKEN_CSS).map((k) => `.wke-t-${k}{${TOKEN_CSS[k]}}`).join('\n');

function injectStyle() {
  if (document.getElementById('wke-style-lang')) return;
  const s = document.createElement('style'); s.id = 'wke-style-lang'; s.textContent = CSS; document.head.appendChild(s);
}

// Minimal CM6-compatible StringStream — the subset our tokenizer uses. Lets the highlighter run
// without @codemirror/language (whose facets need a state instance we can't guarantee matches the host).
// Exported so nested.js can reuse it for the approximate body fallback (langs with no real parser).
export class Stream {
  constructor(line) { this.string = line; this.pos = 0; }
  sol() { return this.pos === 0; }
  eol() { return this.pos >= this.string.length; }
  peek() { return this.string.charAt(this.pos) || undefined; }
  next() { return this.string.charAt(this.pos++) || undefined; }
  eatSpace() { const s = this.pos; while (/\s/.test(this.string.charAt(this.pos))) this.pos++; return this.pos > s; }
  skipToEnd() { this.pos = this.string.length; }
  match(re, consume = true) {
    if (typeof re === 'string') { if (this.string.startsWith(re, this.pos)) { if (consume) this.pos += re.length; return true; } return false; }
    const m = this.string.slice(this.pos).match(re);
    if (!m || m.index !== 0) return null;
    if (consume) this.pos += m[0].length;
    return m;
  }
}

// Build the `.work` highlighter as a ViewPlugin over the HOST's @codemirror/view namespace — uses the
// host's single state/view instance (no cross-package singleton mismatch). `view` = the @codemirror/view
// module. Block state (do…end) is tracked from doc start so nested blocks colour correctly.
export function workHighlightFromView(view, opts = {}) {
  injectStyle();
  const bodies = opts.bodies !== false;   // false ⇒ outer-only (nested.js colours block bodies)
  const { Decoration, ViewPlugin } = view;
  const marks = {};
  const markFor = (name) => marks[name] || (marks[name] = Decoration.mark({ class: 'wke-t-' + name }));

  function build(v) {
    const doc = v.state.doc;
    const decos = [];
    const st = startState();
    const last = doc.lines;
    for (let i = 1; i <= last; i++) {
      const line = doc.line(i);
      // When bodies are delegated to nested.js, skip a line that STARTS inside a block — except the
      // structural do/end keywords — so the outer highlighter only colours openers/prose/headings.
      const inBlockStart = st.inBlock;
      const s = new Stream(line.text);
      let guard = 0;
      while (!s.eol() && guard++ < 5000) {
        const before = s.pos;
        const tok = token(s, st);
        if (s.pos === before) { s.next(); continue; }
        if (!tok || !TOKEN_CSS[tok]) continue;
        const text = line.text.slice(before, s.pos);
        const emit = bodies || !inBlockStart || text === 'do' || text === 'end';
        if (emit) decos.push(markFor(tok).range(line.from + before, line.from + s.pos));
      }
    }
    return Decoration.set(decos, true);
  }

  return [ViewPlugin.fromClass(
    class {
      constructor(v) { this.decorations = build(v); }
      update(u) { if (u.docChanged || u.viewportChanged) this.decorations = build(u.view); }
    },
    { decorations: (v) => v.decorations },
  )];
}
