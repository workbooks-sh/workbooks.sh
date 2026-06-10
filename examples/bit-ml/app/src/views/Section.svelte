<script>
  // Section front (DESIGN.md §4.4: "same stack filtered"). A mono section
  // header (the desk name, typographic — never a tinted band), then the stack
  // filtered to this section. The newest in-section story leads at display
  // size; the rest are bites.
  import WireLead from '../lib/WireLead.svelte';
  import Bite from '../lib/Bite.svelte';
  import { manifest, bySection } from '../lib/stories.svelte.js';
  import { sectionOf } from '../lib/sections.js';
  import { leadProps, biteProps } from '../lib/bite-props.js';

  let { section, onagent } = $props();

  const rows = $derived(manifest());
  const tag = $derived(String(section || '').toUpperCase());
  const sec = $derived(sectionOf(tag));
  const inSection = $derived(rows ? bySection(tag) : []);
  const lead = $derived(inSection[0] || null);
  const rest = $derived(inSection.slice(1));
</script>

{#if rows}
  <header class="secfront">
    <span class="tick"></span>
    <span class="name mono" style="color:{sec.color}">{sec.tag}</span>
    <span class="count mono">{inSection.length} {inSection.length === 1 ? 'story' : 'stories'}</span>
  </header>
  <hr class="hair" />

  {#if lead}
    <div class="lead-wrap">
      <WireLead {...leadProps(lead)} href={`/story/${lead.slug}`} {onagent} />
    </div>
  {/if}

  <div class="stack">
    {#each rest as row (row.slug)}
      <Bite {...biteProps(row)} href={`/story/${row.slug}`} {onagent} />
    {/each}
  </div>

  {#if inSection.length === 0}
    <p class="empty mono">no stories on this desk yet.</p>
  {/if}
{/if}

<style>
  .secfront {
    display: flex; align-items: baseline; gap: 10px;
    padding: 28px 0 12px;
  }
  .tick { width: 2px; height: 14px; background: var(--ink); align-self: center; }
  .name {
    font-size: 13px; font-weight: 500; text-transform: uppercase;
    letter-spacing: 0.1em;
  }
  .count { font-size: 11px; color: var(--ink-3); margin-left: auto; letter-spacing: 0.04em; }
  .lead-wrap { padding-top: 18px; }
  .stack { margin-top: 8px; }
  .empty { padding: 40px 0; color: var(--ink-3); font-size: 12px; }
</style>
