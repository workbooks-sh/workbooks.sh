<script>
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';
  import History from '$lib/History.svelte';
  import Drafts from '$lib/Drafts.svelte';

  const id = $derived(page.params.id);
  const detail = $derived(nexusStore.detail(id));
  const nexus = $derived(detail?.nexus);
  const config = $derived(detail?.config);
  const month = $derived(detail?.month);

  let confirmOpen = $state(false);

  // live-jitter metrics (ported from the prototype's setInterval)
  let cpu = $state(18);
  let memMb = $state(412);
  let reqMin = $state(37);

  // fake live logs
  const LOGLINES = [
    ['g', '▸ nexus woke from sleep in 1.4s'],
    ['', 'GET /  200  12ms'],
    ['', 'weave workbook "sales-pulse" → ok'],
    ['a', '⚙ compiling rust toolkit (shared build)…'],
    ['g', '✓ toolkit ready · cached'],
    ['', 'POST /agent/run  202'],
    ['', 'snapshot saved ok'],
    ['', 'GET /assets/hero.png  200  (cached, 0 egress)']
  ];
  let logs = $state([]);
  let li = 0;
  const stamp = () => new Date().toLocaleTimeString('en-US', { hour12: false });
  function addLog() {
    const [c, txt] = LOGLINES[li % LOGLINES.length];
    logs = [...logs.slice(-39), { t: stamp(), c, txt }];
    li++;
  }

  onMount(() => {
    for (let k = 0; k < 6; k++) addLog();
    const lt = setInterval(addLog, 2200);
    const mt = setInterval(() => {
      cpu = 12 + Math.floor(Math.random() * 20);
      memMb = 380 + Math.floor(Math.random() * 90);
      reqMin = 28 + Math.floor(Math.random() * 30);
    }, 2000);
    return () => { clearInterval(lt); clearInterval(mt); };
  });

  // ── state-aware actions ──
  function sleepIt() {
    nexusStore.setState(id, 'sleep');
    toast(`${nexus.name} is sleeping`);
  }
  function wake() {
    nexusStore.setState(id, 'run');
    toast(`${nexus.name} is waking…`);
  }
  function restart() {
    nexusStore.setState(id, 'build');
    toast(`Restarting ${nexus.name}…`);
    const target = id;
    setTimeout(() => nexusStore.setState(target, 'run'), 2500);
  }
  function reallyDelete() {
    confirmOpen = false;
    const nm = nexus.name;
    nexusStore.remove(id);
    toast(`Deleted ${nm}`, 'bad');
    goto('/');
  }
</script>

{#if !nexus}
  <section>
    <a class="dim" href="/" style="font-size:13px;display:inline-flex;gap:6px;align-items:center;margin-bottom:16px">← all nexuses</a>
    <div class="card" style="text-align:center;color:var(--dim)">
      Nexus “{id}” not found. It may have been deleted.
    </div>
  </section>
{:else}
<section>
  <a class="dim" href="/" style="font-size:13px;display:inline-flex;gap:6px;align-items:center;margin-bottom:16px">← all nexuses</a>

  <div class="sechead">
    <div>
      <h2 style="display:flex;align-items:center;gap:11px"><span class="dot {nexus.state}"></span><span>{nexus.name}</span></h2>
      <p class="mono">{nexus.url}</p>
    </div>
    <div style="display:flex;gap:8px">
      <button class="btn sm" onclick={() => window.open('https://' + nexus.url, '_blank')}>Open ↗</button>
      <button class="btn sm" onclick={restart} disabled={nexus.state === 'build'}>Restart</button>
      {#if nexus.state === 'sleep'}
        <button class="btn sm" onclick={wake}>Wake</button>
      {:else if nexus.state === 'run'}
        <button class="btn sm" onclick={sleepIt}>Sleep</button>
      {/if}
      <a class="btn sm" href="/settings">Settings</a>
    </div>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">CPU</div><div class="v">{cpu}<small>%</small></div><div class="d up">▲ active</div></div>
    <div class="stat"><div class="k">Memory</div><div class="v">{memMb}<small>MB / {config.plan.split('· ')[1] || '1 GB'}</small></div><div class="d dim">{Math.round((memMb / 1024) * 100)}% of cap</div></div>
    <div class="stat"><div class="k">Requests</div><div class="v">{reqMin}<small>/min</small></div><div class="d up">▲ steady</div></div>
    <div class="stat"><div class="k">Est. this month</div><div class="v">${detail.metrics.costMonth}</div><div class="d dim">at current rate</div></div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h3>Configuration</h3>
      <div class="kv"><span class="k">Region</span><span class="v">{config.region}</span></div>
      <div class="kv"><span class="k">Plan</span><span class="v">{config.plan}</span></div>
      <div class="kv"><span class="k">Scale-to-zero</span><span class="v" style="color:var(--live)">{config.scaleToZero}</span></div>
      <div class="kv"><span class="k">Storage addon</span><span class="v">{config.storage}</span></div>
      <div class="kv"><span class="k">Database</span><span class="v faint">{config.database}</span></div>
      <div class="kv"><span class="k">Created</span><span class="v">{config.created}</span></div>
    </div>
    <div class="card">
      <h3>This month</h3>
      <div class="kv"><span class="k">Active compute</span><span class="v">{month.activeCompute}</span></div>
      <div class="kv"><span class="k">Sleeping</span><span class="v">{month.sleeping}</span></div>
      <div class="kv"><span class="k">Storage</span><span class="v">{month.storage}</span></div>
      <div class="kv"><span class="k">Egress</span><span class="v">{month.egress}</span></div>
      <div class="kv"><span class="k">Subtotal</span><span class="v" style="color:var(--live)">{month.subtotal}</span></div>
    </div>
  </div>

  <div class="card">
    <h3><span class="dot run"></span> Live logs</h3>
    <div class="logs">
      {#each logs as ln}
        <div class="ln"><span class="t">{ln.t}</span> <span class={ln.c}>{ln.txt}</span></div>
      {/each}
    </div>
  </div>

  <Drafts nexus={id} />

  <History scope={id} />

  <div class="card danger-zone">
    <h3>Danger zone</h3>
    <div style="display:flex;align-items:center;justify-content:space-between">
      <p class="dim" style="font-size:13px">Permanently delete this nexus and its storage. This cannot be undone.</p>
      <button class="btn danger sm" onclick={() => (confirmOpen = true)}>Delete nexus</button>
    </div>
  </div>
</section>

<Confirm
  open={confirmOpen}
  title="Delete {nexus.name}?"
  body="This permanently deletes the nexus and its storage. This cannot be undone."
  confirmLabel="Delete nexus"
  danger
  onconfirm={reallyDelete}
  oncancel={() => (confirmOpen = false)}
/>
{/if}
