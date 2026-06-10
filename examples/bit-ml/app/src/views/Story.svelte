<script>
  // Story page (DESIGN.md §4.5). Full bite anatomy ENLARGED — serif head
  // 32–36, dek, byline row — then the orgitorial-rendered org body at 68ch,
  // then the Receipt (only if the manifest row carries one), then
  // "more from <section>" (3 bites). The serif lives here: story headlines
  // ARE the serif's home (§2 the Linear-forward dial).
  import Bite from '../lib/Bite.svelte';
  import Byline from '../lib/Byline.svelte';
  import Receipt from '../lib/Receipt.svelte';
  import { sectionOf } from '../lib/sections.js';
  import { manifest, storyBySlug, storyBody, moreFrom } from '../lib/stories.svelte.js';
  import { bylineProps, biteProps } from '../lib/bite-props.js';

  let { slug, onagent } = $props();

  const rows = $derived(manifest());
  const story = $derived(rows ? storyBySlug(slug) : null);
  const sec = $derived(story ? sectionOf(story.section) : null);
  const more = $derived(story ? moreFrom(story.section, story.slug, 3) : []);

  // fetch + render the org body once the row is known (cached in the store)
  let body = $state('');
  let pending = $state(true);
  $effect(() => {
    if (!story) return;
    pending = true; body = '';
    storyBody(slug).then((html) => { body = html; pending = false; });
  });
</script>

{#if rows && !story}
  <p class="missing mono">story not found: {slug}</p>
{:else if story}
  <article class="story">
    <!-- enlarged bite anatomy -->
    <div class="meta-top mono">
      <span class="sec"><span class="tick"></span><span class="tag" style="color:{sec.color}">{sec.tag}</span></span>
      <span class="when">{story.time} · {story.read} read</span>
    </div>

    <h1 class="head serif">{story.head}</h1>
    {#if story.dek}<p class="dek">{story.dek}</p>{/if}

    <div class="byline-row">
      <span class="sources mono">{#if story.sources?.length}sources: {#each story.sources as s, i}<a href={s.url} target="_blank" rel="noopener">{s.label}</a>{#if i < story.sources.length - 1} · {/if}{/each}{/if}</span>
      {#if story.byline}<Byline {...bylineProps(story.byline)} {onagent} avatar />{/if}
    </div>

    <hr class="hair" />

    <!-- the org body — orgitorial returns <article class="org-doc">…</article>;
         --org-* vars are mapped onto bit.ml tokens in app.css so it reads
         native (serif sub-heads, Switzer body at 68ch, Geist Mono meta) -->
    <div class="org-mount">
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
      {#each more as row (row.slug)}
        <Bite {...biteProps(row)} href={`/story/${row.slug}`} {onagent} />
      {/each}
    </section>
  {/if}
{/if}

<style>
  .story { padding-top: 26px; }

  .meta-top {
    display: flex; align-items: center; justify-content: space-between;
    gap: 12px; margin-bottom: 16px;
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em;
  }
  .sec { display: inline-flex; align-items: center; gap: 8px; }
  .tick { width: 2px; height: 12px; background: var(--ink); display: inline-block; }
  .tag { font-weight: 500; }
  .when { color: var(--ink-3); white-space: nowrap; }

  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 36px; line-height: 1.08; font-weight: 600;
    font-optical-sizing: auto; letter-spacing: -0.018em;
    color: var(--ink); text-wrap: balance;
  }

  .dek {
    margin: 16px 0 0;
    font-size: 19px; line-height: 1.5; color: var(--ink-2);
    letter-spacing: -0.01em; max-width: 60ch;
  }

  .byline-row {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 16px; margin: 22px 0 0; flex-wrap: wrap;
  }
  .sources { font-size: 11px; color: var(--ink-3); }
  .sources a { color: var(--ink-2); }

  .byline-row + .hair { margin-top: 22px; }

  .receipt-wrap { margin-top: 40px; }

  .more { margin-top: 72px; }
  .more-head {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--ink); margin-bottom: 12px;
  }
  .loading { color: var(--ink-3); padding: 24px 0; }
  .missing { color: var(--ink-3); padding: 60px 0; font-size: 12px; }

  @media (max-width: 600px) {
    .head { font-size: 28px; }
  }
</style>
