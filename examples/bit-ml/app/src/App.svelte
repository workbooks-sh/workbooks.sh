<script>
  // The PERSISTENT SHELL (DESIGN.md §7 — same architecture as the lander).
  // Masthead, CrewPanel, Footer, and the theme toggle mount ONCE and never
  // unmount; only the CONTENT REGION (#route) swaps as the client router
  // changes. Zero fades between routes (§5: instant swap, shell persists).
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

  // ── page theme toggle (paper ↔ terminal) — proves the token system ──────
  let theme = $state('light');
  $effect(() => {
    document.documentElement.dataset.theme = theme === 'terminal' ? 'terminal' : '';
  });

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

<!-- the docked, toggleable crew panel (always terminal-skinned) -->
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

<!-- floating mono theme toggle (bottom-left) — proves the token system -->
<button class="theme-toggle mono" onclick={() => (theme = theme === 'terminal' ? 'light' : 'terminal')}>
  {theme === 'terminal' ? '○ paper' : '● terminal'}
</button>

<style>
  .theme-toggle {
    position: fixed; left: 18px; bottom: 18px; z-index: 70;
    background: var(--paper); color: var(--ink-2);
    border: 1px solid var(--rule); border-radius: 999px;
    padding: 7px 13px; font-size: 11px; letter-spacing: 0.04em;
    box-shadow: 0 2px 14px -8px rgba(0,0,0,.3);
    transition: color .15s ease, border-color .15s ease;
  }
  .theme-toggle:hover { color: var(--wire); border-color: color-mix(in srgb, var(--wire) 40%, var(--rule)); }
</style>
