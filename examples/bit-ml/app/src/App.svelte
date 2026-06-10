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
  import { crewFeed, changesFeed, pipelineLine, fetchActivity, fetchChanges } from './lib/feed.js';

  startRouter();
  loadManifest();                       // runtime CMS — fetch the manifest once
  const r = $derived(route());

  // ── crew panel state (toggled from the masthead, footer, or a byline) ───
  let crewOpen = $state(false);
  let crewFilter = $state(null);
  function openCrew(name = null) { crewFilter = name; crewOpen = true; }
  // the masthead/footer toggle opens the GRID (no member filter)
  function toggleCrew() { crewFilter = null; crewOpen = !crewOpen; }
  function closeCrew() { crewOpen = false; crewFilter = null; }

  // ── live UTC clock for the crew panel header ────────────────────────────
  let clock = $state(new Date().toISOString().slice(11, 19));
  $effect(() => {
    const id = setInterval(() => { clock = new Date().toISOString().slice(11, 19); }, 1000);
    return () => clearInterval(id);
  });

  // ── crew feed: specimen by default; poll the runtime live while the panel
  //    is open (every ~3s). /_activity → agents/doing/live + pipeline;
  //    /_changes → the commit history. When offline, the specimen stands and
  //    the honest "specimen data" tag stays. (DESIGN §4.8 / §7.)
  const aFeed = crewFeed();
  const cFeed = changesFeed();
  let agentsRaw = $state(aFeed.agents);
  let pipelineObj = $state(aFeed.pipeline);
  let commits = $state(cFeed.commits);
  let specimen = $state(true);          // flips false once a live fetch lands

  const crewAgents = $derived(agentsRaw.map((a) => ({ ...a, state: a.live ? 'live' : 'idle' })));
  const pipeline = $derived(pipelineLine(pipelineObj));

  async function pollCrew() {
    const [act, chg] = await Promise.all([fetchActivity(), fetchChanges()]);
    let liveHit = false;
    if (act) { agentsRaw = act.agents; if (act.pipeline) pipelineObj = act.pipeline; liveHit = true; }
    if (chg) { commits = chg.commits; liveHit = true; }
    if (liveHit) specimen = false;
  }
  // poll only while the panel is open — no work when it's closed
  $effect(() => {
    if (!crewOpen) return;
    pollCrew();
    const id = setInterval(pollCrew, 3000);
    return () => clearInterval(id);
  });
</script>

<div id="top"></div>

<!-- ── PERSISTENT SHELL — mounted once, outside #route ── -->
<div class="sheet">
  <Masthead oncrew={toggleCrew} {crewOpen} />

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

  <Footer oncrew={toggleCrew} />
</div>

<!-- the docked crew panel — character grid + profile + commit console (§4.8) -->
<CrewPanel
  open={crewOpen}
  filter={crewFilter}
  agents={crewAgents}
  commits={commits}
  {pipeline}
  {specimen}
  {clock}
  onclose={closeCrew}
/>
