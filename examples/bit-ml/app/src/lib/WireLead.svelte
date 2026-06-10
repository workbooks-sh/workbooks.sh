<script>
  // §4.2 The Wire (front-page lead band). NOT a hero — a LEAD. The newest /
  // most load-bearing bite at display size: mono dateline with section badge,
  // Newsreader 44px head, one-sentence dek, source row. A hairline below,
  // then the stack. Optional banner image (§4.5 note 3): rendered below dek,
  // full-column, radius var(--r); missing/404 → renders nothing (onerror hide).
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
    href = null,   // /story/<slug> — the lead head links into the story
    banner = null,       // optional: path to banner image
    bannerAlt = '',
  } = $props();

  const sec = $derived(sectionOf(section));
</script>

<article class="lead">
  <div class="dateline mono">
    <!-- section badge: tiny icon + tag, tinted wash, color text (§4.2/§4.3) -->
    <span
      class="sec-badge"
      style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
    >{@html sec.icon}{sec.tag}</span>
    <span class="dot">·</span>
    <span class="when">{dateline}</span>
  </div>

  <h1 class="head serif">{#if href}<a class="headlink" {href}>{head}</a>{:else}{head}{/if}</h1>

  {#if dek}<p class="dek">{dek}</p>{/if}

  {#if banner}
    <!-- banner: full-column, radius, no border; onerror hides it (§4.5 note 3) -->
    <img
      class="banner"
      src={banner}
      alt={bannerAlt}
      loading="lazy"
      onerror={(e) => { e.currentTarget.style.display = 'none'; }}
    />
  {/if}

  <div class="foot">
    <span class="sources mono">{#if sources.length}sources: {sources.join(' · ')}{/if}</span>
    {#if byline}<Byline {...byline} {onagent} />{/if}
  </div>
</article>
<hr class="hair" />

<style>
  .lead { padding: 8px 0 36px; }

  .dateline {
    display: flex; align-items: center; gap: 8px;
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    margin-bottom: 20px;
  }
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
  .headlink { color: inherit; text-decoration: none; }
  .headlink:hover { color: var(--wire); text-decoration: none; }

  .dek {
    margin: 18px 0 0;
    font-size: 18px; line-height: 1.45; color: var(--ink-2);
    letter-spacing: -0.01em;
    max-width: 52ch;
  }

  .banner {
    display: block; width: 100%; margin-top: 24px;
    border-radius: var(--r); object-fit: cover;
    /* no border per §4.5 note 3 */
  }

  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin-top: 24px; flex-wrap: wrap;
  }
  .sources { font-size: 11px; color: var(--ink-3); }

  @media (max-width: 600px) {
    .head { font-size: 32px; }
  }
</style>
