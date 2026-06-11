<script>
  // §4.2 The Wire (front-page lead FEATURE). NOT a hero — a LEAD, now the
  // broadsheet feature: a BIG banner paired with the Newsreader display head.
  // At wide widths the banner dominates the left column and the head/dek/foot
  // sit to its right; it stacks (banner on top) on narrow. Brand marks render
  // inline on the head + dek FIRST mention (§"inline brand logos"). Section
  // badge dateline, source row, byline below. Banner (§4.5 note 3): 16:9 crop
  // box, radius var(--r), soft shadow; missing/404 → hides (onerror).
  import { sectionOf } from './sections.js';
  import { brandify } from './brands.js';
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
    banner = null,       // optional: path to banner image (already resolved)
    bannerAlt = '',
  } = $props();

  const sec = $derived(sectionOf(section));
  // brand marks on first mention (head + dek each track their own first-mentions)
  const headHtml = $derived(brandify(head));
  const dekHtml = $derived(brandify(dek));
</script>

<article class="lead" class:has-banner={!!banner}>
  {#if banner}
    <!-- the dominant feature image: 16:9 crop box (the webp is ~square),
         radius + soft shadow; onerror hides the whole box (§4.5 note 3) -->
    <a class="banner-box" href={href ?? undefined} aria-hidden="true" tabindex="-1">
      <img
        class="banner"
        src={banner}
        alt={bannerAlt}
        loading="eager"
        onerror={(e) => { e.currentTarget.closest('.banner-box').style.display = 'none'; }}
      />
    </a>
  {/if}

  <div class="copy">
    <div class="dateline mono">
      <!-- section badge: tiny icon + tag, tinted wash, color text (§4.2/§4.3) -->
      <span
        class="sec-badge"
        style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
      >{@html sec.icon}{sec.tag}</span>
      <span class="dot">·</span>
      <span class="when">{dateline}</span>
    </div>

    <h1 class="head serif">{#if href}<a class="headlink" {href}>{@html headHtml}</a>{:else}{@html headHtml}{/if}</h1>

    {#if dek}<p class="dek">{@html dekHtml}</p>{/if}

    <div class="foot">
      <span class="sources mono">{#if sources.length}sources: {sources.join(' · ')}{/if}</span>
      {#if byline}<Byline {...byline} {onagent} />{/if}
    </div>
  </div>
</article>
<hr class="hair" />

<style>
  .lead { padding: 8px 0 40px; }

  /* WIDE: the feature spreads — big banner left (dominant), copy right.
     A broadsheet lead, not a stack. Generous gap (air is the aesthetic). */
  .lead.has-banner {
    display: grid;
    grid-template-columns: 1.35fr 1fr;
    gap: 40px;
    align-items: start;
  }
  .copy { min-width: 0; }   /* let text wrap instead of forcing column width */

  /* the dominant feature image — 16:9 crop box, radius + soft lift */
  .banner-box {
    display: block; width: 100%;
    aspect-ratio: 16 / 9;
    border-radius: var(--r); overflow: hidden;
    background: var(--surface);
    box-shadow: var(--shadow);
    transition: transform .15s ease, box-shadow .15s ease;
  }
  .banner-box:hover { transform: translateY(-2px);
    box-shadow: 0 2px 4px rgba(0,0,0,.05), 0 16px 40px -12px rgba(0,0,0,.18); }
  .banner {
    display: block; width: 100%; height: 100%;
    object-fit: cover; object-position: center;
  }

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
    font-size: 46px; line-height: 1.04; font-weight: 600;
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

  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin-top: 24px; flex-wrap: wrap;
  }
  .sources { font-size: 11px; color: var(--ink-3); }

  /* MEDIUM: when the shell narrows below the broadsheet, stack (banner on top) */
  @media (max-width: 860px) {
    .lead.has-banner { grid-template-columns: 1fr; gap: 22px; }
    .head { font-size: 40px; }
  }
  @media (max-width: 600px) {
    .head { font-size: 32px; }
  }
</style>
