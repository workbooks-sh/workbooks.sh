<script>
  // §4.4 — the SECONDARY feature (the lead's smaller sibling in the top two-up).
  // Medium: its banner (3:2), a serif head one notch down from the lead, dek,
  // byline. Quieter than the WireLead hero but still a picture-led feature.
  import { brandify } from './brands.js';
  import { sectionOf } from './sections.js';
  import Byline from './Byline.svelte';
  import { imageUrl } from './stories.svelte.js';
  import { bylineProps } from './bite-props.js';

  let { story = null, onagent } = $props();

  const sec = $derived(story ? sectionOf(String(story.section).toUpperCase()) : null);
  const banner = $derived(story?.banner ? imageUrl(story.banner) : null);
  const headHtml = $derived(story ? brandify(story.head) : '');
  const dekHtml = $derived(story?.dek ? brandify(story.dek) : '');
</script>

{#if story}
  <article class="feat">
    {#if banner}
      <a class="img-box" href={`/story/${story.slug}`} aria-hidden="true" tabindex="-1">
        <img class="img" src={banner} alt={story.bannerAlt ?? ''} loading="eager"
             onerror={(e) => { e.currentTarget.closest('.img-box').style.display = 'none'; }} />
      </a>
    {/if}
    <div class="dateline mono">
      <span class="sec-badge"
            style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
      >{@html sec.icon}{sec.tag}</span>
    </div>
    <h2 class="head serif">
      <a class="headlink" href={`/story/${story.slug}`}>{@html headHtml}</a>
    </h2>
    {#if story.dek}<p class="dek">{@html dekHtml}</p>{/if}
    <div class="foot">
      <Byline {...bylineProps(story.byline)} {onagent} />
      {#if story.read}<span class="read mono">{story.read} read</span>{/if}
    </div>
  </article>
{/if}

<style>
  .feat { min-width: 0; }
  .img-box {
    display: block; width: 100%;
    aspect-ratio: 3 / 2;
    border-radius: var(--r); overflow: hidden;
    background: var(--surface); box-shadow: var(--shadow);
    transition: transform .15s ease, box-shadow .15s ease;
  }
  .img-box:hover { transform: translateY(-2px);
    box-shadow: 0 2px 4px rgba(0,0,0,.05), 0 14px 36px -12px rgba(0,0,0,.16); }
  .img { display: block; width: 100%; height: 100%; object-fit: cover; object-position: center; }

  .dateline {
    display: flex; align-items: center; gap: 8px;
    margin: 16px 0 12px;
  }
  .head {
    margin: 0;
    font-family: var(--serif);
    font-size: 28px; line-height: 1.08; font-weight: 600;
    font-optical-sizing: auto;
    letter-spacing: -0.018em;
    color: var(--ink); text-wrap: balance;
  }
  .headlink { color: inherit; text-decoration: none; }
  .headlink:hover { color: var(--wire); }
  .dek {
    margin: 12px 0 0;
    font-size: 16px; line-height: 1.5; color: var(--ink-2);
    letter-spacing: -0.008em; max-width: 50ch;
  }
  .foot {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 14px; flex-wrap: wrap; margin-top: 16px;
  }
  .read {
    font-size: 11px; color: var(--ink-3);
    text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
  }
  @media (max-width: 600px) { .head { font-size: 24px; } }
</style>
