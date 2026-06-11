<script>
  // Story page (DESIGN.md §4.5). Full bite anatomy ENLARGED — serif head
  // 36, dek, byline row — then the orgitorial-rendered org body at 68ch,
  // then the Receipt (only if the manifest row carries one), then
  // "more from <section>" (3 bites). The serif lives here: story headlines
  // ARE the serif's home (§2 the Linear-forward dial).
  //
  // Banner (§4.5 note 3): manifest row may carry "banner" path + optional
  // "bannerAlt". Rendered full-column above body, radius var(--r), no border.
  // Missing/404 → nothing (onerror hides the img).
  //
  // Full-bleed blocks (§4.11): .org-block[data-width=wide/full] breakout via
  // CSS in app.css. After body mounts, call Orgitorial.activate(mountEl) if
  // the vendored orgitorial exposes it (typeof guard — forward-compatible).
  import Bite from '../lib/Bite.svelte';
  import Byline from '../lib/Byline.svelte';
  import Receipt from '../lib/Receipt.svelte';
  import { sectionOf } from '../lib/sections.js';
  import { brandify } from '../lib/brands.js';
  import { manifest, storyBySlug, storyBody, moreFrom, imageUrl } from '../lib/stories.svelte.js';
  import { bylineProps, biteProps } from '../lib/bite-props.js';

  let { slug, onagent } = $props();

  const rows = $derived(manifest());
  const story = $derived(rows ? storyBySlug(slug) : null);
  const sec = $derived(story ? sectionOf(story.section) : null);
  const more = $derived(story ? moreFrom(story.section, story.slug, 3) : []);
  // resolve the banner for workbook mode (inline data-URI) — DRY via imageUrl
  const bannerSrc = $derived(story?.banner ? imageUrl(story.banner) : null);
  // brand marks on the native serif head + dek (first mention each)
  const headHtml = $derived(story ? brandify(story.head) : '');
  const dekHtml = $derived(story?.dek ? brandify(story.dek) : '');

  // fetch + render the org body once the row is known (cached in the store)
  let body = $state('');
  let pending = $state(true);
  let mountEl = $state(null);

  $effect(() => {
    if (!story) return;
    pending = true; body = '';
    storyBody(slug).then((html) => {
      body = html;
      pending = false;
    });
  });

  // After body renders into the DOM, activate orgitorial if available (§4.11).
  // typeof guard makes this forward-compatible: no-op until the vendored
  // orgitorial lands with an activate() export.
  $effect(() => {
    if (pending || !mountEl) return;
    if (typeof window !== 'undefined' && typeof window.Orgitorial?.activate === 'function') {
      window.Orgitorial.activate(mountEl);
    }
  });
</script>

{#if rows && !story}
  <p class="missing mono">story not found: {slug}</p>
{:else if story}
  <article class="story">
    <!-- enlarged bite anatomy -->
    <div class="meta-top mono">
      <!-- section badge with color accent (§4.3) -->
      <span
        class="sec-badge"
        style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
      >{@html sec.icon}{sec.tag}</span>
      <span class="when">{#if story.time}{story.time} · {/if}{story.read} read</span>
    </div>

    <h1 class="head serif">{@html headHtml}</h1>
    {#if story.dek}<p class="dek">{@html dekHtml}</p>{/if}

    <div class="byline-row">
      <span class="sources mono">{#if story.sources?.length}sources: {#each story.sources as s, i}<a href={s.url} target="_blank" rel="noopener">{s.label}</a>{#if i < story.sources.length - 1} · {/if}{/each}{/if}</span>
      {#if story.byline}<Byline {...bylineProps(story.byline)} {onagent} avatar />{/if}
    </div>

    <hr class="hair story-hr" />

    {#if bannerSrc}
      <!-- full-column banner above body (§4.5 note 3); onerror hides on 404.
           16:9 crop box so the ~square generated webp crops cleanly. -->
      <div class="story-banner-box">
        <img
          class="story-banner"
          src={bannerSrc}
          alt={story.bannerAlt ?? ''}
          loading="lazy"
          onerror={(e) => { e.currentTarget.closest('.story-banner-box').style.display = 'none'; }}
        />
      </div>
    {/if}

    <!-- the org body — orgitorial returns <article class="org-doc">…</article>;
         --org-* vars are mapped onto bit.ml tokens in app.css so it reads
         native (serif sub-heads, Switzer body at 68ch, Geist Mono meta).
         overflow:visible on .org-mount lets wide/full blocks escape column. -->
    <div class="org-mount" bind:this={mountEl}>
      {#if pending}<p class="loading mono">…</p>{:else}{@html body}{/if}
    </div>

    <!-- the receipt — only if the manifest row carries the pipeline trail -->
    {#if story.receipt?.length}
      <div class="receipt-wrap">
        <Receipt title={`${story.slug}.org — the run`} rows={story.receipt} />
      </div>
    {/if}
  </article>

  <!-- more from the same section -->
  {#if more.length}
    <section class="more">
      <header class="more-head mono">more from {sec.tag.toLowerCase()}</header>
      <hr class="hair" />
      <div class="more-stack">
        {#each more as row (row.slug)}
          <Bite {...biteProps(row)} href={`/story/${row.slug}`} {onagent} />
        {/each}
      </div>
    </section>
  {/if}
{/if}

<style>
  .story { padding-top: 36px; }

  .meta-top {
    display: flex; align-items: center; justify-content: space-between;
    gap: 12px; margin-bottom: 22px;
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em;
  }
  .when { color: var(--ink-3); white-space: nowrap; }

  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 36px; line-height: 1.08; font-weight: 600;
    font-optical-sizing: auto; letter-spacing: -0.018em;
    color: var(--ink); text-wrap: balance;
  }

  .dek {
    margin: 22px 0 0;
    font-size: 19px; line-height: 1.5; color: var(--ink-2);
    letter-spacing: -0.01em; max-width: 60ch;
  }

  .byline-row {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin: 30px 0 0; flex-wrap: wrap;
  }
  .sources { font-size: 11px; color: var(--ink-3); }
  .sources a { color: var(--ink-2); }

  .story-hr { margin-top: 28px; }

  /* a set aspect-ratio box so the ~square generated webp crops to 16:9 cleanly
     and looks intentional (DESIGN §4.5 note 3). Soft --shadow lift on the image
     card (the one sanctioned image-card shadow). */
  .story-banner-box {
    display: block; width: 100%; margin-top: 32px;
    aspect-ratio: 16 / 9;
    border-radius: var(--r); overflow: hidden;
    background: var(--surface);
    box-shadow: var(--shadow);
  }
  .story-banner {
    display: block; width: 100%; height: 100%;
    object-fit: cover; object-position: center;
    /* no border per §4.5 note 3 */
  }

  .org-mount { margin-top: 36px; }

  .receipt-wrap { margin-top: 52px; }

  .more { margin-top: 88px; }
  .more-head {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--ink); margin-bottom: 16px;
  }
  .more-stack { display: flex; flex-direction: column; gap: 20px; margin-top: 16px; }

  .loading { color: var(--ink-3); padding: 32px 0; }
  .missing { color: var(--ink-3); padding: 72px 0; font-size: 12px; }

  @media (max-width: 600px) {
    .head { font-size: 28px; }
    .story { padding-top: 24px; }
  }
</style>
