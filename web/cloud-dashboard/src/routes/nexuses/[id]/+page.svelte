<script>
  import { onMount } from 'svelte';

  let { data } = $props();
  const nexus = $derived(data.nexus);
  const config = $derived(data.config);
  const month = $derived(data.month);

  // live-jitter metrics (ported from the prototype's setInterval)
  let cpu = $state(data.metrics.cpu);
  let memMb = $state(data.metrics.memMb);
  let reqMin = $state(data.metrics.reqMin);

  // fake live logs
  const LOGLINES = [
    ['g', '▸ nexus woke from sleep in 1.4s'],
    ['', 'GET /  200  12ms'],
    ['', 'weave workbook "sales-pulse" → ok'],
    ['a', '⚙ compiling rust toolkit (shared build)…'],
    ['g', '✓ toolkit ready · cached'],
    ['', 'POST /agent/run  202'],
    ['', 'litestream → R2 checkpoint ok'],
    ['', 'GET /assets/hero.png  200  (R2, 0 egress)']
  ];
  let logs = $state([]);
  let i = 0;
  const stamp = () => new Date().toLocaleTimeString('en-US', { hour12: false });
  function addLog() {
    const [c, txt] = LOGLINES[i % LOGLINES.length];
    logs = [...logs.slice(-39), { t: stamp(), c, txt }];
    i++;
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
</script>

<section>
  <a class="dim" href="/" style="font-size:13px;display:inline-flex;gap:6px;align-items:center;margin-bottom:16px">← all nexuses</a>

  <div class="sechead">
    <div>
      <h2 style="display:flex;align-items:center;gap:11px"><span class="dot {nexus.state}"></span><span>{nexus.name}</span></h2>
      <p class="mono">{nexus.url}</p>
    </div>
    <div style="display:flex;gap:8px">
      <button class="btn sm" onclick={() => window.open('https://' + nexus.url, '_blank')}>Open ↗</button>
      <button class="btn sm">Restart</button>
      <button class="btn sm">Sleep</button>
      <a class="btn sm" href="/settings">Settings</a>
    </div>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">CPU</div><div class="v">{cpu}<small>%</small></div><div class="d up">▲ active</div></div>
    <div class="stat"><div class="k">Memory</div><div class="v">{memMb}<small>MB / {config.plan.split('· ')[1] || '1 GB'}</small></div><div class="d dim">{Math.round((memMb / 1024) * 100)}% of cap</div></div>
    <div class="stat"><div class="k">Requests</div><div class="v">{reqMin}<small>/min</small></div><div class="d up">▲ steady</div></div>
    <div class="stat"><div class="k">Est. this month</div><div class="v">${data.metrics.costMonth}</div><div class="d dim">at current rate</div></div>
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

  <div class="card danger-zone">
    <h3>Danger zone</h3>
    <div style="display:flex;align-items:center;justify-content:space-between">
      <p class="dim" style="font-size:13px">Permanently delete this nexus and its storage. This cannot be undone.</p>
      <button class="btn danger sm">Delete nexus</button>
    </div>
  </div>
</section>
