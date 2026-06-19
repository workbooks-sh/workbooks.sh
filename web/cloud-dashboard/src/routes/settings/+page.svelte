<script>
  import { toast } from '$lib/toastStore.svelte.js';
  import { mintToken, listTokens, revokeToken, listDomains, addDomain, verifyDomain, removeDomain } from '$lib/api.js';
  import { onMount } from 'svelte';

  // ── Custom domains (paid-tier, owner-verified) ──
  let domains = $state([]);
  let domHost = $state('');
  let domBusy = $state(false);
  let domLocked = $state(false);   // tier doesn't allow custom domains
  onMount(async () => { try { domains = await listDomains(); } catch {} });
  async function addDom() {
    const host = domHost.trim().toLowerCase();
    if (!host) { toast('Enter a domain'); return; }
    domBusy = true;
    try {
      const d = await addDomain(host);
      domains = [...domains, d]; domHost = ''; domLocked = false;
      toast('Domain added — publish the TXT record, then verify');
    } catch (e) {
      if (String(e.message || e).includes('402')) { domLocked = true; toast('Custom domains need a paid plan'); }
      else toast(humanize(e));
    }
    domBusy = false;
  }
  async function verifyDom(id) {
    try {
      const d = await verifyDomain(id);
      domains = domains.map((x) => (x.id === id ? d : x));
      toast(d.status === 'active' ? 'Verified — provisioning your certificate' : 'Verification pending');
    } catch (e) { toast(humanize(e)); }
  }
  async function removeDom(id) {
    try { await removeDomain(id); domains = domains.filter((x) => x.id !== id); toast('Domain removed'); }
    catch { toast('Could not remove'); }
  }
  function humanize(e) {
    const m = String(e?.message || e);
    if (m.includes('TXT')) return 'TXT record not found yet — allow DNS to propagate, then retry';
    if (m.includes('409')) return 'That host is already in use';
    return 'Could not add that domain';
  }
  function copyText(t, label) { navigator.clipboard?.writeText(t).then(() => toast(`${label} copied`)); }

  // ── CLI access tokens ──
  let tokens = $state([]);
  let minted = $state(null);   // the one-time plaintext token
  let tokName = $state('');
  let minting = $state(false);
  onMount(async () => { try { tokens = await listTokens(); } catch {} });
  async function generateToken() {
    minting = true;
    try {
      const r = await mintToken(tokName.trim() || 'cli');
      minted = r.token; tokName = '';
      tokens = await listTokens();
      toast('Token generated — copy it now');
    } catch { toast('Could not generate token'); }
    minting = false;
  }
  async function revoke(id) {
    try { await revokeToken(id); tokens = tokens.filter((t) => t.id !== id); if (minted) minted = null; toast('Token revoked'); }
    catch { toast('Could not revoke'); }
  }
  function copyMinted() { navigator.clipboard?.writeText(minted).then(() => toast('Token copied')); }

  let name = $state('Shane');
  let theme = $state('dark');
  if (typeof document !== 'undefined') theme = document.documentElement.getAttribute('data-theme') || 'dark';

  function setTheme(t) {
    theme = t;
    document.documentElement.setAttribute('data-theme', t);
    try { localStorage.setItem('wb-theme', t); } catch {}
  }

  // Backup (mock — 1:1 with GET/POST /api/nexuses/:id/backup*)
  let backup = $state({ connected: false, host: null, url: null });
  let bkUrl = $state('');
  function connectBackup() {
    const url = bkUrl.trim();
    if (!url) { toast('Enter a repository URL'); return; }
    const host = url.includes('gitlab') ? 'GitLab' : url.includes('github') ? 'GitHub' : 'Git host';
    backup = { connected: true, host, url };
    toast(`Backup connected to ${host}`);
  }

  // App-auth providers (mirrors Workbooks.AuthIntegrations / GET /api/auth-integrations)
  const AUTH_PROVIDERS = [
    { id: 'builtin', name: 'Built-in', blurb: "Workbooks' own end-user auth — nothing to configure." },
    { id: 'clerk', name: 'Clerk', blurb: "Use Clerk for your app's users." },
    { id: 'workos', name: 'WorkOS', blurb: "Use WorkOS AuthKit for your app's users." },
    { id: 'auth0', name: 'Auth0', blurb: "Use Auth0 for your app's users." }
  ];
  let authProvider = $state('builtin');
</script>

<section>
  <div class="sechead"><div><h2>Settings</h2><p>Your account &amp; preferences</p></div></div>

  <div class="card">
    <h3>Profile</h3>
    <div style="display:flex;align-items:center;gap:14px;margin-bottom:12px">
      <div class="avatar">S</div>
      <button class="btn sm" onclick={() => toast('Photo upload opening…')}>Change photo</button>
    </div>
    <div class="srow"><label for="name">Name</label><input id="name" class="sinput" bind:value={name} /></div>
    <div class="srow"><label for="email">Email</label><div class="sval">shane@shinyobjectz.com</div></div>
    <div style="display:flex;justify-content:flex-end;margin-top:8px"><button class="btn sm primary" onclick={() => toast('Profile saved')}>Save changes</button></div>
  </div>

  <div class="card">
    <h3>Preferences</h3>
    <div class="srow"><label>Appearance</label>
      <div class="seg">
        <button class:on={theme === 'dark'} onclick={() => setTheme('dark')}>Dark</button>
        <button class:on={theme === 'light'} onclick={() => setTheme('light')}>Light</button>
      </div>
    </div>
    <div class="srow"><label>Default region</label><div class="sval">San Francisco (sfo)</div></div>
  </div>

  <div class="card">
    <h3>Security</h3>
    <div class="kv"><span class="k">Sign-in method</span><span class="v">Google</span></div>
    <div class="kv"><span class="k">Two-factor auth</span><span style="display:flex;gap:10px;align-items:center"><span class="v faint">Not enabled</span><button class="btn sm" onclick={() => toast('Two-factor setup opening…')}>Enable</button></span></div>
    <div class="kv"><span class="k">This device</span><button class="btn sm" onclick={() => toast('Signed out')}>Sign out</button></div>
  </div>

  <div class="card">
    <h3>CLI access</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Generate a token, then run <code class="mono">work login --token &lt;token&gt;</code> to drive the <code class="mono">work</code> CLI against your account — deploy workbooks and manage nexuses, headless.</p>
    {#if minted}
      <div class="srow"><label>New token</label>
        <span style="display:flex;gap:8px;align-items:center;flex:1;justify-content:flex-end;min-width:0">
          <code class="mono" style="font-size:12px;overflow:hidden;text-overflow:ellipsis">{minted}</code>
          <button class="btn sm primary" onclick={copyMinted}>Copy</button>
        </span>
      </div>
      <p class="faint" style="font-size:12px;margin:6px 0 0">Copy it now — for security, you won't be able to see it again.</p>
    {/if}
    <div class="srow"><label for="tokname">Name</label>
      <input id="tokname" class="sinput" placeholder="my-laptop" bind:value={tokName} />
      <button class="btn sm primary" onclick={generateToken} disabled={minting}>{minting ? 'Generating…' : 'Generate token'}</button>
    </div>
    {#if tokens.length}
      <div style="margin-top:6px">
        {#each tokens as t (t.id)}
          <div class="kv"><span class="k mono">{t.name}</span>
            <span style="display:flex;gap:10px;align-items:center">
              <span class="v faint mono" style="font-size:11.5px">{t.id}</span>
              <button class="btn sm" onclick={() => revoke(t.id)}>Revoke</button>
            </span>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- Custom domains (paid-tier, owner-verified) -->
  <div class="card">
    <h3>Custom domains</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Share your apps from <i>your</i> domain instead of ours. Add a domain, prove you own it with a DNS record, and we put it on top of your nexus — replacing the default <code class="mono">.workbooks.sh</code> address. <span class="faint">Available on Team and Scale plans.</span></p>

    {#if domLocked}
      <div class="kv"><span class="k">Plan</span><span class="v faint">Custom domains need a paid plan — <a href="/billing">upgrade</a> to bind one.</span></div>
    {/if}

    <div class="srow"><label for="domhost">Domain</label>
      <input id="domhost" class="sinput" placeholder="apps.yourcompany.com" bind:value={domHost} onkeydown={(e) => { if (e.key === 'Enter') addDom(); }} />
      <button class="btn sm primary" onclick={addDom} disabled={domBusy}>{domBusy ? 'Adding…' : 'Add domain'}</button>
    </div>

    {#each domains as d (d.id)}
      <div class="dom">
        <div class="dom-head">
          <span class="k mono">{d.host}</span>
          <span style="display:flex;gap:10px;align-items:center">
            <span class="badge" class:active={d.status === 'active'} class:pending={d.status === 'pending'}>{d.status}</span>
            {#if d.status !== 'active'}<button class="btn sm primary" onclick={() => verifyDom(d.id)}>Verify</button>{/if}
            <button class="btn sm" onclick={() => removeDom(d.id)}>Remove</button>
          </span>
        </div>
        {#if d.status !== 'active' && d.verify}
          <p class="faint" style="font-size:12px;margin:8px 0 4px">Add these DNS records at your provider, then click Verify:</p>
          <div class="dns"><span class="t">TXT</span><code class="mono" onclick={() => copyText(d.verify.name, 'Name')}>{d.verify.name}</code><code class="mono" onclick={() => copyText(d.verify.value, 'Value')}>{d.verify.value}</code></div>
          <div class="dns"><span class="t">CNAME</span><code class="mono" onclick={() => copyText(d.cname.name, 'Name')}>{d.cname.name}</code><code class="mono" onclick={() => copyText(d.cname.target, 'Target')}>{d.cname.target}</code></div>
        {/if}
        {#if d.status === 'active'}
          <p class="faint" style="font-size:12px;margin:8px 0 0">● Live — your apps are served from <b>{d.host}</b>. {#if d.dns_validation?.target}Certificate validating via <code class="mono">{d.dns_validation.target}</code>.{/if}</p>
        {/if}
      </div>
    {/each}
  </div>

  <!-- Backup (Phase 6) -->
  <div class="card">
    <h3>Backup</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Keep a developer-friendly copy of your whole workspace on a git host — your folders become directories, drafts become branches, and every change is a commit you can browse.</p>
    {#if backup.connected}
      <div class="kv"><span class="k">Status</span><span class="v" style="color:var(--live)">● Connected to {backup.host}</span></div>
      <div class="kv"><span class="k">Repository</span><span class="v mono" style="font-size:12px">{backup.url}</span></div>
      <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:10px">
        <button class="btn sm" onclick={() => toast('Backing up…')}>Back up now</button>
        <button class="btn sm" onclick={() => { backup = { connected: false, host: null, url: null }; toast('Backup disconnected'); }}>Disconnect</button>
      </div>
    {:else}
      <div class="srow"><label for="bkurl">Repository URL</label><input id="bkurl" class="sinput" placeholder="https://github.com/you/workspace.git" bind:value={bkUrl} /></div>
      <div style="display:flex;justify-content:flex-end;margin-top:8px">
        <button class="btn sm primary" onclick={connectBackup}>Connect backup</button>
      </div>
    {/if}
  </div>

  <!-- App authentication (Phase 6) -->
  <div class="card">
    <h3>App authentication</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Choose how the people who use <i>your</i> deployed app sign in. Use the built-in option, or connect your own provider. (This is separate from how you sign in here.)</p>
    <div class="regions">
      {#each AUTH_PROVIDERS as p}
        <div class="reg" role="button" tabindex="0" class:sel={authProvider === p.id}
             onclick={() => (authProvider = p.id)} onkeydown={(e) => { if (e.key === 'Enter') authProvider = p.id; }}>{p.name}</div>
      {/each}
    </div>
    <p class="faint" style="font-size:12px;margin-top:10px">{(AUTH_PROVIDERS.find((p) => p.id === authProvider) || {}).blurb}</p>
    {#if authProvider !== 'builtin'}
      <div class="srow" style="margin-top:8px"><label for="iss">Issuer URL</label><input id="iss" class="sinput" placeholder="https://your-tenant.{authProvider}.com" /></div>
      <div style="display:flex;justify-content:flex-end;margin-top:8px"><button class="btn sm primary" onclick={() => toast(`${authProvider} connected`)}>Save provider</button></div>
    {/if}
  </div>

  <div class="card danger-zone">
    <h3>Danger zone</h3>
    <div style="display:flex;align-items:center;justify-content:space-between;gap:16px">
      <p class="dim" style="font-size:13px">Permanently delete your account and all workspaces. This cannot be undone.</p>
      <button class="btn danger sm" onclick={() => toast('Account deletion requires email confirmation')}>Delete account</button>
    </div>
  </div>
</section>

<style>
  .avatar { width:44px; height:44px; border-radius:50%; display:grid; place-items:center; font:700 16px var(--sans);
    color:var(--on-bloom); background:linear-gradient(135deg,var(--peach),var(--blue)); border:2px solid var(--stroke); }
  .srow { display:flex; align-items:center; gap:14px; padding:9px 0; border-bottom:1px solid var(--line-soft); }
  .srow:last-child { border:0; }
  .srow label { width:130px; color:var(--dim); font-size:13px; flex:none; }
  .sval { color:var(--ink); font-size:13px; flex:1; text-align:right; }
  .sinput { flex:1; height:36px; padding:0 11px; border:2px solid var(--line); border-radius:8px; background:var(--card);
    color:var(--ink); font:400 14px var(--sans); outline:none; }
  .sinput:focus { border-color:var(--ink); }
  .seg { display:flex; border:2px solid var(--stroke); border-radius:9px; overflow:hidden; margin-left:auto; }
  .seg button { padding:6px 16px; font:600 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); background:var(--card); cursor:pointer; }
  .seg button.on { background:var(--ink); color:var(--paper); }
  .dom { padding:11px 0; border-bottom:1px solid var(--line-soft); }
  .dom:last-child { border:0; }
  .dom-head { display:flex; align-items:center; justify-content:space-between; gap:10px; }
  .badge { font:600 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; padding:3px 8px; border-radius:6px;
    background:var(--card); border:1.5px solid var(--line); color:var(--dim); }
  .badge.pending { color:var(--peach-ink, #9a6a3a); border-color:var(--peach); }
  .badge.active { color:var(--live); border-color:var(--live); }
  .dns { display:flex; align-items:center; gap:8px; margin:5px 0; flex-wrap:wrap; }
  .dns .t { font:600 10px var(--mono); letter-spacing:.05em; color:var(--dim); width:52px; flex:none; }
  .dns code { font-size:11.5px; padding:3px 7px; background:var(--card); border:1.5px solid var(--line); border-radius:6px; cursor:pointer; }
  .dns code:hover { border-color:var(--ink); }
</style>
