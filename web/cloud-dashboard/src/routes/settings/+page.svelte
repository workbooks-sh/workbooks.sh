<script>
  import { toast } from '$lib/toastStore.svelte.js';

  let name = $state('Shane');
  let theme = $state('dark');
  if (typeof document !== 'undefined') theme = document.documentElement.getAttribute('data-theme') || 'dark';

  function setTheme(t) {
    theme = t;
    document.documentElement.setAttribute('data-theme', t);
    try { localStorage.setItem('wb-theme', t); } catch {}
  }
  function copyToken() {
    navigator.clipboard?.writeText('wb_live_a1b2c3d4e5f64f2a').then(() => toast('API key copied'));
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
    <h3>API keys</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Use this key to manage your nexuses programmatically.</p>
    <div class="srow"><label>Secret key</label>
      <span style="display:flex;gap:8px;align-items:center;flex:1;justify-content:flex-end">
        <code class="mono" style="font-size:12.5px">wb_live_••••••••4f2a</code>
        <button class="btn sm" onclick={copyToken}>Copy</button>
        <button class="btn sm" onclick={() => toast('New API key generated')}>Regenerate</button>
      </span>
    </div>
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
</style>
