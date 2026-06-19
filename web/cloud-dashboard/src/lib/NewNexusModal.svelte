<script>
  // New-nexus modal (ported from the prototype). On deploy it calls the mock
  // PCP client and routes to the new nexus's list, then closes.
  import { goto } from '$app/navigation';
  import { nexusStore } from '$lib/nexusStore.svelte.js';
  import { toast } from '$lib/toastStore.svelte.js';

  let { open = false, onclose } = $props();

  let name = $state('nova');
  let region = $state('sfo');
  let size = $state('1 GB');
  let dbOn = $state(true); // a database comes with every nexus; toggle off if you don't want one
  let deploying = $state(false);

  const REGIONS = [
    { id: 'sfo', label: '🌉 sfo' },
    { id: 'ewr', label: '🗽 ewr' },
    { id: 'fra', label: '🇩🇪 fra' },
    { id: 'sin', label: '🇸🇬 sin' }
  ];
  // A nexus is one isolated micro-VM; "size" is its compute (RAM). It draws from your
  // plan's compute — bigger sizes use more of it. No per-nexus subscription here; your
  // plan is the bill.
  const SIZES = [
    { id: '1 GB', nm: 'Small',  ds: '1 GB · a project or a few agents' },
    { id: '2 GB', nm: 'Medium', ds: '2 GB · a busy app · more headroom' },
    { id: '4 GB', nm: 'Large',  ds: '4 GB · heavy workloads · dedicated' }
  ];

  async function deploy() {
    if (deploying) return;
    deploying = true;
    // Fly uses 'sjc' for the SF bay; the rest of our region ids are valid Fly regions.
    const flyRegion = region === 'sfo' ? 'sjc' : region;
    onclose?.();
    toast('Provisioning your nexus…');
    try {
      const nx = await nexusStore.provision({ name: name.trim(), region: flyRegion, plan: size, database: dbOn });
      toast(`${nx.name} is provisioning`);
      goto('/nexuses/' + nx.id);
    } catch {
      toast('Couldn’t provision a nexus — check the runtime connection');
    } finally {
      deploying = false;
    }
  }
</script>

{#if open}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) onclose?.(); }}>
    <div class="sheet">
      <h2>Create your nexus</h2>
      <p class="sub">Your organization's hosted runtime — you'll scale this one nexus as you grow.</p>

      <div class="lab">Name</div>
      <div class="field"><input bind:value={name} placeholder="my-nexus" /></div>

      <div class="lab">Region</div>
      <div class="regions">
        {#each REGIONS as r}
          <div class="reg" class:sel={region === r.id} onclick={() => (region = r.id)}>{r.label}</div>
        {/each}
      </div>

      <div class="lab">Starting size</div>
      <div class="plans">
        {#each SIZES as s}
          <div class="plan" class:sel={size === s.id} onclick={() => (size = s.id)}>
            <div class="nm">{s.nm}</div>
            <div class="pr">{s.id}</div>
            <div class="ds">{s.ds}</div>
          </div>
        {/each}
      </div>

      <div class="lab">Database</div>
      <div class="addon">
        <div class="info"><b>Postgres database</b><p>Comes with every nexus — turn it off if you don’t need one</p></div>
        <div class="pr">included</div>
        <div class="tog" class:on={dbOn} onclick={() => (dbOn = !dbOn)}><i></i></div>
      </div>

      <div class="note">Egress-free object storage and Postgres are included. Unlimited workspaces and users — you're only ever scaled by memory and bandwidth. You can scale this nexus up anytime; you'll never need a second.</div>

      <div class="foot">
        <div class="est">Scale up anytime</div>
        <div style="display:flex;gap:8px">
          <button class="btn" onclick={() => onclose?.()}>Cancel</button>
          <button class="btn primary" onclick={deploy}>Create nexus</button>
        </div>
      </div>
    </div>
  </div>
{/if}
