<script>
  // The Nexus overview — the home. Leads with the two metrics that matter (Storage +
  // Load), then a few calm drill-in cards for the nexus's systems. No feature list.
  import { nexusStore } from '$lib/nexusStore.svelte.js';

  let { data } = $props();

  const nx = $derived(nexusStore.active);
  const status = $derived(nx?.state === 'run' ? 'Active' : nx?.state === 'sleep' ? 'Idle' : 'Starting');
  const storageUsed = $derived(data?.storage?.totalSize || '0 GB');
  // Load = % of compute capacity in use, metered server-side from real Fly machine
  // state (runtime/host/nexus_usage.ex). A scaled-down nexus is genuinely 0%; an
  // active one reports its real metered floor. `null/undefined` (machine unknown) ⇒
  // honest "—", never a fabricated number.
  const loadPct = $derived(data?.usage?.summary?.load);
  const loadKnown = $derived(typeof loadPct === 'number');
  const loadDisplay = $derived(loadKnown ? `${loadPct}%` : '—');
  const loadNote = $derived(
    !loadKnown ? 'No live machine to meter' : loadPct === 0 ? 'Idle — scaled down' : 'Live · metered from Fly'
  );

  const CARDS = [
    { href: '/storage', title: 'Storage', sub: 'Files, images & data', accent: 'var(--sky)' },
    { href: '/database', title: 'Database', sub: 'Postgres, included', accent: 'var(--mint)' },
    { href: '/team', title: 'Team', sub: 'Org members & access', accent: 'var(--peach)' },
    { href: '/usage', title: 'Usage & billing', sub: 'Plan, invoices, history', accent: 'var(--sage)' }
  ];
</script>

<section>
  {#if !nx}
    <div class="sechead"><div><h2>Nexus</h2><p>Your hosted runtime.</p></div></div>
    <div class="card empty">No nexus yet — open the <b>Nexus</b> switcher and hit <b>New nexus</b> to spin one up.</div>
  {:else}
    <div class="sechead">
      <div>
        <h2 style="display:flex;align-items:center;gap:11px"><span class="dot {nx.state}"></span>{nx.name}</h2>
        <p>{nx.plan} · {nx.region} · {status}</p>
      </div>
      <button class="btn sm" onclick={() => window.open(nx.url, '_blank')}>Open ↗</button>
    </div>

    <!-- the two metrics that matter -->
    <div class="metrics">
      <div class="metric">
        <div class="mlabel">Storage</div>
        <div class="mbig">{storageUsed}</div>
        <div class="mbar"><i style="width:8%"></i></div>
        <div class="msub">used of your plan</div>
      </div>
      <div class="metric">
        <div class="mlabel">Load</div>
        <div class="mbig">{loadDisplay}</div>
        <div class="mbar"><i style="width:{loadKnown ? loadPct : 0}%; background:var(--peach)"></i></div>
        <div class="msub">{loadNote}</div>
      </div>
    </div>

    <!-- calm drill-in cards for the nexus systems -->
    <div class="cards">
      {#each CARDS as c}
        <a class="dcard" href={c.href}>
          <span class="ddot" style="background:{c.accent}"></span>
          <div class="dt">{c.title}</div>
          <div class="ds">{c.sub}</div>
        </a>
      {/each}
    </div>
  {/if}
</section>

<style>
  .empty { text-align: center; color: var(--dim); }
  .metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin: 4px 0 18px; }
  .metric { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; }
  .mlabel { font: 700 10px var(--read); letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }
  .mbig { font: 700 32px var(--read); color: var(--ink); margin: 6px 0 12px; letter-spacing: -0.02em; }
  .mbar { height: 7px; border-radius: 4px; background: var(--line); overflow: hidden; }
  .mbar i { display: block; height: 100%; background: var(--sky); border-radius: 4px; }
  .msub { font: 500 12px var(--read); color: var(--dim); margin-top: 9px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }
  .dcard {
    display: block; background: var(--card); border: 1px solid var(--line); border-radius: 13px;
    padding: 16px 18px; text-decoration: none; color: inherit; transition: border-color 0.12s, transform 0.08s;
  }
  .dcard:hover { border-color: var(--stroke); transform: translateY(-1px); }
  .ddot { display: inline-block; width: 10px; height: 10px; border-radius: 4px; margin-bottom: 10px; }
  .dt { font: 600 15px var(--read); color: var(--ink); }
  .ds { font: 500 12.5px var(--read); color: var(--dim); margin-top: 3px; }
</style>
