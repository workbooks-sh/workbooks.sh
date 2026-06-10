<script>
  // The PERSISTENT SHELL (DESIGN.md §7 — same architecture as the lander).
  // Masthead, CrewPanel, and Footer mount ONCE and never unmount; only the
  // CONTENT REGION (#route) swaps as the client router changes. Zero fades
  // between routes (§5: instant swap, shell persists). ONE theme — light
  // only (the terminal page theme + toggle were retired, founder 2026-06-10).
  //
  // Routes (lib/router.svelte.js):
  //   /            → Front     · /s/<section> → Section
  //   /story/<slug>→ Story     · /design      → Design (the living styleguide)
  import Masthead from './lib/Masthead.svelte';
  import CrewPanel from './lib/CrewPanel.svelte';
  import Footer from './lib/Footer.svelte';
  import Front from './views/Front.svelte';
  import Section from './views/Section.svelte';
  import Story from './views/Story.svelte';
  import Design from './views/Design.svelte';
  import { route, startRouter } from './lib/router.svelte.js';
  import { loadManifest } from './lib/stories.svelte.js';
  import { crewFeed, pipelineLine } from './lib/feed.js';

  startRouter();
  loadManifest();                       // runtime CMS — fetch the manifest once
  const r = $derived(route());

  // ── crew panel state (toggled from the masthead, footer, or a byline) ───
  let crewOpen = $state(false);
  let crewFilter = $state(null);
  function openCrew(name = null) { crewFilter = name; crewOpen = true; }

  // ── live UTC clock for the crew panel header ────────────────────────────
  let clock = $state(new Date().toISOString().slice(11, 19));
  $effect(() => {
    const id = setInterval(() => { clock = new Date().toISOString().slice(11, 19); }, 1000);
    return () => clearInterval(id);
  });

  // ── crew feed (specimen for now; future = /_activity, see lib/feed.js) ──
  const feed = crewFeed();
  const crewAgents = feed.agents.map((a) => ({ ...a, state: a.live ? 'live' : 'idle' }));
  const pipeline = pipelineLine(feed.pipeline);
</script>

<div id="top"></div>

<!-- ── PERSISTENT SHELL — mounted once, outside #route ── -->
<div class="sheet">
  <Masthead oncrew={() => (crewOpen = !crewOpen)} {crewOpen} />

  <!-- ── CONTENT REGION — the only thing navigation swaps ── -->
  <main id="route">
    {#if r.name === 'story'}
      {#key r.slug}<Story slug={r.slug} onagent={openCrew} />{/key}
    {:else if r.name === 'section'}
      {#key r.section}<Section section={r.section} onagent={openCrew} />{/key}
    {:else if r.name === 'design'}
      <Design onagent={openCrew} />
    {:else}
      <Front onagent={openCrew} />
    {/if}
  </main>

  <Footer oncrew={() => (crewOpen = !crewOpen)} />
</div>

<!-- the docked, toggleable crew panel — the fun org chart (light, Notion lift) -->
<CrewPanel
  open={crewOpen}
  filter={crewFilter}
  agents={crewAgents}
  wire={feed.wire}
  {pipeline}
  specimen={feed.specimen}
  {clock}
  onclose={() => (crewOpen = false)}
/>
