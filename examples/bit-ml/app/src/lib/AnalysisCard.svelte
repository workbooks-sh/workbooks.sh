<script>
  // §4.4 — an ANALYSIS / OPINION card. A DIFFERENT register from the news
  // clusters: byline-forward, serif head, NO image, a quieter typographic
  // treatment. The writer's name leads (this is commentary, signed). Sits in
  // the bordered-off ANALYSIS band (the one sanctioned subtle rule).
  import { brandify } from './brands.js';
  import Byline from './Byline.svelte';

  let { head = '', dek = '', read = '', byline, onagent, href = null } = $props();

  const headHtml = $derived(brandify(head));
  const dekHtml = $derived(brandify(dek));
</script>

<article class="analysis">
  <div class="kicker mono">Analysis{#if byline} · by {byline.writer?.name}{/if}</div>
  <h3 class="head serif">
    {#if href}<a class="headlink" {href}>{@html headHtml}</a>{:else}{@html headHtml}{/if}
  </h3>
  {#if dek}<p class="dek">{@html dekHtml}</p>{/if}
  <div class="foot">
    {#if byline}<Byline {...byline} {onagent} />{/if}
    {#if read}<span class="read mono">{read} read</span>{/if}
  </div>
</article>

<style>
  .analysis { min-width: 0; }
  .kicker {
    font-size: 10.5px; color: var(--ink-3);
    text-transform: uppercase; letter-spacing: 0.08em;
    margin-bottom: 12px;
  }
  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 22px; line-height: 1.15; font-weight: 600;
    font-optical-sizing: auto;
    letter-spacing: -0.012em;
    color: var(--ink); text-wrap: balance;
  }
  .headlink { color: inherit; text-decoration: none; }
  .headlink:hover { color: var(--wire); }
  .dek {
    margin: 12px 0 0;
    /* the quieter register: serif italic body, not the grotesk deks elsewhere */
    font-family: var(--serif);
    font-size: 16px; line-height: 1.55; color: var(--ink-2);
    font-style: italic; letter-spacing: -0.004em;
    max-width: 46ch;
  }
  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 14px; flex-wrap: wrap; margin-top: 16px;
  }
  .read {
    font-size: 11px; color: var(--ink-3);
    text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
  }
</style>
