# orgitorial — integrate

# When to use this

Read this when your task is to *plug orgitorial into a site* — a static page,
a server-rendered template, a single HTML file, or a component framework. The
job is always the same shape: get the org text, call `render()`, drop the
string into the page, and link the stylesheet. Everything else is delivery.

# The two assets

- `dist/orgitorial.js` — the renderer. Zero dependencies. Exposes
  `render(orgText, opts)` and `parseMeta(orgText)` three ways:
  - ES module: `import { render } from "./orgitorial.js"`
  - browser global: load via `<script>`, then call `window.Orgitorial.render`
  - CommonJS: `const { render } ` require("./orgitorial.js")=
- `dist/orgitorial.css` — the skin. Link it once; it styles every class the
  renderer emits.

The renderer is *pure string→string*. It needs no DOM and no Node APIs, so the
same file runs in a browser tag, in Node at build time, and in the runtime's
QuickJS wasm lane. That portability is the point — pick the delivery that fits
the site, the renderer doesn't change.

# The three-line minimum (browser)

```html
<link rel="stylesheet" href="orgitorial.css">
<div id="post"></div>
<script src="orgitorial.js"></script>
<script>
  document.getElementById("post").innerHTML =
    Orgitorial.render("#+TITLE: Hello\n\nMy *first* org post.");
  Orgitorial.activate(document);   // ← bring living blocks alive (see below)
</script>
```

# The activate() step (living blocks)

`render()` alone gives you a styled, static post. If the org uses *living
blocks* — a `#+begin_src mermaid` diagram, a `#+begin_src html :app` mini-app,
or `#+begin_export html` — the host page MUST call `Orgitorial.activate(document)`
(or any root element) once, AFTER the rendered HTML is in the DOM:

```html
<script type="module">
  import { render, activate } from "./orgitorial.js";
  document.getElementById("post").innerHTML = render(org);
  activate(document);
</script>
```

Why it's separate: `render()` is pure string→string and *zero-dependency* by
law — it can't fetch a CDN or run scripts. `activate()` is the browser-only opt-in
that does both. It is idempotent (safe to call again after appending more posts).

- *Live app scripts.* Inline `<script>` injected via `innerHTML` never executes;
  `activate()` re-creates each script node so it runs — including =type=module=.
- *Mermaid CDN.* `activate()` lazy-loads mermaid *only if* a `.org-mermaid` block
  exists — zero cost on diagram-free pages. Default source:
  `https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs` (override with
  `activate(root, { mermaidCdn, mermaidTheme })`). If the CDN is blocked, the
  diagram degrades to its readable source `<pre>` — never a blank.
- *Wasm / module payloads.* A module script in an `:app` block may `import` wasm
  (e.g. a candle-compiled model) — it rides the standard module loader, nothing
  special is wired. Keep those payloads lean; you're shipping them to a reader.

If you prerender at build time (next section), you still ship `activate()` as a
small client script for pages that have living blocks; diagram-free, app-free
posts need no client JS at all.

That is a complete, styled blog post. Fetch the org from a `.org` file instead
of inlining it when you have real content:

```html
<script>
  fetch("posts/hello.org").then(r => r.text()).then(org => {
    document.getElementById("post").innerHTML = Orgitorial.render(org);
  });
</script>
```

# Build-time prerender (no JS shipped to the client)

Render once at build time and ship static HTML — the renderer runs anywhere a
string transform runs.

In Node:

```bash
node -e "import('./dist/orgitorial.js').then(async m => {
  const fs = await import('node:fs');
  const org = fs.readFileSync('posts/hello.org','utf8');
  fs.writeFileSync('public/hello.html', m.render(org));
})"
```

In the runtime's JS lane (QuickJS wasm) it is the same call — no Node globals
are used by the renderer, so `render(orgText)` is all you need.

Use the metadata when prerendering to fill `<title>`, Open Graph tags, an
index page, etc.:

```javascript
import { render, parseMeta } from "./orgitorial.js";
const meta = parseMeta(org);                 // { title, author, date, keywords:[] }
const html = render(org, { header: true });  // article incl. <header>
// or, both at once:
const { html, meta } = render(org, { meta: true });
```

# render() options

- `header` (default `true`) — emit `<header class`"org-header">= from the
  metadata (title/author/date/keywords). Set `false` to render body only
  (e.g. when you supply your own header chrome).
- `meta` (default `false`) — return `{ html, meta }` instead of a string.

# Using it from a framework (Svelte / React / anything)

Do *not* reach for a component library — orgitorial ships none on purpose.
Render the *string* and inject it. The class contract + CSS vars are what make
it framework-agnostic; the framework's only job is to place the HTML.

Svelte:

```svelte
<script>
  import { render } from "orgitorial";
  export let org;
  $: html = render(org);
</script>
<svelte:head><link rel="stylesheet" href="/orgitorial.css" /></svelte:head>
{@html html}
```

React:

```jsx
import { render } from "orgitorial";
export function Post({ org }) {
  return <div dangerouslySetInnerHTML={{ __html: render(org) }} />;
}
```

In both cases the markup is plain semantic HTML with stable classes, so it
inherits the linked `orgitorial.css` with no per-framework styling. To
re-skin, override `--org-*` vars (see `theming`) — never fork the renderer.

# The class contract is the API

The integration boundary is the set of classes the renderer emits
(`org-doc`, `org-h`, `org-src`, `org-check`, `org-drawer`, …). The CSS targets
exactly those. As long as you:

1. render the string through `render()`, and
2. link `orgitorial.css` (or your retheme of it),

…the post is styled correctly anywhere. The full catalog is in `components`;
the variables you override to re-skin are in `theming`.

# Done-when

The post renders with the editorial skin applied, `parseMeta` fills your page
head, and you wrote *no* framework-specific styling — you leaned on the class
contract and the CSS vars. If you found yourself editing `orgitorial.js` to
change appearance, stop: that is a `theming` task, done in CSS.
