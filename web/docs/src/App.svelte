<script>
  import { html, title } from 'virtual:org?./index.org'
</script>

<svelte:head>
  <title>{title}</title>
</svelte:head>

<main>
  <header class="hero">
    <p class="eyebrow">Documentation · <span class="mono">workbooks.sh</span></p>
    <h1>The workbook is<br />the unit.</h1>
    <p class="lede">One file carries its own code, data, and a query interface over both.
      Author in Org, render to HTML, publish anywhere.</p>
    <p class="actions">
      <a class="cta" href="https://github.com/workbooks-sh/workbooks.sh">View source on GitHub</a>
      <a class="textlink" href="https://workbooks.sh">workbooks.sh &rarr;</a>
    </p>
  </header>

  <div class="doc-body">
    {@html html}
  </div>

  <footer>
    <p>This page is a workbook — authored in Org, rendered by the OQL kernel, published with <span class="mono">wb publish</span>.</p>
  </footer>
</main>

<style>
  /* ---- design tokens (mirror lander) -------------------------------- */
  :global(:root) {
    --bg:      #1a1a1f;
    --surface: #25252b;
    --fg:      #f4f4f5;
    --line:    rgba(244,244,245,.06);
    --divider: rgba(244,244,245,.12);
    --muted:   rgba(244,244,245,.55);
    --dim:     rgba(244,244,245,.40);
    --ok:      #34d399;
    --sans: "Geist", system-ui, -apple-system, sans-serif;
    --mono: "Geist Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
  }

  @media (prefers-color-scheme: light) {
    :global(:root) {
      --bg:      #f7f7f8;
      --surface: #ffffff;
      --fg:      #1a1a1f;
      --line:    rgba(26,26,31,.07);
      --divider: rgba(26,26,31,.12);
      --muted:   rgba(26,26,31,.58);
      --dim:     rgba(26,26,31,.42);
      --ok:      #059669;
    }
  }

  :global(*, *::before, *::after) { box-sizing: border-box; margin: 0; padding: 0; }
  :global(html) { -webkit-text-size-adjust: 100%; }

  :global(body) {
    background: var(--bg);
    color: var(--fg);
    font-family: var(--sans);
    font-weight: 300;
    line-height: 1.55;
    letter-spacing: -.005em;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }

  /* ---- layout ------------------------------------------------------- */
  main {
    max-width: 720px;
    margin: 0 auto;
    padding: 0 24px;
  }

  .mono { font-family: var(--mono); font-weight: 400; letter-spacing: 0; }

  .eyebrow {
    font-family: var(--mono);
    font-weight: 400;
    font-size: .8rem;
    letter-spacing: .02em;
    color: var(--muted);
  }

  /* ---- hero --------------------------------------------------------- */
  .hero {
    padding: clamp(5rem, 14vh, 9rem) 0 clamp(3rem, 7vh, 4.5rem);
  }

  .hero h1 {
    margin: 1.4rem 0;
    font-size: clamp(2.4rem, 7vw, 4rem);
    font-weight: 600;
    line-height: 1.04;
    letter-spacing: -.025em;
  }

  .lede {
    max-width: 60ch;
    font-size: 1.12rem;
    color: var(--fg);
  }

  .actions {
    display: flex;
    align-items: center;
    gap: 1.6rem;
    margin-top: 2.2rem;
    flex-wrap: wrap;
  }

  .cta {
    font-family: var(--mono);
    font-weight: 500;
    font-size: .92rem;
    color: var(--bg);
    background: var(--fg);
    text-decoration: none;
    padding: .72rem 1.25rem;
    border-radius: 7px;
    border: 1px solid var(--fg);
    transition: opacity .15s ease;
  }
  .cta:hover { opacity: .82; }

  .textlink {
    font-family: var(--mono);
    font-size: .88rem;
    color: var(--muted);
    text-decoration: none;
    border-bottom: 1px solid var(--divider);
    padding-bottom: 2px;
    transition: color .15s ease;
  }
  .textlink:hover { color: var(--fg); }

  /* ---- doc body (org-rendered content) ------------------------------ */
  .doc-body {
    border-top: 1px solid var(--divider);
    padding-top: clamp(2rem, 5vh, 3rem);
  }

  :global(.doc-body h1) { display: none; } /* title is the hero h1 */

  :global(.doc-body h2) {
    font-size: 1.25rem;
    font-weight: 600;
    letter-spacing: -.015em;
    margin: clamp(2.5rem, 6vh, 3.5rem) 0 .9rem;
    padding-top: clamp(2rem, 5vh, 2.6rem);
    border-top: 1px solid var(--divider);
    color: var(--fg);
  }

  :global(.doc-body h2:first-of-type) {
    margin-top: 0;
    padding-top: 0;
    border-top: 0;
  }

  :global(.doc-body h3) {
    font-family: var(--mono);
    font-size: .88rem;
    font-weight: 500;
    letter-spacing: .01em;
    color: var(--muted);
    margin: 1.8rem 0 .6rem;
    text-transform: uppercase;
  }

  :global(.doc-body p) {
    max-width: 64ch;
    font-size: 1.06rem;
    margin-bottom: 1rem;
    color: var(--fg);
  }

  :global(.doc-body a) {
    color: var(--fg);
    text-underline-offset: 3px;
  }
  :global(.doc-body a:hover) { color: var(--muted); }

  :global(.doc-body code) {
    font-family: var(--mono);
    font-size: .88em;
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: .1em .35em;
  }

  :global(.doc-body pre) {
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 1.1rem 1.3rem;
    overflow-x: auto;
    margin: 1.2rem 0;
  }

  :global(.doc-body pre code) {
    font-size: .84rem;
    line-height: 1.75;
    background: none;
    border: none;
    padding: 0;
  }

  :global(.doc-body table) {
    width: 100%;
    border-collapse: collapse;
    font-size: .92rem;
    margin: 1.4rem 0;
  }

  :global(.doc-body th) {
    font-family: var(--mono);
    font-size: .78rem;
    font-weight: 500;
    letter-spacing: .03em;
    text-transform: uppercase;
    color: var(--muted);
    text-align: left;
    padding: .5rem .75rem;
    border-bottom: 1px solid var(--divider);
  }

  :global(.doc-body td) {
    padding: .55rem .75rem;
    border-bottom: 1px solid var(--line);
    color: var(--fg);
    vertical-align: top;
  }

  :global(.doc-body td code) { font-size: .82em; }

  /* ---- footer ------------------------------------------------------- */
  footer {
    margin-top: clamp(3rem, 7vh, 4.5rem);
    padding: 2.2rem 0 3rem;
    border-top: 1px solid var(--divider);
  }

  footer p {
    font-size: .82rem;
    color: var(--dim);
    letter-spacing: .01em;
  }
</style>
