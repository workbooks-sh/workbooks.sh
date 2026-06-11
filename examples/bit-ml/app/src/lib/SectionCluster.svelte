<script>
  // §4.4 — a PER-SECTION CLUSTER: the front page's core editorial texture.
  //   header  : the section badge as a LEFT-ALIGNED RULE (mono, section accent)
  //   lead    : ONE imaged story (its feature banner, medium) — the picture
  //   list    : a tight HEADLINE LIST of the section's remaining stories
  //             (head + dek-snippet + read/byline, NO images, hairline-dense)
  // One picture, many headlines. Clusters lay in a responsive grid (the Front
  // places them 2-across on wide, 1 on narrow) so the page has rhythm.
  import { sectionOf } from './sections.js';
  import { brandify } from './brands.js';
  import Byline from './Byline.svelte';
  import HeadlineRow from './HeadlineRow.svelte';
  import { imageUrl } from './stories.svelte.js';
  import { bylineProps } from './bite-props.js';

  let { section = 'AI', lead = null, rest = [], onagent } = $props();

  const sec = $derived(sectionOf(String(section).toUpperCase()));
  const leadBanner = $derived(lead?.banner ? imageUrl(lead.banner) : null);
  const leadHeadHtml = $derived(lead ? brandify(lead.head) : '');
  const leadDekHtml = $derived(lead?.dek ? brandify(lead.dek) : '');
</script>

<section class="cluster">
  <!-- section header: badge + hairline rule, the section accent on a mono page -->
  <header class="head">
    <span
      class="sec-badge sec-badge--lg"
      style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
    >{@html sec.icon}{sec.tag}</span>
    <span class="rule" style="background:color-mix(in srgb,{sec.color} 28%,var(--rule))"></span>
  </header>

  {#if lead}
    <!-- the ONE imaged lead for this section (medium). collage house style. -->
    <article class="lead">
      {#if leadBanner}
        <a class="img-box" href={`/story/${lead.slug}`} aria-hidden="true" tabindex="-1">
          <img class="img" src={leadBanner} alt={lead.bannerAlt ?? ''} loading="lazy"
               onerror={(e) => { e.currentTarget.closest('.img-box').style.display = 'none'; }} />
        </a>
      {/if}
      <h2 class="lhead">
        <a class="headlink" href={`/story/${lead.slug}`}>{@html leadHeadHtml}</a>
      </h2>
      {#if lead.dek}<p class="ldek">{@html leadDekHtml}</p>{/if}
      <div class="lmeta mono">
        {#if lead.read}<span class="read">{lead.read} read</span>{/if}
        <Byline {...bylineProps(lead.byline)} {onagent} />
      </div>
    </article>
  {/if}

  <!-- the headline list: one picture above, many headlines below -->
  <div class="list">
    {#each rest as row (row.slug)}
      <HeadlineRow
        head={row.head} dek={row.dek} read={row.read}
        byline={bylineProps(row.byline)} {onagent}
        href={`/story/${row.slug}`} />
    {/each}
  </div>
</section>

<style>
  .cluster { min-width: 0; }

  .head {
    display: flex; align-items: center; gap: 14px;
    margin-bottom: 22px;
  }
  .head .rule { flex: 1; height: 1px; }   /* a left-aligned section rule */

  /* — the imaged lead (medium) — */
  .lead { margin-bottom: 6px; }
  .img-box {
    display: block; width: 100%;
    aspect-ratio: 3 / 2;
    border-radius: var(--r); overflow: hidden;
    background: var(--surface); box-shadow: var(--shadow);
    margin-bottom: 18px;
    transition: transform .15s ease, box-shadow .15s ease;
  }
  .img-box:hover { transform: translateY(-2px);
    box-shadow: 0 2px 4px rgba(0,0,0,.05), 0 14px 36px -12px rgba(0,0,0,.16); }
  .img { display: block; width: 100%; height: 100%; object-fit: cover; object-position: center; }

  .lhead {
    margin: 0;
    font-family: var(--serif);
    font-size: 25px; line-height: 1.12; font-weight: 600;
    font-optical-sizing: auto;
    letter-spacing: -0.018em;
    color: var(--ink); text-wrap: balance;
  }
  .headlink { color: inherit; text-decoration: none; }
  .headlink:hover { color: var(--wire); }
  .ldek {
    margin: 10px 0 0;
    font-size: 16px; line-height: 1.5; color: var(--ink-2);
    letter-spacing: -0.008em; max-width: 56ch;
  }
  .lmeta {
    display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap;
    margin-top: 14px;
  }
  .read {
    font-size: 11px; color: var(--ink-3);
    text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
  }

  /* the headline list closes its top hairline against the lead's meta */
  .list { margin-top: 18px; }

  @media (max-width: 600px) {
    .lhead { font-size: 22px; }
  }
</style>
