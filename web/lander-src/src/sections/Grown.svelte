<script>
  // Agent-grown sections live in ./grown/NN-slug.svelte and are picked up at
  // build time, sorted by filename (numbering is the ordering law). The agent
  // adds files here; the page is a build artifact. See WALDO.md.
  const mods = import.meta.glob('./grown/*.svelte', { eager: true });
  const sections = Object.keys(mods)
    .sort()
    .map((k) => mods[k].default);
</script>

<div id="grown">
  {#each sections as Section}
    <Section />
  {/each}
</div>
