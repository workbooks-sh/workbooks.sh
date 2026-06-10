# For Waldo — how to grow this page

Your content is a **runtime CMS — no build step**. The page fetches a manifest
and your HTML partials on every load, exactly like the blog. You drop a file and
add a row; it appears on the next page load. You never run `bun run build` to
ship a section.

## The content layout (served from the site root)

Everything lives under `public/content/` (Vite copies `public/` into `dist/`
verbatim — that's how the partials ship). Three things:

```
public/
  content/
    sections.json              # ordered manifest of your page sections
    sections/NN-slug.html      # one <section class="grown"> partial each
    blog.json                  # manifest of blog posts (index + on-page listing)
  blog/<slug>.html             # the blog post pages themselves
```

### `content/sections.json` — the page-section manifest
An ordered array. `order` is the page position; the page renumbers the kickers
from it, so the printed "NN ·" is always correct even if you skip numbers.

```json
[
  { "order": 4, "slug": "the-workbook", "title": "What's a workbook",
    "file": "content/sections/04-the-workbook.html" }
]
```

- The human shell owns positions up to **03**. Your sections start at **04+**.
- An **faq** entry is **always last** regardless of its number — add
  `"pin": "last"` and it sorts after every other section.

### `content/sections/NN-slug.html` — a section partial
A complete `<section class="grown">` fragment. **No Svelte, no `<script>`.**
Kicker + h2 + prose, using the page's conventions:

```html
<section class="grown">
  <div class="kicker">04 · the workbook</div>
  <h2>Your headline</h2>
  <p>One or two honest paragraphs — terse, plain, the page voice.</p>
</section>
```

The page injects this into `#grown`, stamps `data-grown="NN-slug"` on it (so the
follow-mode cursor can still find it), renumbers the kicker, and wires
scroll-reveal. Empty/missing manifest → nothing renders (no errors).

### `content/blog.json` — the blog manifest
The **single source** for both the `/blog` index and the on-page "from the
agent's desk" listing. Add a post here and it can never be forgotten from the
listing.

```json
[
  { "slug": "lovable-alternative",
    "title": "Lovable alternative: open-source, runs on your desktop",
    "date": "2026-06-10",
    "excerpt": "One-sentence summary.",
    "tag": "compare",
    "file": "blog/lovable-alternative.html" }
]
```

## Adding a section (the whole flow)
1. Write `public/content/sections/NN-slug.html` (the partial above).
2. Add its row to `public/content/sections.json`.
3. Run the check (below). Commit. It's live on the next load — no build.

## Validate before deploy
`node scripts/check-content.mjs` (no deps) verifies the tree:
- every `sections.json` / `blog.json` row points at a file that exists;
- every `content/sections/*.html` and `blog/*.html` has a manifest row (no orphans);
- no duplicate `order`s; any `faq` / `pin:"last"` entry sorts last;
- each section partial has exactly one `<section class="grown">` and an `<h2>`.

It exits non-zero with one clear message per problem. This is what catches
"wrote a file but forgot the manifest row" or "added a row but no file".

## Build (only for the human shell — NOT your content)
`bun install` then `bun run build` rebuilds the Svelte shell (hero, the three
human sections, the engine) into `dist/`. Your content does **not** need it —
partials ship by being committed under `public/content/`.
