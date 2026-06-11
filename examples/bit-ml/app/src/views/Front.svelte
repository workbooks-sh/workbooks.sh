<script>
  // The front page (DESIGN.md §4.2–4.4) — the WIDE BROADSHEET. WireLead = newest
  // PUBLISHED story, rendered as a big feature (banner + display head). Below it
  // a multi-column editorial GRID of bites with rhythm: bites that carry a
  // banner become the FEATURED (larger, thumbnail) variant; text-only bites stay
  // compact. Hierarchy is scale + space, not borders. Collapses to one clean
  // column on mobile. No MarketStrip on the real front (§4.6 forbids placeholder
  // numbers). Ends with the Footer (the shell renders it).
  import WireLead from '../lib/WireLead.svelte';
  import Bite from '../lib/Bite.svelte';
  import { manifest, newestPublished, stackBites } from '../lib/stories.svelte.js';
  import { leadProps, biteProps } from '../lib/bite-props.js';

  let { onagent } = $props();

  const rows = $derived(manifest());
  const lead = $derived(rows ? newestPublished() : null);
  const bites = $derived(rows ? stackBites(lead?.slug) : []);
</script>

{#if rows}
  {#if lead}
    <WireLead {...leadProps(lead)} href={`/story/${lead.slug}`} {onagent} />
  {/if}

  <!-- the editorial grid: featured bites (those with a banner) carry their
       thumbnail and span two columns; the rest read compact. Rhythm, not
       uniformity. -->
  <div class="grid">
    {#each bites as row (row.slug)}
      {@const p = biteProps(row)}
      <div class="cell" class:span={!!p.banner}>
        <Bite {...p} feature={!!p.banner} href={`/story/${row.slug}`} {onagent} />
      </div>
    {/each}
  </div>
{/if}

<style>
  /* WIDE: a 3-column editorial grid. Featured bites (with a banner) span 2
     columns so they dominate; compact bites take one. Dense flow gives a
     broadsheet rhythm without true masonry. Generous gap (air). */
  .grid {
    margin-top: 56px;
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 28px;
    grid-auto-flow: row dense;
    align-items: start;
  }
  .cell { min-width: 0; }
  /* a featured (banner) bite is the dominant column pair */
  .cell.span { grid-column: span 2; }

  /* MEDIUM: 2 columns; featured spans both for a full-width feature row */
  @media (max-width: 980px) {
    .grid { grid-template-columns: repeat(2, 1fr); gap: 24px; margin-top: 44px; }
    .cell.span { grid-column: span 2; }
  }
  /* MOBILE: one clean measured column (the stack), no horizontal scroll */
  @media (max-width: 680px) {
    .grid { grid-template-columns: 1fr; gap: 20px; margin-top: 32px; }
    .cell.span { grid-column: span 1; }
  }
</style>
