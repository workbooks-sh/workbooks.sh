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

  // a soft pastel accent PER STEP — the multi-pastel feel, anchored by the green CTA
  const ACCENTS = ['var(--mint)', 'var(--sky)', 'var(--peach)', 'var(--cream)', 'var(--sage)'];
  const accent = $derived(ACCENTS[step % ACCENTS.length]);

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

<!-- full-bleed, multi-pastel canvas; unique class names so the dashboard's global .wrap can't leak in -->
<div class="ob-canvas">
  <div class="ob-blobs" aria-hidden="true">
    <span style="--c:var(--mint);   top:-12%; left:-8%"></span>
    <span style="--c:var(--sky);    top:8%;  right:-10%"></span>
    <span style="--c:var(--peach);  bottom:-14%; left:14%"></span>
    <span style="--c:var(--cream);  bottom:6%;  right:10%"></span>
    <span style="--c:var(--sage);   top:38%; left:42%"></span>
  </div>

  <div class="ob-card" style="--accent:{accent}">
    <div class="ob-rail">
      {#each STEPS as s, i}
        <div class="ob-dot" class:on={i === step} class:done={i < step}></div>
      {/each}
    </div>

    {#if step === 0}
      <div class="ob-badge" style="background:{accent}">✦</div>
      <h1>Welcome, {first}</h1>
      <p class="sub">Let’s set up your workspace — about a minute. You’ll name it, spin up your first nexus, and (optionally) connect billing.</p>
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
      <p class="sub">Add a payment method to go beyond the free allowance — or skip and add it later. Your nexus keeps running on the starter allowance.</p>
      {#if createdNexus}
        <div class="done-row" style="background:color-mix(in srgb, {accent} 42%, #fff); color:#1a1b1e">✓ Nexus <b>{createdNexus.name}</b> is building in {region}.</div>
      {/if}
      <div class="foot">
        <button class="btn" onclick={back}>Back</button>
        <a class="btn" href="/billing/checkout?plan=team" onclick={() => (billingDone = true)}>Set up billing ↗</a>
        <button class="btn primary" onclick={next}>{billingDone ? 'Continue' : 'Skip for now'}</button>
      </div>

    {:else}
      <div class="ob-badge" style="background:{accent}">🎉</div>
      <h1>You’re all set</h1>
      <p class="sub">Your workspace is ready. Jump in to manage your nexus, history, drafts, and shared folders.</p>
      <form method="POST" action="?/finish" use:enhance>
        <div class="foot"><button class="btn primary big-btn" type="submit">Enter your dashboard →</button></div>
      </form>
    {/if}
  </div>
</div>

<style>
  /* a distinct, light, multi-pastel moment — NOT the dark app chrome */
  .ob-canvas {
    position:fixed; inset:0; display:grid; place-items:center; padding:24px; overflow:hidden;
    background:
      radial-gradient(120% 120% at 50% -20%, color-mix(in srgb, var(--mint) 22%, #fbfaf6), #fbfaf6 60%);
  }
  /* absolute so the blobs DON'T take a grid row (which pushed the card off-center) */
  .ob-blobs { position:absolute; inset:0; pointer-events:none; }
  .ob-blobs span {
    position:absolute; width:42vw; height:42vw; max-width:560px; max-height:560px; border-radius:50%;
    background:var(--c); filter:blur(80px); opacity:.55;
  }
  .ob-card {
    position:relative; z-index:1; width:520px; max-width:100%;
    background:#fff; color:#1a1b1e; border:1px solid rgba(18,19,22,.12); border-radius:18px;
    box-shadow:var(--soft-2); padding:36px 36px 28px;
  }
  .ob-rail { display:flex; gap:7px; margin-bottom:24px; }
  .ob-dot { height:5px; flex:1; border-radius:3px; background:#eceae2; }
  .ob-dot.on { background:#121316; }
  .ob-dot.done { background:color-mix(in srgb, #121316 42%, #eceae2); }
  .ob-badge { width:46px; height:46px; border-radius:13px; display:grid; place-items:center;
    font-size:22px; border:1px solid rgba(18,19,22,.12); margin-bottom:16px; box-shadow:var(--soft-1); }
  h1 { font-size:25px; margin:0 0 10px; letter-spacing:-.01em; }
  .sub { color:#5f635c; font-size:14px; line-height:1.6; margin:0 0 20px; }
  .big { width:100%; font-size:18px; padding:13px 15px; border:1px solid rgba(18,19,22,.12); border-radius:11px;
    background:#fbfaf6; color:#1a1b1e; box-shadow:var(--soft-1); }
  .big:focus { outline:none; box-shadow:var(--soft-2); }
  .lab { font-size:12px; color:#5f635c; text-transform:uppercase; letter-spacing:.05em; font-weight:700; margin:14px 0 8px; }
  .opts { display:flex; flex-wrap:wrap; gap:8px; }
  .opt { display:flex; flex-direction:column; gap:1px; padding:9px 14px; border:1px solid rgba(18,19,22,.12); border-radius:10px;
    background:#fff; cursor:pointer; font-weight:600; font-size:13.5px; color:#1a1b1e; box-shadow:var(--soft-1); }
  .opt small { font:400 11px var(--mono); color:#8a8f86; }
  .opt.sel { background:var(--accent); box-shadow:none; transform:none; }
  .opt.sel small { color:#3a3f36; }
  .done-row { border:1px solid rgba(18,19,22,.12); border-radius:11px; padding:11px 14px; font-size:13.5px; margin-bottom:6px; }
  .foot { display:flex; justify-content:flex-end; gap:8px; margin-top:26px; }
  /* buttons use Geist Mono, like the live site; PRIMARY is ink (not green) */
  .btn { padding:11px 18px; border:1px solid rgba(18,19,22,.12); border-radius:10px; box-shadow:var(--soft-1);
    font:600 12.5px/1 var(--mono); letter-spacing:-.01em; cursor:pointer; background:#fff; color:#121316;
    text-decoration:none; display:inline-flex; align-items:center; transition:transform .06s, box-shadow .06s; }
  .btn:hover { transform:translateY(-1px); box-shadow:var(--soft-1); }
  .btn.primary { background:#121316; color:#fbfaf3; border-color:#121316; }
  .btn.primary:hover { background:#000; }
  .btn:disabled { opacity:.4; cursor:default; transform:none; box-shadow:var(--soft-1); }
  .big-btn { padding:12px 22px; font-size:14.5px; }
</style>
