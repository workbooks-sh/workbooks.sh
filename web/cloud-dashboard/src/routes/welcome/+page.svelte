<script>
  import { enhance } from '$app/forms';
  let { data } = $props();
  const first = $derived(data.user?.firstName || 'there');

  let stepKey = $state('intro');
  let history = $state([]);
  let accountType = $state('');   // 'personal' | 'org'
  let deploy = $state('');        // personal: 'local' | 'cloud'
  let usecases = $state([]);
  let orgName = $state('');
  let orgSize = $state('');
  let heard = $state('');
  let tier = $state('');          // chosen tier id

  const REGION = 'San Francisco · sfo';

  const USECASES = [
    ['tools', 'Internal tools'], ['data', 'Data apps'], ['sites', 'Sites & landers'],
    ['auto', 'Automations'], ['agents', 'AI agents'], ['other', 'Something else']
  ];
  const SIZES = ['Just me', '2–10', '11–50', '51–200', '200+'];
  const HEARD = ['Search', 'X / social', 'A friend', 'YouTube', 'Other'];

  // PLACEHOLDER tiers — gate on STORAGE, never seats. Unlimited users on every tier
  // (WorkOS auth is free to 1M MAU, so seats cost us ~nothing; compute + storage do).
  // each tier carries a representative team size, so the stack comparison scales with
  // the SELECTED tier (the value gap widens dramatically at Scale/Enterprise).
  const TIERS = [
    { id: 'free', name: 'Free', price: 0, storage: '2 GB', users: 2, blurb: 'Kick the tires.' },
    { id: 'starter', name: 'Starter', price: 29, storage: '50 GB', users: 6, blurb: 'A small team or project.' },
    { id: 'team', name: 'Team', price: 99, storage: '250 GB', users: 25, blurb: 'A growing team.' },
    { id: 'scale', name: 'Scale', price: 249, storage: '1 TB', users: 100, blurb: 'Serious storage + compute.' },
    { id: 'ent', name: 'Enterprise', price: null, storage: 'Custom', users: 250, blurb: 'SSO · SCIM · dedicated.' }
  ];
  // the "usual stack" they'd otherwise pay per seat — real comp prices (verify before a deck).
  // logos via Simple Icons (the lobe pack only covers AI/dev brands; this set is uniform).
  const STACK = [
    { name: 'Slack', cat: 'Chat', per: 18, slug: 'slack' },
    { name: 'Notion', cat: 'Docs', per: 20, slug: 'notion' },
    { name: 'Linear', cat: 'Project mgmt', per: 16, slug: 'linear' },
    { name: 'Retool', cat: 'Internal tools', per: 20, slug: 'retool' },
    { name: 'Vercel', cat: 'Dev hosting', per: 20, slug: 'vercel' }
  ];
  const logo = (slug) => `https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/${slug}.svg`;
  const STACK_PER_USER = STACK.reduce((a, s) => a + s.per, 0); // ≈ $94/user

  const recommended = $derived.by(() => {
    if (accountType === 'personal') return 'starter';
    if (orgSize === '200+') return 'ent';
    if (orgSize === '51–200') return 'scale';
    if (orgSize === '11–50') return 'team';
    return 'starter';
  });
  const selTier = $derived(TIERS.find((t) => t.id === (tier || recommended)) || TIERS[1]);
  const cmpUsers = $derived(selTier.users);              // comparison scales with the SELECTED tier
  const stackCost = $derived(cmpUsers * STACK_PER_USER);
  const isEnt = $derived(selTier.id === 'ent');

  function nextKey(k) {
    if (k === 'intro') return 'account';
    if (k === 'account') return accountType === 'org' ? 'usecase' : 'deploy';
    if (k === 'deploy') return deploy === 'local' ? 'local' : 'usecase';
    if (k === 'usecase') return accountType === 'org' ? 'org' : 'mirror';
    if (k === 'org') return 'mirror';
    if (k === 'mirror') return 'plan';
    if (k === 'plan') return accountType === 'org' ? 'team' : 'pay';
    if (k === 'team') return 'pay';
    return k;
  }
  function next() { history = [...history, stepKey]; stepKey = nextKey(stepKey); }
  function back() { if (!history.length) return; const h = [...history]; stepKey = h.pop(); history = h; }

  const path = $derived.by(() => {
    const seq = ['intro']; let k = 'intro'; let g = 0;
    while (k !== nextKey(k) && g++ < 12) { k = nextKey(k); seq.push(k); }
    return seq.filter((s) => s !== 'local');
  });
  const progress = $derived(Math.max(0, path.indexOf(stepKey)) / Math.max(1, path.length - 1));
  const ACCENTS = ['var(--mint)', 'var(--sky)', 'var(--peach)', 'var(--cream)', 'var(--sage)', 'var(--violet)'];
  const accent = $derived(ACCENTS[Math.max(0, path.indexOf(stepKey)) % ACCENTS.length]);

  const toggleUse = (id) => (usecases = usecases.includes(id) ? usecases.filter((x) => x !== id) : [...usecases, id]);
  const useLabels = $derived(usecases.map((id) => (USECASES.find((u) => u[0] === id) || [, id])[1]));
  const canNextOrg = $derived(orgName.trim().length > 0 && orgSize !== '');
  const ENT_GIF = 'https://media0.giphy.com/media/v1.Y2lkPTc5MGI3NjExem1wZTAzajMzb3JndW95dnh0MW9vaGVxaWlpcnd5N3Y3d2F2ZXc1ayZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/JROxfRtFCVgSgz8uRd/giphy.gif';
</script>

<div class="ob-canvas">
  <div class="ob-blobs" aria-hidden="true">
    <span style="--c:var(--mint);  top:-12%; left:-8%"></span>
    <span style="--c:var(--sky);   top:8%;  right:-10%"></span>
    <span style="--c:var(--peach); bottom:-14%; left:14%"></span>
    <span style="--c:var(--cream); bottom:6%; right:10%"></span>
    <span style="--c:var(--sage);  top:38%; left:42%"></span>
  </div>

  <div class="ob-card" class:wide={stepKey === 'plan'} style="--accent:{accent}">
    {#if stepKey !== 'intro' && stepKey !== 'local'}
      <div class="ob-rail"><i style="--p:{progress * 100}%"></i></div>
    {/if}

    {#if stepKey === 'intro'}
      <div class="ob-badge" style="background:{accent}">✦</div>
      <h1>Welcome, {first}</h1>
      <p class="sub">Workbooks is your whole software stack in one place — build, run, host, and collaborate. Let’s get you set up.</p>
      <div class="foot"><button class="btn primary" onclick={next}>Get started</button></div>

    {:else if stepKey === 'account'}
      <h1>Who’s this for?</h1>
      <p class="sub">This sets up your account — you can add teammates anytime.</p>
      <div class="picks">
        <button class="pick" class:sel={accountType === 'personal'} onclick={() => (accountType = 'personal')}>
          <span class="pic" style="background:var(--sky)">◦</span><b>Personal</b><small>Just me — build and run my own software.</small>
        </button>
        <button class="pick" class:sel={accountType === 'org'} onclick={() => (accountType = 'org')}>
          <span class="pic" style="background:var(--peach)">◇</span><b>Organization</b><small>A team — shared nexus, members, and roles.</small>
        </button>
      </div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next} disabled={!accountType}>Continue</button></div>

    {:else if stepKey === 'deploy'}
      <h1>Where should it run?</h1>
      <p class="sub">Workbooks runs anywhere. Pick how you want yours hosted.</p>
      <div class="picks">
        <button class="pick" class:sel={deploy === 'cloud'} onclick={() => (deploy = 'cloud')}>
          <span class="pic" style="background:var(--mint)">☁</span><b>Cloud</b><small>We host it — always on, nothing to install.</small>
        </button>
        <button class="pick" class:sel={deploy === 'local'} onclick={() => (deploy = 'local')}>
          <span class="pic" style="background:var(--cream)">▢</span><b>Local <span class="free">free</span></b><small>Run it on your own machine with the desktop app.</small>
        </button>
      </div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next} disabled={!deploy}>Continue</button></div>

    {:else if stepKey === 'usecase'}
      <h1>What do you want to build?</h1>
      <p class="sub">Pick any that fit — we’ll set you up with matching starters.</p>
      <div class="chips">
        {#each USECASES as [id, label]}
          <button class="chip" class:sel={usecases.includes(id)} onclick={() => toggleUse(id)}>{label}</button>
        {/each}
      </div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next} disabled={usecases.length === 0}>Continue</button></div>

    {:else if stepKey === 'org'}
      <h1>About your organization</h1>
      <p class="sub">A couple details so we can tailor your setup.</p>
      <div class="lab">Organization name</div>
      <div class="field"><input placeholder="Acme Inc." bind:value={orgName} /></div>
      <div class="lab">How big is your team?</div>
      <div class="chips">{#each SIZES as s}<button class="chip" class:sel={orgSize === s} onclick={() => (orgSize = s)}>{s}</button>{/each}</div>
      <div class="lab">How did you hear about us? <span class="opt-tag">optional</span></div>
      <div class="chips">{#each HEARD as h}<button class="chip" class:sel={heard === h} onclick={() => (heard = h)}>{h}</button>{/each}</div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next} disabled={!canNextOrg}>Continue</button></div>

    {:else if stepKey === 'mirror'}
      <div class="ob-badge" style="background:{accent}">✓</div>
      <h1>Here’s your setup</h1>
      <p class="sub">Based on what you told us — change anything later.</p>
      <div class="mirror">
        <div class="mrow"><span>Account</span><b>{accountType === 'org' ? (orgName || 'Your organization') : 'Personal'}</b></div>
        <div class="mrow"><span>Hosted in</span><b>{REGION} <small>auto-detected</small></b></div>
        <div class="mrow"><span>Starters</span><b>{useLabels.length ? useLabels.join(', ') : 'A blank workspace'}</b></div>
        <div class="mrow"><span>Pricing</span><b>No seat billing · pay for storage</b></div>
      </div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next}>Looks good</button></div>

    {:else if stepKey === 'plan'}
      <h1>No seat billing. Unlimited users.</h1>
      <p class="sub">Invite your whole {accountType === 'org' ? 'organization' : 'team'} — you only pay for storage.</p>

      <div class="vs-h">For a ~{cmpUsers}-person team — Workbooks vs the stack it replaces</div>
      <div class="vs-cols">
        <div class="vs-col us">
          <svg class="vs-logo" viewBox="0 0 113 66"><path fill="currentColor" d="M48 0h17v30l1 2c6 2 18-18 25-20 3 1 9 8 11 11-4 6-19 18-21 22v2c2 1 27 1 32 1 0 6 0 11-1 17-12 0-27 1-37-4-8-4-15-12-18-20l-2-8-2 14c-12 21-31 18-52 18 0-6 0-11 0-17 6 0 28 1 31-1l0-1c1-4-17-19-20-24 2-3 8-9 11-11 4-1 18 18 22 20 2 1 2 1 3 0 2-2 1-9 1-12V0Z"/></svg>
          <div class="vs-name">Workbooks</div>
          <div class="vs-price">{selTier.price === null ? "Let's talk" : selTier.price === 0 ? 'Free' : `$${selTier.price}`}{#if selTier.price}<small>/mo</small>{/if}</div>
          <div class="vs-cat">∞ users · {selTier.storage}</div>
        </div>
        <div class="vs-x">vs</div>
        {#each STACK as s}
          <div class="vs-col">
            <span class="vs-logo brand" style="--u:url('{logo(s.slug)}')" role="img" aria-label={s.name}></span>
            <div class="vs-name">{s.name}</div>
            <div class="vs-price strike">${(s.per * cmpUsers).toLocaleString()}<small>/mo</small></div>
            <div class="vs-cat">{s.cat}</div>
          </div>
        {/each}
      </div>
      <div class="vs-sum">Their stack ≈ <s>${stackCost.toLocaleString()}/mo</s> · Workbooks {selTier.price === null ? 'Enterprise' : selTier.price === 0 ? 'Free' : `$${selTier.price}/mo`} — unlimited users</div>

      <div class="tiers">
        {#each TIERS as t}
          <button class="tier" class:sel={selTier.id === t.id} onclick={() => (tier = t.id)}>
            {#if t.id === recommended}<span class="tag-rec" style="background:{accent}">For you</span>{/if}
            <div class="tn">{t.name}</div>
            <div class="tp">{t.price === null ? 'Talk' : t.price === 0 ? 'Free' : `$${t.price}`}{#if t.price}<small>/mo</small>{/if}</div>
            <div class="tmeta">∞ users · {t.storage}</div>
          </button>
        {/each}
      </div>

      {#if isEnt}
        <div class="ent2">
          <img class="ent-gif" src={ENT_GIF} alt="" />
          <p>Whoa, Nelly. Enterprise is tailored — SSO, SCIM, dedicated compute. Let’s find the right fit.</p>
        </div>
      {/if}

      <div class="foot">
        <button class="btn" onclick={back}>Back</button>
        {#if isEnt}
          <a class="btn primary" href="mailto:hello@workbooks.sh?subject=Workbooks%20Enterprise">Contact us →</a>
        {:else}
          <button class="btn primary" onclick={next}>Continue with {selTier.name}</button>
        {/if}
      </div>

    {:else if stepKey === 'team'}
      <h1>Invite your team</h1>
      <p class="sub">Add teammates now or later — and there’s no per-seat charge, so invite everyone.</p>
      <div class="field"><input placeholder="teammate@company.com" /></div>
      <div class="field"><input placeholder="another@company.com" /></div>
      <div class="foot"><button class="btn" onclick={back}>Back</button><button class="btn primary" onclick={next}>Continue</button></div>

    {:else if stepKey === 'pay'}
      {#if selTier.price === 0}
        <div class="ob-badge" style="background:{accent}">🎉</div>
        <h1>You’re on Free</h1>
        <p class="sub">Unlimited users and {selTier.storage}. Upgrade anytime when you need more storage — never for more people.</p>
        <form method="POST" action="?/finish" use:enhance>
          <div class="foot"><button class="btn primary big" type="submit">Enter your dashboard →</button></div>
        </form>
      {:else}
        <h1>Bring your nexus online</h1>
        <p class="sub">Your nexus spins up the moment payment goes through. Cancel anytime.</p>
        <div class="summary">
          <div class="srow"><b>{selTier.name}</b><b>${selTier.price}<small>/mo</small></b></div>
          <div class="sfeat">Unlimited users · {selTier.storage} · hosted in {REGION}</div>
        </div>
        <form method="POST" action="?/pay" use:enhance>
          <input type="hidden" name="tier" value={selTier.id} />
          <div class="foot">
            <button class="btn" type="button" onclick={back}>Back</button>
            <button class="btn primary big" type="submit">Continue to payment →</button>
          </div>
        </form>
        <form method="POST" action="?/finish" use:enhance><button class="skip" type="submit">I’ll set up billing later</button></form>
      {/if}

    {:else if stepKey === 'local'}
      <div class="ob-badge" style="background:{accent}">▢</div>
      <h1>Run Workbooks locally</h1>
      <p class="sub">Local runs on your own machine with the desktop app — free, no nexus needed.</p>
      <div class="foot">
        <button class="btn" onclick={back}>Back</button>
        <a class="btn primary" href="https://workbooks.sh" target="_blank" rel="noreferrer">Download the desktop app ↗</a>
      </div>
      <form method="POST" action="?/finish" use:enhance><button class="skip" type="submit">Continue to the dashboard anyway</button></form>
    {/if}
  </div>
</div>

<style>
  .ob-canvas { position:fixed; inset:0; display:grid; place-items:center; padding:24px; overflow:hidden;
    background:radial-gradient(120% 120% at 50% -20%, color-mix(in srgb, var(--mint) 22%, #fbfaf6), #fbfaf6 60%); }
  .ob-blobs { position:absolute; inset:0; pointer-events:none; }
  .ob-blobs span { position:absolute; width:42vw; height:42vw; max-width:560px; max-height:560px; border-radius:50%;
    background:var(--c); filter:blur(80px); opacity:.55; }
  .ob-card { position:relative; z-index:1; width:560px; max-width:100%; background:#fff; color:#1a1b1e;
    border:1px solid rgba(18,19,22,.1); border-radius:18px; padding:34px 36px 28px;
    transition:width .42s cubic-bezier(.3,.8,.3,1); }
  /* the pricing step needs room — grow the card so tiers + brand breakdown aren't squished */
  .ob-card.wide { width:880px; }

  .ob-rail { position:relative; height:6px; border-radius:3px; background:#eceae2; overflow:hidden; margin-bottom:24px; }
  .ob-rail i { position:absolute; inset:0; border-radius:3px;
    background:linear-gradient(90deg, var(--mint), var(--sky), var(--peach), var(--cream), var(--sage), var(--violet));
    clip-path:inset(0 calc(100% - var(--p,0%)) 0 0); transition:clip-path .35s cubic-bezier(.3,.8,.3,1); }
  .ob-badge { width:46px; height:46px; border-radius:13px; display:grid; place-items:center; font-size:22px;
    border:1px solid rgba(18,19,22,.12); margin-bottom:16px; }
  h1 { font-size:25px; margin:0 0 10px; letter-spacing:-.015em; }
  .sub { color:#5f635c; font-size:14px; line-height:1.6; margin:0 0 22px; }
  .lab { font-size:11.5px; color:#5f635c; text-transform:uppercase; letter-spacing:.05em; font-weight:700; margin:16px 0 9px; }
  .opt-tag { text-transform:none; letter-spacing:0; font-weight:500; color:#a0a59a; }

  .picks { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  .pick { text-align:left; padding:16px; border:1px solid rgba(18,19,22,.12); border-radius:13px; background:#fff;
    cursor:pointer; display:flex; flex-direction:column; gap:5px; transition:.1s; }
  .pick:hover { border-color:rgba(18,19,22,.3); }
  .pick.sel { border-color:#121316; }
  .pick .pic { width:30px; height:30px; border-radius:9px; display:grid; place-items:center; font-size:15px; margin-bottom:4px; }
  .pick b { font-size:15px; display:flex; align-items:center; gap:7px; }
  .pick small { color:#6a6f64; font-size:12.5px; line-height:1.5; }
  .free { font:600 9.5px var(--mono); text-transform:uppercase; letter-spacing:.06em; background:var(--mint); color:#1a1b1e; padding:2px 6px; border-radius:6px; }

  .chips { display:flex; flex-wrap:wrap; gap:8px; }
  .chip { padding:9px 14px; border:1px solid rgba(18,19,22,.14); border-radius:999px; background:#fff; cursor:pointer;
    font:600 13px var(--read); color:#1a1b1e; transition:.1s; }
  .chip:hover { border-color:rgba(18,19,22,.3); }
  .chip.sel { background:var(--accent); border-color:transparent; }

  .field { margin-bottom:9px; }
  .field input { width:100%; font-size:15px; padding:12px 14px; border:1px solid rgba(18,19,22,.14); border-radius:11px;
    background:#fbfaf6; color:#1a1b1e; outline:none; }
  .field input:focus { border-color:rgba(18,19,22,.4); }

  .mirror { border:1px solid rgba(18,19,22,.1); border-radius:13px; overflow:hidden; }
  .mrow { display:flex; justify-content:space-between; align-items:baseline; gap:14px; padding:13px 16px; border-bottom:1px solid rgba(18,19,22,.07); }
  .mrow:last-child { border:0; }
  .mrow span { color:#6a6f64; font-size:12.5px; }
  .mrow b { font-size:14px; text-align:right; } .mrow b small { color:#a0a59a; font:500 11px var(--mono); margin-left:6px; }

  .vs-h { font-size:12.5px; font-weight:600; color:#3a3f36; margin:0 0 11px; }
  .vs-cols { display:grid; grid-template-columns:1.25fr auto repeat(5, 1fr); gap:8px; align-items:stretch; }
  .vs-col { display:flex; flex-direction:column; align-items:center; text-align:center; gap:5px;
    padding:14px 8px 12px; border:1px solid rgba(18,19,22,.1); border-radius:12px; background:#fff; }
  .vs-col.us { background:color-mix(in srgb, var(--accent) 22%, #fff); border-color:#121316; }
  /* the Workbooks mark is an inline svg (wide aspect → height-driven); brand logos are
     CSS masks so they size + colour reliably (the source SVGs have no intrinsic size). */
  .vs-logo { height:30px; width:auto; display:block; margin-bottom:2px; }
  .vs-col.us .vs-logo { color:#121316; }
  .vs-logo.brand { width:30px; height:30px; background:#8a8f86;
    -webkit-mask:var(--u) center/contain no-repeat; mask:var(--u) center/contain no-repeat; }
  .vs-name { font:600 12px var(--read); }
  .vs-price { font-size:17px; font-weight:600; line-height:1.1; } .vs-price small { font:500 9.5px var(--mono); color:#a0a59a; }
  .vs-price.strike { color:#8a8f86; text-decoration:line-through; text-decoration-color:rgba(18,19,22,.3); }
  .vs-col .vs-cat { font:500 9.5px var(--mono); color:#9b9f93; line-height:1.4; }
  .vs-x { align-self:center; font:600 11px var(--mono); color:#b0b4a9; padding:0 2px; }
  .vs-sum { font:500 11.5px var(--mono); color:#6a6f64; margin:11px 0 18px; text-align:center; }
  .vs-sum s { color:#8a8f86; }

  .tiers { display:grid; grid-template-columns:repeat(5,1fr); gap:7px; }
  .tier { position:relative; text-align:left; padding:13px 10px 12px; border:1px solid rgba(18,19,22,.12); border-radius:12px;
    background:#fff; cursor:pointer; transition:.1s; }
  .tier:hover { border-color:rgba(18,19,22,.3); }
  .tier.sel { border-color:#121316; }
  .tier .tag-rec { position:absolute; top:-9px; left:8px; font:600 9px var(--mono); text-transform:uppercase; letter-spacing:.04em; color:#1a1b1e; padding:2px 6px; border-radius:5px; }
  .tier .tn { font:600 12px var(--read); }
  .tier .tp { font-size:17px; font-weight:600; margin:4px 0 5px; } .tier .tp small { font:500 10px var(--mono); color:#a0a59a; }
  .tier .tmeta { font:500 9.5px var(--mono); color:#6a6f64; line-height:1.5; }

  .ent2 { text-align:center; margin-top:16px; }
  .ent-gif { width:150px; max-width:55%; border-radius:12px; display:block; margin:0 auto 8px;
    animation:entpop .5s cubic-bezier(.2,.9,.25,1.05) both; }
  @keyframes entpop { 0%{ opacity:0; transform:scale(.7) translateY(10px); } 60%{ opacity:1; } 100%{ transform:none; } }
  @media (prefers-reduced-motion:reduce){ .ent-gif{ animation:none; } }
  .ent2 p { color:#5f635c; font-size:13px; line-height:1.55; max-width:42ch; margin:0 auto; }

  .summary { border:1px solid rgba(18,19,22,.1); border-radius:13px; padding:16px; margin-bottom:4px; }
  .srow { display:flex; justify-content:space-between; align-items:baseline; font-size:17px; font-weight:600; }
  .srow small { font:500 11px var(--mono); color:#a0a59a; }
  .sfeat { color:#6a6f64; font:500 11.5px var(--mono); margin-top:8px; line-height:1.5; }

  .foot { display:flex; justify-content:flex-end; gap:8px; margin-top:24px; }
  .skip { display:block; margin:14px auto 0; background:none; border:0; color:#8a8f86; font:600 12px var(--mono); cursor:pointer; text-decoration:underline; text-underline-offset:3px; }
  .skip:hover { color:#1a1b1e; }

  .btn { padding:11px 18px; border:1px solid rgba(18,19,22,.12); border-radius:10px;
    font:600 12.5px/1 var(--mono); letter-spacing:-.01em; cursor:pointer; background:#fff; color:#121316;
    text-decoration:none; display:inline-flex; align-items:center; transition:.1s; }
  .btn:hover { border-color:rgba(18,19,22,.35); }
  .btn.primary { background:#121316; color:#fbfaf3; border-color:#121316; }
  .btn.primary:hover { background:#000; }
  .btn:disabled { opacity:.4; cursor:default; }
  .btn.big { padding:12px 22px; font-size:13.5px; }
</style>
