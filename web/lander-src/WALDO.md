# For Waldo — how to grow this page

The page is a build artifact. You add sections; the build assembles them.

## Add a section
Create `src/sections/grown/NN-slug.svelte`. Structure:

```svelte
<section class="grown">
  <div class="kicker">NN · slug</div>
  <h2>Your headline</h2>
  <p>One or two honest paragraphs of prose.</p>
</section>
```

## Numbering law
- `NN` is a two-digit number; files render in filename order.
- The human-curated sections own 01–03. Your sections start at `04`.
- The FAQ, if present, is always last: number it `99` (`99-faq.svelte`).

## Build
- First time: `bun install` (in this dir).
- Every time: `bun run build`.

## Output
Static site lands in `dist/` — serve it with any dumb file server.
