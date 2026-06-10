<script>
  // Section front (DESIGN.md §4.4: "same stack filtered"). Section header uses
  // the section badge (§4.3) for typographic identity with color accent. Then
  // the stack filtered to this section. The newest in-section story leads at
  // display size; the rest are bites.
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
    <!-- section badge as the header identity (§4.3 — badge is the accent) -->
    <span
      class="sec-badge sec-badge--lg"
      style="color:{sec.color};background:color-mix(in srgb,{sec.color} 10%,transparent)"
    >{@html sec.icon}{sec.tag}</span>
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
    display: flex; align-items: center; gap: 12px;
    padding: 36px 0 16px;
  }
  /* slightly larger badge variant for the section front header */
  .sec-badge--lg {
    font-size: 11px !important;
    padding: 4px 10px !important;
  }
  .count { font-family: var(--mono); font-size: 11px; color: var(--ink-3); margin-left: auto; letter-spacing: 0.04em; }
  .lead-wrap { padding-top: 24px; }
  .stack { margin-top: 20px; display: flex; flex-direction: column; gap: 20px; }
  .empty { padding: 48px 0; color: var(--ink-3); font-size: 12px; font-family: var(--mono); }
</style>
