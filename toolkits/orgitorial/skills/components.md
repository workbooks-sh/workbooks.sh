# orgitorial — components

# When to use this

Read this when you need the *class contract* — the exact HTML each org
construct becomes, the stable classes the CSS targets, and which `--org-*`
vars shape each one. This is the reference both halves of the toolkit agree
on: change a class here and you change the public API. For writing the org,
see `authoring`; for the variable system, see `theming`.

# The contract, at a glance

Every construct maps to a fixed element + class. The renderer guarantees these;
the CSS styles exactly these.

| Construct        | Element + class                         | Notable hooks                         |
|------------------|-----------------------------------------|---------------------------------------|
| Document root    | `article.org-doc`                       | sets measure, paper, ink, rhythm      |
| Metadata header  | `header.org-header`                      | `h1.org-title`, `.org-meta`           |
| ↳ author/date    | `.org-author`, `.org-date`, `.org-keywords` | mono, faint                       |
| Headline L1–L4   | `h2..h5.org-h`                          | `.org-todo` / `.org-done` state       |
| ↳ TODO keyword   | `span.org-todo-kw`                       | chip; bg from todo/done vars          |
| ↳ tag            | `span.org-tag`                          | mono pill, accent                     |
| Paragraph        | `p.org-p`                               |                                       |
| Bold/italic/u/s  | `strong` / `em` / `u` / `del`           |                                       |
| Verbatim / code  | `code.org-verbatim` / `code.org-code`   | code is accent-colored                |
| Link / bare url  | `a.org-link` / `a.org-link-url`         | accent underline                      |
| Image            | `img.org-img`                           | bordered, centered                    |
| Timestamp        | `time.org-ts`                           | mono chip                             |
| List (un/ordered)| `ul.org-list` / `ol.org-list`           | `li.org-item`                         |
| Checkbox item    | `li.org-check[data-checked]`            | `true` / `false` / `partial`          |
| Source block     | `pre.org-src.org-block[data-lang]`      | `code.org-src-code.language-<lang>`   |
| Mermaid block    | `div.org-block.org-mermaid`             | raw text in `pre.org-mermaid-src`     |
| Live mini-app    | `div.org-block.org-app`                 | inline HTML; scripts run on `activate()` |
| Width modifier   | =[data-width=column\vert{}wide\vert{}full]` + `.org-w-*= | on any src/quote/app/mermaid block |
| Example block    | `pre.org-example`                       | literal, no language bar              |
| Quote            | `blockquote.org-quote.org-block`        | accent rule + glyph; takes `:width`   |
| Verse            | `p.org-verse`                           | line breaks preserved                 |
| Table            | `table.org-table`                       | `thead/tbody`, `th/td`                 |
| Drawer           | `details.org-drawer`                     | `summary.org-drawer-name`, `.org-prop`|
| Footnote ref     | `sup.org-fnref`                          | links to definition                   |
| Footnotes block  | `section.org-footnotes` > `ol.org-fn-list` | `li.org-fn`, `.org-fn-back`        |
| Horizontal rule  | `hr.org-rule`                           | centered, glyph marker                |
| Unsupported      | `p.org-raw` / `pre.org-raw[data-block]` | escaped, preserved — never dropped    |

# Anatomy of the load-bearing components

## Headline with state and tags

```html
<h2 class="org-h org-todo">
  <span class="org-todo-kw">TODO</span> Ship it
  <span class="org-tag">planning</span>
</h2>
```

- `.org-todo` vs `.org-done` switches the chip background
  (`--org-todo-bg/-ink` vs `--org-done-bg/-ink`).
- `h2..h5` sizes are fixed steps; `h5` renders as a mono eyebrow.

## Source block (header bar shows the language)

```html
<pre class="org-src" data-lang="javascript">
  <code class="org-src-code language-javascript">…escaped code…</code>
</pre>
```

- The language bar is a CSS `::before` reading `attr(data-lang)` — no markup
  cost. Empty/absent lang falls back to the label "src".
- Code is HTML-escaped by the renderer. The `language-*` class is the hook for
  a third-party highlighter; orgitorial ships none.

## Checkbox item

```html
<li class="org-check" data-checked="true">Done item</li>
<li class="org-check" data-checked="false">Open item</li>
<li class="org-check" data-checked="partial">In progress</li>
```

The box is drawn entirely in CSS from `data-checked` (`::before` box,
`::after` check/dash). No icon font, no SVG.

## Drawer (collapsed metadata)

```html
<details class="org-drawer">
  <summary class="org-drawer-name">PROPERTIES</summary>
  <div class="org-prop">
    <span class="org-prop-key">ID</span>
    <span class="org-prop-val">my-post</span>
  </div>
</details>
```

Renders collapsed; the disclosure triangle is CSS, the summary is mono.

## Footnotes

```html
<sup class="org-fnref" id="fnref-1"><a href="#fn-1">[1]</a></sup>
…
<section class="org-footnotes">
  <h2 class="org-fn-title">Footnotes</h2>
  <ol class="org-fn-list">
    <li class="org-fn" id="fn-1">
      <a class="org-fn-back" href="#fnref-1">1</a>
      <span class="org-fn-body">the note text</span>
    </li>
  </ol>
</section>
```

Ref and definition cross-link both ways; `:target` highlights the landed note.

# Living blocks: the three block types

These turn a static article into a workbook. They share one rule the CSS
enforces: a living block *never inner-scrolls* (`height: auto`, no `max-height`,
no `overflow: scroll`) and may break out of the editorial measure.

## Mermaid diagram — `#+begin_src mermaid`

The renderer stays zero-dep: it emits the raw diagram text, it does *not* draw
it. Drawing is a HOST-PAGE opt-in via `activate()` (below).

```html
<div class="org-block org-mermaid">
  <pre class="org-mermaid-src">flowchart LR
  A --> B</pre>
</div>
```

After `activate()`, the `<pre>` is replaced by `<div class`"org-mermaid-svg">=
(the rendered SVG) and the source is kept as a collapsed
`details.org-mermaid-fallback`. If the CDN is unreachable, the readable `<pre>`
stays — never a blank.

## Live mini-app — `#+begin_src html :app` (or `#+begin_export html`)

First-party authored HTML, emitted *inline and un-escaped* — same trust model as
the existing `{@html}` note in `integrate`. No chrome: the app owns its look.

```html
<div class="org-block org-app">
  <button id="b">click</button>
  <script>document.getElementById("b").onclick = …;</script>
</div>
```

Inline `<script>` tags (incl. =type=module=) do *not* run from injected
innerHTML — `activate()` re-creates each script node so it executes. A module
script may `import` wasm (e.g. a candle-compiled model); nothing special is done
for it, it rides the standard module loader.

## Width — `:width column|wide|full` on any src/quote/app/mermaid block

Adds `data-width`"wide|full"` + `.org-w-wide|full=. Default `column` emits
neither (stays in the measure).

- `wide` → `width: min(92vw, measure + 24rem)`, centered breakout.
- `full` → full-bleed `100vw` via the centered margin-inline calc.

# The `activate()` contract

`render()` is pure string→string and zero-dep. `activate(rootEl, opts)` is the
*optional, browser-only* second step that brings living blocks to life. THE HOST
PAGE MUST CALL `Orgitorial.activate(document)` (or a root element) AFTER injecting
the rendered HTML — otherwise app scripts never run and mermaid never draws.

```html
<div id="post"></div>
<script type="module">
  import { render, activate } from "./orgitorial.js";
  document.getElementById("post").innerHTML = render(orgText);
  activate(document);                  // ← brings .org-app + .org-mermaid alive
</script>
```

- It is *idempotent* — guards each node with `data-org-activated`; safe to call
  again after appending more posts.
- It only fetches mermaid (from `opts.mermaidCdn`, default jsDelivr
  `mermaid@11`) when at least one `.org-mermaid` exists — zero cost otherwise.
- `opts.mermaidTheme` (default `"neutral"`) sets the mermaid theme.
- Headless (no `document`) it returns a resolved promise and does nothing —
  safe to import in Node/QuickJS where only `render` is used.

# CSS variables each component reads

All components inherit the document vars; these are the ones worth knowing per
group (full list + defaults in `theming`):

| Component group       | Primary vars                                              |
|-----------------------|----------------------------------------------------------|
| Document / measure    | `--org-paper`, `--org-ink`, `--org-measure`, `--org-fs`, `--org-lh` |
| Headlines             | `--org-ink`, `--org-rule` (h2 underline)                 |
| TODO/DONE chips       | `--org-todo-bg/-ink`, `--org-done-bg/-ink`               |
| Tags / pills          | `--org-accent`, `--org-accent-soft`, `--org-rule-strong` |
| Links / code accents  | `--org-accent`                                            |
| Panels (src/example/drawer) | `--org-panel`, `--org-panel-bar`, `--org-rule`     |
| Quote / verse rules   | `--org-accent`, `--org-rule-strong`                      |
| Tables                | `--org-rule`, `--org-ink` (header underline)             |
| Type families         | `--org-serif`, `--org-sans`, `--org-mono`                |

# Copy-paste: a minimal styled fragment

To preview a single component without the renderer, hand-write the contract
HTML and link `orgitorial.css`:

```html
<link rel="stylesheet" href="orgitorial.css">
<article class="org-doc">
  <h2 class="org-h org-done"><span class="org-todo-kw">DONE</span> Looks right</h2>
  <p class="org-p">Body with <code class="org-code">inline</code> bits.</p>
  <ul class="org-list">
    <li class="org-check" data-checked="true">checked</li>
    <li class="org-check" data-checked="false">unchecked</li>
  </ul>
</article>
```

Because the contract is fixed, anything the renderer emits will match this
exactly — that is the guarantee that lets you re-skin with confidence.

# Done-when

You can name the element + class for any construct the post uses, and you
re-skinned by setting vars (not by rewriting class rules or the renderer). If
a needed construct has no class here, it is unsupported by design — it renders
as `.org-raw` (see `authoring`).
