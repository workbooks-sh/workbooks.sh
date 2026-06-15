<script>
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { nexusUsage } from '$lib/api.js';
  import { toast } from '$lib/toastStore.svelte.js';
  import Confirm from '$lib/Confirm.svelte';
  import History from '$lib/History.svelte';
  import Drafts from '$lib/Drafts.svelte';

  const id = $derived(page.params.id);
  const detail = $derived(nexusStore.detail(id));
  const nexus = $derived(detail?.nexus);
  const config = $derived(detail?.config);

  let confirmOpen = $state(false);

  // Real per-nexus usage from the platform rollup (Fly-grounded compute + cost).
  let usageRow = $state(null);
  async function loadUsage() {
    try {
      const u = await nexusUsage();
      usageRow = (u.rows || []).find((r) => r.name === id) || null;
    } catch {
      usageRow = null;
    }
  }
  onMount(loadUsage);

  const stateLabel = $derived(
    nexus?.state === 'run' ? 'Running' : nexus?.state === 'sleep' ? 'Sleeping' : 'Building'
  );
  const activeHrs = $derived(usageRow?.activeHrs ?? '0.0');
  const costMonth = $derived(usageRow?.cost ?? '$0.00');
  const dbLabel = $derived(usageRow?.database ?? config?.database ?? 'none');

  // ── state-aware actions (real lifecycle via the provisioner) ──
  function sleepIt() {
    nexusStore.setState(id, 'sleep');
    toast(`${nexus.name} is sleeping`);
  }
  function wake() {
    nexusStore.setState(id, 'run');
    toast(`${nexus.name} is waking…`);
  }
  async function restart() {
    toast(`Restarting ${nexus.name}…`);
    await nexusStore.setState(id, 'sleep');
    await nexusStore.setState(id, 'run');
    toast(`${nexus.name} restarted`);
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
    <div class="stat"><div class="k">State</div><div class="v">{stateLabel}</div><div class="d dim">scale-to-zero</div></div>
    <div class="stat"><div class="k">Plan</div><div class="v" style="font-size:18px">{config.plan}</div><div class="d dim">unlimited users</div></div>
    <div class="stat"><div class="k">Active compute</div><div class="v">{activeHrs}<small>hrs</small></div><div class="d dim">this cycle</div></div>
    <div class="stat"><div class="k">Est. this cycle</div><div class="v">{costMonth}</div><div class="d dim">at current rate</div></div>
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
      <h3>This cycle</h3>
      <div class="kv"><span class="k">Active compute</span><span class="v">{activeHrs} hrs</span></div>
      <div class="kv"><span class="k">Storage</span><span class="v">{usageRow?.storage || '—'}</span></div>
      <div class="kv"><span class="k">Database</span><span class="v faint">{dbLabel}</span></div>
      <div class="kv"><span class="k">Egress</span><span class="v">$0.00</span></div>
      <div class="kv"><span class="k">Subtotal</span><span class="v" style="color:var(--live)">{costMonth}</span></div>
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
