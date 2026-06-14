<script>
  // New-nexus modal (ported from the prototype). On deploy it calls the mock
  // PCP client and routes to the new nexus's list, then closes.
  import { goto } from '$app/navigation';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';

  let { open = false, onclose } = $props();

  let name = $state('nova');
  let region = $state('sfo');
  let plan = $state('Starter · 1 GB');
  let est = $state(20);
  let storageOn = $state(false);
  let dbOn = $state(false);

  const REGIONS = [
    { id: 'sfo', label: '🌉 sfo' },
    { id: 'ewr', label: '🗽 ewr' },
    { id: 'fra', label: '🇩🇪 fra' },
    { id: 'sin', label: '🇸🇬 sin' }
  ];
  const PLANS = [
    { id: 'Starter · 1 GB',   nm: 'Starter',   pr: 20,  ds: '1 GB · scale-to-zero · for one app or agent' },
    { id: 'Pro · 2 GB',       nm: 'Pro',       pr: 45,  ds: '2 GB · always-warm option · more burst' },
    { id: 'Dedicated · 4 GB', nm: 'Dedicated', pr: 120, ds: 'isolated host · strongest boundary' }
  ];

  function selectPlan(p) { plan = p.id; est = p.pr; }

  function deploy() {
    const addons = [];
    if (storageOn) addons.push('storage');
    if (dbOn) addons.push('database');
    const nx = nexusStore.create({ name, region, plan, addons });
    onclose?.();
    toast(`Deploying ${nx.name}…`);
    // flip build → run once the (mock) weave finishes
    setTimeout(() => {
      nexusStore.setState(nx.id, 'run');
      toast(`${nx.name} is live`);
    }, 3000);
    goto('/nexuses/' + nx.id);
  }
</script>

{#if open}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) onclose?.(); }}>
    <div class="sheet">
      <h2>New nexus</h2>
      <p class="sub">A hosted runtime that builds and runs your workbooks. Sleeps when idle.</p>

      <div class="lab">Name</div>
      <div class="field"><input bind:value={name} placeholder="my-nexus" /></div>

      <div class="lab">Region</div>
      <div class="regions">
        {#each REGIONS as r}
          <div class="reg" class:sel={region === r.id} onclick={() => (region = r.id)}>{r.label}</div>
        {/each}
      </div>

      <div class="lab">Plan</div>
      <div class="plans">
        {#each PLANS as p}
          <div class="plan" class:sel={plan === p.id} onclick={() => selectPlan(p)}>
            <div class="nm">{p.nm}</div>
            <div class="pr">${p.pr}<small>/mo</small></div>
            <div class="ds">{p.ds}</div>
          </div>
        {/each}
      </div>

      <div class="lab">Addons</div>
      <div class="addon">
        <div class="info"><b>Object storage</b><p>Zero-egress storage for images &amp; files</p></div>
        <div class="pr">$0.015/GB</div>
        <div class="tog" class:on={storageOn} onclick={() => (storageOn = !storageOn)}><i></i></div>
      </div>
      <div class="addon">
        <div class="info"><b>Managed Postgres</b><p>Real backend, scales to zero with the nexus</p></div>
        <div class="pr">+$10/mo</div>
        <div class="tog" class:on={dbOn} onclick={() => (dbOn = !dbOn)}><i></i></div>
      </div>

      <div class="note">Prices are illustrative placeholders — final numbers come from load-testing real tenant cost. You're billed on active compute, not idle time.</div>

      <div class="foot">
        <div class="est">Base <b>${est}/mo</b> + metered usage</div>
        <div style="display:flex;gap:8px">
          <button class="btn" onclick={() => onclose?.()}>Cancel</button>
          <button class="btn primary" onclick={deploy}>Deploy nexus</button>
        </div>
      </div>
    </div>
  </div>
{/if}
