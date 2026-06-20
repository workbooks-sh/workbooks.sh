<script>
  import { workspaceStore } from '$lib/workspaceStore.svelte.js';
  import { nexusStore } from '$lib/nexusStore.svelte.js';

  // The workspace's STRUCTURE — its .work files visualized as a live code-graph (every client /
  // server / resource / data unit + how they connect), served straight from the nexus
  // (GET /:wb/graph). This is the literate-programming → infrastructure payoff: you see what the
  // workspace IS and how it's used, not a generic file list.
  const ws = $derived(workspaceStore.active);
  // workspace id "ws_<mount>" → the mount the nexus serves it under.
  const mount = $derived((ws?.id || '').replace(/^ws_/, ''));
  const base = $derived((nexusStore.active?.url || 'https://workbooks.sh').replace(/\/$/, ''));
  const vizUrl = $derived(mount ? `${base}/${mount}/graph?format=html` : null);

  // Order + colour the kind breakdown the same way the viz does.
  const KIND = { client: '#a8d4f0', server: '#aee5c2', resource: '#f3c5a3', data: '#d9c5f0', design: '#f2ddb0', agent: '#9fc4e8' };
  let summary = $state(null);
  let err = $state(false);

  $effect(() => {
    const m = mount, b = base;
    summary = null; err = false;
    if (!m) return;
    fetch(`${b}/${m}/graph`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((d) => (summary = d))
      .catch(() => (err = true));
  });
</script>

{#if !ws}
  <div class="card faint" style="text-align:center">Pick a workspace from the sidebar.</div>
{:else}
  <div class="kinds">
    {#if summary}
      <div class="kpill total"><b>{summary.units}</b> units</div>
      {#each Object.entries(summary.byKind) as [k, n] (k)}
        <div class="kpill"><span class="dot" style="background:{KIND[k] || 'var(--dim)'}"></span><b>{n}</b> {k}</div>
      {/each}
    {:else if err}
      <div class="faint" style="font-size:13px">Couldn’t read the structure (the nexus may be waking — refresh in a moment).</div>
    {:else}
      <div class="faint" style="font-size:13px">Reading structure…</div>
    {/if}
  </div>

  <div class="vizwrap">
    {#if vizUrl}
      <iframe title="Workspace structure graph" src={vizUrl} loading="lazy"></iframe>
    {/if}
  </div>
  <p class="hint">Each node is a <code>.work</code> unit — colour = kind (client / server / resource / data), badges = live utilization. Click a node to inspect its declared vs. real facets. Served live from your nexus.</p>
{/if}

<style>
  .kinds { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:14px; align-items:center; }
  .kpill {
    display:inline-flex; align-items:center; gap:6px; padding:5px 11px; border:1px solid var(--line);
    border-radius:20px; font:500 12.5px var(--read); color:var(--ink); background:var(--card);
  }
  .kpill.total { background:var(--line); }
  .kpill .dot { width:9px; height:9px; border-radius:50%; flex:none; }
  .vizwrap { border:1px solid var(--line); border-radius:14px; overflow:hidden; background:var(--card); }
  .vizwrap iframe { width:100%; height:62vh; min-height:420px; border:0; display:block; }
  .hint { margin-top:10px; font:400 12.5px var(--read); color:var(--dim); }
  .hint code { font:600 11.5px var(--mono); background:var(--line); padding:1px 5px; border-radius:4px; }
</style>
