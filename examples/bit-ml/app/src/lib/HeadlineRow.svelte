<script>
  // §4.4 — the HEADLINE-LIST row. The core editorial texture of a section
  // cluster: one picture (the section lead), then MANY headlines. No image,
  // hairline-separated, dense. head (tight grotesk) + a short dek snippet +
  // a mono meta line (read time · byline). Brand marks render on the head.
  import { brandify } from './brands.js';
  import Byline from './Byline.svelte';

  let {
    head = '',
    dek = '',
    read = '',
    byline,
    onagent,
    href = null,
  } = $props();

  const headHtml = $derived(brandify(head));
  // a tight dek snippet — the headline list stays dense (one line of context)
  const snip = $derived(dek.length > 96 ? dek.slice(0, 95).replace(/\s+\S*$/, '') + '…' : dek);
</script>

<article class="row">
  <h3 class="head">
    {#if href}<a class="headlink" {href}>{@html headHtml}</a>{:else}{@html headHtml}{/if}
  </h3>
  {#if snip}<p class="snip">{snip}</p>{/if}
  <div class="meta mono">
    {#if read}<span class="read">{read} read</span>{/if}
    {#if byline}<Byline {...byline} {onagent} />{/if}
  </div>
</article>

<style>
  .row {
    padding: 14px 0;
    border-top: 1px solid var(--rule);    /* hairline-separated, dense */
  }
  .head {
    margin: 0;
    font-family: var(--sans);
    font-size: 17px; line-height: 1.28; font-weight: 590;
    letter-spacing: -0.02em;
    color: var(--ink);
    text-wrap: balance;
  }
  .headlink { color: inherit; text-decoration: none; }
  .headlink:hover { color: var(--wire); }
  .snip {
    margin: 5px 0 0;
    font-size: 14.5px; line-height: 1.45; color: var(--ink-2);
    letter-spacing: -0.006em;
  }
  .meta {
    display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap;
    margin-top: 8px;
  }
  .read {
    font-size: 11px; color: var(--ink-3);
    text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
  }
</style>
