<script>
  // §4.2 The Wire (front-page lead band). NOT a hero — a LEAD. The newest /
  // most load-bearing bite at display size: mono dateline, Newsreader 44px
  // head, one-sentence dek, source row. A hairline below, then the stack.
  import { sectionOf } from './sections.js';
  import Byline from './Byline.svelte';

  let {
    section = 'AI',
    dateline = '',
    head = '',
    dek = '',
    sources = [],
    byline,
    onagent,
  } = $props();

  const sec = $derived(sectionOf(section));
</script>

<article class="lead">
  <div class="dateline mono">
    <span class="tick"></span>
    <span class="tag" style="color:{sec.color}">{sec.tag}</span>
    <span class="dot">·</span>
    <span class="when">{dateline}</span>
  </div>

  <h1 class="head serif">{head}</h1>

  {#if dek}<p class="dek">{dek}</p>{/if}

  <div class="foot">
    <span class="sources mono">{#if sources.length}sources: {sources.join(' · ')}{/if}</span>
    {#if byline}<Byline {...byline} {onagent} />{/if}
  </div>
</article>
<hr class="hair" />

<style>
  .lead { padding: 6px 0 26px; }

  .dateline {
    display: flex; align-items: center; gap: 8px;
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    margin-bottom: 16px;
  }
  .tick { width: 2px; height: 12px; display: inline-block; background: var(--ink); }
  .tag { font-weight: 500; }
  .dot { color: var(--rule); }
  .when { color: var(--ink-3); }

  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 44px; line-height: 1.05; font-weight: 600;
    /* display sizes → high-contrast optical end of Newsreader (§2) */
    font-optical-sizing: auto;
    letter-spacing: -0.02em;
    color: var(--ink);
    text-wrap: balance;
  }

  .dek {
    margin: 14px 0 0;
    font-size: 18px; line-height: 1.45; color: var(--ink-2);
    letter-spacing: -0.01em;
    max-width: 52ch;
  }

  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin-top: 20px; flex-wrap: wrap;
  }
  .sources { font-size: 11px; color: var(--ink-3); }

  @media (max-width: 600px) {
    .head { font-size: 32px; }
  }
</style>
