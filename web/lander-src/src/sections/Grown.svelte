<script>
  // Agent-grown sections live in ./grown/NN-slug.svelte and are picked up at
  // build time, sorted by filename (numbering is the ordering law). The agent
  // adds files here; the page is a build artifact. See WALDO.md.
  const mods = import.meta.glob('./grown/*.svelte', { eager: true });
  // keep the NN-slug key alongside the component — the follow resolver maps a
  // step touching src/sections/grown/<NN-slug>.svelte to [data-grown="<NN-slug>"]
  const sections = Object.keys(mods)
    .sort()
    .map((k) => ({
      Comp: mods[k].default,
      key: k.replace(/^.*\/(.+)\.svelte$/, '$1'),   // ./grown/04-uses.svelte → 04-uses
    }));

  // a component renders its own <section>; stamp the NN-slug onto that section
  // (and its wrapper) so the engine can find it without owning the markup.
  const tag = (host, key) => {
    host.setAttribute('data-grown', key);
    host.querySelector('section')?.setAttribute('data-grown', key);
  };
</script>

<div id="grown">
  {#each sections as { Comp, key } (key)}
    <div class="grown-host" style="display:contents" use:tag={key}><Comp /></div>
  {/each}
</div>
