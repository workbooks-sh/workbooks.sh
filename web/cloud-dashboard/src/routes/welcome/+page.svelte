<script>
  import { enhance } from '$app/forms';
  import { createNexus } from '$lib/api.js';
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();

  const first = $derived(data.user?.firstName || 'there');
  const STEPS = ['Welcome', 'Workspace', 'First nexus', 'Billing', 'Done'];
  let step = $state(0);

  let workspace = $state('');
  let region = $state('sfo');
  let plan = $state('Starter · 1 GB');
  let creating = $state(false);
  let createdNexus = $state(null);
  let billingDone = $state(false);

  const REGIONS = [['sfo', 'San Francisco'], ['ewr', 'New York'], ['fra', 'Frankfurt'], ['sin', 'Singapore']];
  const PLANS = ['Starter · 1 GB', 'Pro · 2 GB'];

  const next = () => (step = Math.min(step + 1, STEPS.length - 1));
  const back = () => (step = Math.max(step - 1, 0));

  async function createFirst() {
    const name = (workspace || 'my-workspace').toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
    creating = true;
    createdNexus = await createNexus({ name, region, plan });
    creating = false;
    toast(`Nexus “${createdNexus.name}” is spinning up`);
    next();
  }
</script>

<div class="wrap">
  <div class="sheet">
    <div class="rail">
      {#each STEPS as s, i}
        <div class="dot" class:on={i === step} class:done={i < step}></div>
      {/each}
    </div>

    {#if step === 0}
      <h1>Welcome, {first} 👋</h1>
      <p class="sub">Let’s get your workspace set up — it takes about a minute. You’ll name your workspace, spin up your first nexus, and (optionally) connect billing.</p>
      <div class="foot"><button class="btn primary" onclick={next}>Get started</button></div>

    {:else if step === 1}
      <h1>Name your workspace</h1>
      <p class="sub">This is the home for your nexuses, folders, and team. You can rename it later.</p>
      <input class="big" placeholder="acme" bind:value={workspace} />
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next} disabled={!workspace.trim()}>Continue</button></div>

    {:else if step === 2}
      <h1>Create your first nexus</h1>
      <p class="sub">A nexus is your hosted Workbooks runtime — where your workbooks weave and run.</p>
      <div class="lab">Region</div>
      <div class="opts">
        {#each REGIONS as [id, name]}
          <button class="opt" class:sel={region === id} onclick={() => (region = id)}>{name}<small>{id}</small></button>
        {/each}
      </div>
      <div class="lab">Plan</div>
      <div class="opts">
        {#each PLANS as p}
          <button class="opt" class:sel={plan === p} onclick={() => (plan = p)}>{p}</button>
        {/each}
      </div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={createFirst} disabled={creating}>{creating ? 'Creating…' : 'Create nexus'}</button></div>

    {:else if step === 3}
      <h1>Connect billing</h1>
      <p class="sub">Add a payment method to go beyond the free allowance. You can skip this and add it later — your nexus keeps running on the starter allowance.</p>
      {#if createdNexus}
        <div class="done-row">✓ Nexus <b>{createdNexus.name}</b> is building in {region}.</div>
      {/if}
      <div class="foot">
        <button class="btn" onclick={back}>Back</button>
        <a class="btn" href="/billing/checkout?plan=team" onclick={() => (billingDone = true)}>Set up billing ↗</a>
        <button class="btn primary" onclick={next}>{billingDone ? 'Continue' : 'Skip for now'}</button>
      </div>

    {:else}
      <h1>You’re all set 🎉</h1>
      <p class="sub">Your workspace is ready. Jump into the dashboard to manage your nexus, history, drafts, and shared folders.</p>
      <form method="POST" action="?/finish" use:enhance>
        <div class="foot"><button class="btn primary big-btn" type="submit">Enter your dashboard →</button></div>
      </form>
    {/if}
  </div>
</div>

<style>
  .wrap { min-height:100dvh; display:grid; place-items:center; padding:24px; background:var(--paper); }
  .sheet { width:520px; max-width:100%; background:var(--card); border:2px solid var(--stroke); border-radius:16px;
    box-shadow:4px 4px 0 var(--shadow); padding:34px 34px 28px; }
  .rail { display:flex; gap:7px; margin-bottom:22px; }
  .dot { height:5px; flex:1; border-radius:3px; background:var(--line); }
  .dot.on { background:var(--bloomd); }
  .dot.done { background:color-mix(in srgb, var(--bloomd) 55%, var(--line)); }
  h1 { font-size:24px; margin:0 0 10px; }
  .sub { color:var(--dim); font-size:14px; line-height:1.6; margin:0 0 20px; }
  .big { width:100%; font-size:18px; padding:12px 14px; border:2px solid var(--stroke); border-radius:10px; background:var(--paper); color:inherit; }
  .lab { font-size:12px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; font-weight:700; margin:14px 0 8px; }
  .opts { display:flex; flex-wrap:wrap; gap:8px; }
  .opt { display:flex; flex-direction:column; gap:1px; padding:9px 14px; border:2px solid var(--stroke); border-radius:9px;
    background:var(--card); cursor:pointer; font-weight:600; font-size:13.5px; color:inherit; box-shadow:2px 2px 0 var(--shadow); }
  .opt small { font:400 11px var(--mono); color:var(--dim); }
  .opt.sel { background:var(--bloomd); color:var(--on-bloom); border-color:var(--bloomd); box-shadow:none; }
  .done-row { background:var(--paper); border:2px solid var(--line); border-radius:9px; padding:11px 14px; font-size:13.5px; margin-bottom:6px; }
  .foot { display:flex; justify-content:flex-end; gap:8px; margin-top:24px; }
  .btn { padding:9px 18px; border:2px solid var(--stroke); border-radius:9px; box-shadow:2px 2px 0 var(--shadow);
    font-weight:600; font-size:13.5px; cursor:pointer; background:var(--card); color:inherit; text-decoration:none; display:inline-flex; align-items:center; }
  .btn.primary { background:var(--bloomd); color:var(--on-bloom); border-color:var(--bloomd); box-shadow:none; }
  .btn:disabled { opacity:.5; cursor:default; }
  .big-btn { padding:11px 22px; font-size:14.5px; }
</style>
