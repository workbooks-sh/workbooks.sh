<script>
  // The front page (DESIGN.md §4.2–4.4). WireLead = newest PUBLISHED story;
  // then the stack of Bites from the manifest in order (the live story keeps
  // its type-in treatment). No MarketStrip on the real front — §4.6 forbids
  // placeholder numbers and there's no real feed yet (the strip lives on
  // /design). Ends with the Footer (the shell renders it).
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

  <div class="stack">
    {#each bites as row (row.slug)}
      <Bite {...biteProps(row)} href={`/story/${row.slug}`} {onagent} />
    {/each}
  </div>
{/if}

<style>
  .stack { margin-top: 24px; display: flex; flex-direction: column; gap: 16px; }
</style>
