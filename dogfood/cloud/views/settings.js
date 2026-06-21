WB.scopedStyles('/settings', `
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
`);

WB.view('/settings', {
  title: 'Settings',
  accent: 'var(--violet)',
  async render(el, ctx) {
    const toast = (m, k) => WB.toast(m, k);
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // ── state ──
    let domains = [];
    let domHost = '';
    let domBusy = false;
    let domLocked = false;

    let tokens = [];
    let minted = null;
    let tokName = '';
    let minting = false;

    let name = 'Shane';
    let theme = 'dark';
    if (typeof document !== 'undefined') theme = document.documentElement.getAttribute('data-theme') || 'dark';

    let backup = { connected: false, host: null, url: null };
    let bkUrl = '';

    const AUTH_PROVIDERS = [
      { id: 'builtin', name: 'Built-in', blurb: "Workbooks' own end-user auth — nothing to configure." },
      { id: 'clerk', name: 'Clerk', blurb: "Use Clerk for your app's users." },
      { id: 'auth0', name: 'Auth0', blurb: "Use Auth0 for your app's users." }
    ];
    let authProvider = 'builtin';

    // ── logic ──
    function humanize(e) {
      const m = String(e?.message || e);
      if (m.includes('TXT')) return 'TXT record not found yet — allow DNS to propagate, then retry';
      if (m.includes('409')) return 'That host is already in use';
      return 'Could not add that domain';
    }
    function copyText(t, label) { navigator.clipboard?.writeText(t).then(() => toast(`${label} copied`)); }

    function setTheme(t) {
      theme = t;
      document.documentElement.setAttribute('data-theme', t);
      try { localStorage.setItem('wb-theme', t); } catch {}
      paint();
    }

    async function addDom() {
      const host = domHost.trim().toLowerCase();
      if (!host) { toast('Enter a domain'); return; }
      domBusy = true; paint();
      try {
        const d = await WB.api.addDomain(host);
        domains = [...domains, d]; domHost = ''; domLocked = false;
        toast('Domain added — publish the TXT record, then verify');
      } catch (e) {
        if (String(e.message || e).includes('402')) { domLocked = true; toast('Custom domains need a paid plan'); }
        else toast(humanize(e));
      }
      domBusy = false; paint();
    }
    async function verifyDom(id) {
      try {
        const d = await WB.api.verifyDomain(id);
        domains = domains.map((x) => (x.id === id ? d : x));
        toast(d.status === 'active' ? 'Verified — provisioning your certificate' : 'Verification pending');
      } catch (e) { toast(humanize(e)); }
      paint();
    }
    async function removeDom(id) {
      try { await WB.api.removeDomain(id); domains = domains.filter((x) => x.id !== id); toast('Domain removed'); }
      catch { toast('Could not remove'); }
      paint();
    }

    async function generateToken() {
      minting = true; paint();
      try {
        const r = await WB.api.mintToken(tokName.trim() || 'cli');
        minted = r.token; tokName = '';
        tokens = await WB.api.listTokens();
        toast('Token generated — copy it now');
      } catch { toast('Could not generate token'); }
      minting = false; paint();
    }
    async function revoke(id) {
      try { await WB.api.revokeToken(id); tokens = tokens.filter((t) => t.id !== id); if (minted) minted = null; toast('Token revoked'); }
      catch { toast('Could not revoke'); }
      paint();
    }
    function copyMinted() { navigator.clipboard?.writeText(minted).then(() => toast('Token copied')); }

    function connectBackup() {
      const url = bkUrl.trim();
      if (!url) { toast('Enter a repository URL'); return; }
      const host = url.includes('gitlab') ? 'GitLab' : url.includes('github') ? 'GitHub' : 'Git host';
      backup = { connected: true, host, url };
      toast(`Backup connected to ${host}`);
      paint();
    }

    // ── render ──
    function paint() {
      const mintedRow = minted ? `
      <div class="srow"><label>New token</label>
        <span style="display:flex;gap:8px;align-items:center;flex:1;justify-content:flex-end;min-width:0">
          <code class="mono" style="font-size:12px;overflow:hidden;text-overflow:ellipsis">${esc(minted)}</code>
          <button class="btn sm primary" data-act="copyMinted">Copy</button>
        </span>
      </div>
      <p class="faint" style="font-size:12px;margin:6px 0 0">Copy it now — for security, you won't be able to see it again.</p>` : '';

      const tokensList = tokens.length ? `
      <div style="margin-top:6px">
        ${tokens.map((t) => `
          <div class="kv"><span class="k mono">${esc(t.name)}</span>
            <span style="display:flex;gap:10px;align-items:center">
              <span class="v faint mono" style="font-size:11.5px">${esc(t.id)}</span>
              <button class="btn sm" data-revoke="${esc(t.id)}">Revoke</button>
            </span>
          </div>`).join('')}
      </div>` : '';

      const domLockedRow = domLocked ? `
      <div class="kv"><span class="k">Plan</span><span class="v faint">Custom domains need a paid plan — <a href="/upgrade">upgrade</a> to bind one.</span></div>` : '';

      const domList = domains.map((d) => {
        let body = '';
        if (d.status !== 'active' && d.verify) {
          body += `
          <p class="faint" style="font-size:12px;margin:8px 0 4px">Add these DNS records at your provider, then click Verify:</p>
          <div class="dns"><span class="t">TXT</span><code class="mono" data-copy="txtname" data-id="${esc(d.id)}">${esc(d.verify.name)}</code><code class="mono" data-copy="txtval" data-id="${esc(d.id)}">${esc(d.verify.value)}</code></div>
          <div class="dns"><span class="t">CNAME</span><code class="mono" data-copy="cnname" data-id="${esc(d.id)}">${esc(d.cname.name)}</code><code class="mono" data-copy="cntarget" data-id="${esc(d.id)}">${esc(d.cname.target)}</code></div>`;
        }
        if (d.status === 'active') {
          body += `
          <p class="faint" style="font-size:12px;margin:8px 0 0">● Live — your apps are served from <b>${esc(d.host)}</b>. ${d.dns_validation?.target ? `Certificate validating via <code class="mono">${esc(d.dns_validation.target)}</code>.` : ''}</p>`;
        }
        return `
        <div class="dom">
          <div class="dom-head">
            <span class="k mono">${esc(d.host)}</span>
            <span style="display:flex;gap:10px;align-items:center">
              <span class="badge${d.status === 'active' ? ' active' : ''}${d.status === 'pending' ? ' pending' : ''}">${esc(d.status)}</span>
              ${d.status !== 'active' ? `<button class="btn sm primary" data-verify="${esc(d.id)}">Verify</button>` : ''}
              <button class="btn sm" data-remove="${esc(d.id)}">Remove</button>
            </span>
          </div>${body}
        </div>`;
      }).join('');

      const backupBody = backup.connected ? `
      <div class="kv"><span class="k">Status</span><span class="v" style="color:var(--live)">● Connected to ${esc(backup.host)}</span></div>
      <div class="kv"><span class="k">Repository</span><span class="v mono" style="font-size:12px">${esc(backup.url)}</span></div>
      <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:10px">
        <button class="btn sm" data-act="bkNow">Back up now</button>
        <button class="btn sm" data-act="bkDisconnect">Disconnect</button>
      </div>` : `
      <div class="srow"><label for="bkurl">Repository URL</label><input id="bkurl" class="sinput" placeholder="https://github.com/you/workspace.git" value="${esc(bkUrl)}" /></div>
      <div style="display:flex;justify-content:flex-end;margin-top:8px">
        <button class="btn sm primary" data-act="connectBackup">Connect backup</button>
      </div>`;

      const authProviders = AUTH_PROVIDERS.map((p) => `
        <div class="reg${authProvider === p.id ? ' sel' : ''}" role="button" tabindex="0" data-prov="${esc(p.id)}">${esc(p.name)}</div>`).join('');
      const authBlurb = (AUTH_PROVIDERS.find((p) => p.id === authProvider) || {}).blurb || '';
      const authExtra = authProvider !== 'builtin' ? `
      <div class="srow" style="margin-top:8px"><label for="iss">Issuer URL</label><input id="iss" class="sinput" placeholder="https://your-tenant.${esc(authProvider)}.com" /></div>
      <div style="display:flex;justify-content:flex-end;margin-top:8px"><button class="btn sm primary" data-act="saveProvider">Save provider</button></div>` : '';

      el.innerHTML = `
<section>
  <div class="sechead"><div><h2>Settings</h2><p>Your account &amp; preferences</p></div></div>

  <div class="card">
    <h3>Profile</h3>
    <div style="display:flex;align-items:center;gap:14px;margin-bottom:12px">
      <div class="avatar">S</div>
      <button class="btn sm" data-act="changePhoto">Change photo</button>
    </div>
    <div class="srow"><label for="name">Name</label><input id="name" class="sinput" value="${esc(name)}" /></div>
    <div class="srow"><label for="email">Email</label><div class="sval">shane@shinyobjectz.com</div></div>
    <div style="display:flex;justify-content:flex-end;margin-top:8px"><button class="btn sm primary" data-act="saveProfile">Save changes</button></div>
  </div>

  <div class="card">
    <h3>Preferences</h3>
    <div class="srow"><label>Appearance</label>
      <div class="seg">
        <button class="${theme === 'dark' ? 'on' : ''}" data-theme="dark">Dark</button>
        <button class="${theme === 'light' ? 'on' : ''}" data-theme="light">Light</button>
      </div>
    </div>
    <div class="srow"><label>Default region</label><div class="sval">San Francisco (sfo)</div></div>
  </div>

  <div class="card">
    <h3>Security</h3>
    <div class="kv"><span class="k">Sign-in method</span><span class="v">Google</span></div>
    <div class="kv"><span class="k">Two-factor auth</span><span style="display:flex;gap:10px;align-items:center"><span class="v faint">Not enabled</span><button class="btn sm" data-act="enable2fa">Enable</button></span></div>
    <div class="kv"><span class="k">This device</span><button class="btn sm" data-act="signout">Sign out</button></div>
  </div>

  <div class="card">
    <h3>CLI access</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Generate a token, then run <code class="mono">work login --token &lt;token&gt;</code> to drive the <code class="mono">work</code> CLI against your account — deploy workbooks and manage nexuses, headless.</p>
    ${mintedRow}
    <div class="srow"><label for="tokname">Name</label>
      <input id="tokname" class="sinput" placeholder="my-laptop" value="${esc(tokName)}" />
      <button class="btn sm primary" data-act="generateToken"${minting ? ' disabled' : ''}>${minting ? 'Generating…' : 'Generate token'}</button>
    </div>
    ${tokensList}
  </div>

  <!-- Custom domains (paid-tier, owner-verified) -->
  <div class="card">
    <h3>Custom domains</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Share your apps from <i>your</i> domain instead of ours. Add a domain, prove you own it with a DNS record, and we put it on top of your nexus — replacing the default <code class="mono">.workbooks.sh</code> address. <span class="faint">Available on Team and Scale plans.</span></p>

    ${domLockedRow}

    <div class="srow"><label for="domhost">Domain</label>
      <input id="domhost" class="sinput" placeholder="apps.yourcompany.com" value="${esc(domHost)}" />
      <button class="btn sm primary" data-act="addDom"${domBusy ? ' disabled' : ''}>${domBusy ? 'Adding…' : 'Add domain'}</button>
    </div>

    ${domList}
  </div>

  <!-- Backup (Phase 6) -->
  <div class="card">
    <h3>Backup</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Keep a developer-friendly copy of your whole workspace on a git host — your folders become directories, drafts become branches, and every change is a commit you can browse.</p>
    ${backupBody}
  </div>

  <!-- App authentication (Phase 6) -->
  <div class="card">
    <h3>App authentication</h3>
    <p class="dim" style="font-size:13px;margin-bottom:12px">Choose how the people who use <i>your</i> deployed app sign in. Use the built-in option, or connect your own provider. (This is separate from how you sign in here.)</p>
    <div class="regions">
      ${authProviders}
    </div>
    <p class="faint" style="font-size:12px;margin-top:10px">${esc(authBlurb)}</p>
    ${authExtra}
  </div>

  <div class="card danger-zone">
    <h3>Danger zone</h3>
    <div style="display:flex;align-items:center;justify-content:space-between;gap:16px">
      <p class="dim" style="font-size:13px">Permanently delete your account and all workspaces. This cannot be undone.</p>
      <button class="btn danger sm" data-act="deleteAccount">Delete account</button>
    </div>
  </div>
</section>`;

      wire();
    }

    function wire() {
      // inputs (preserve state without re-render on keystroke)
      const nameI = el.querySelector('#name'); if (nameI) nameI.oninput = (e) => { name = e.target.value; };
      const tokI = el.querySelector('#tokname'); if (tokI) tokI.oninput = (e) => { tokName = e.target.value; };
      const bkI = el.querySelector('#bkurl'); if (bkI) bkI.oninput = (e) => { bkUrl = e.target.value; };
      const domI = el.querySelector('#domhost');
      if (domI) {
        domI.oninput = (e) => { domHost = e.target.value; };
        domI.onkeydown = (e) => { if (e.key === 'Enter') addDom(); };
      }

      el.querySelectorAll('[data-theme]').forEach((b) => b.onclick = () => setTheme(b.getAttribute('data-theme')));
      el.querySelectorAll('[data-revoke]').forEach((b) => b.onclick = () => revoke(b.getAttribute('data-revoke')));
      el.querySelectorAll('[data-verify]').forEach((b) => b.onclick = () => verifyDom(b.getAttribute('data-verify')));
      el.querySelectorAll('[data-remove]').forEach((b) => b.onclick = () => removeDom(b.getAttribute('data-remove')));
      el.querySelectorAll('[data-copy]').forEach((c) => c.onclick = () => {
        const id = c.getAttribute('data-id');
        const d = domains.find((x) => x.id === id);
        if (!d) return;
        const k = c.getAttribute('data-copy');
        if (k === 'txtname') copyText(d.verify.name, 'Name');
        else if (k === 'txtval') copyText(d.verify.value, 'Value');
        else if (k === 'cnname') copyText(d.cname.name, 'Name');
        else if (k === 'cntarget') copyText(d.cname.target, 'Target');
      });
      el.querySelectorAll('[data-prov]').forEach((r) => {
        const id = r.getAttribute('data-prov');
        r.onclick = () => { authProvider = id; paint(); };
        r.onkeydown = (e) => { if (e.key === 'Enter') { authProvider = id; paint(); } };
      });

      const acts = {
        changePhoto: () => toast('Photo upload opening…'),
        saveProfile: () => toast('Profile saved'),
        enable2fa: () => toast('Two-factor setup opening…'),
        signout: () => toast('Signed out'),
        generateToken,
        copyMinted,
        addDom,
        connectBackup,
        bkNow: () => toast('Backing up…'),
        bkDisconnect: () => { backup = { connected: false, host: null, url: null }; toast('Backup disconnected'); paint(); },
        saveProvider: () => toast(`${authProvider} connected`),
        deleteAccount: () => toast('Account deletion requires email confirmation')
      };
      el.querySelectorAll('[data-act]').forEach((b) => {
        const fn = acts[b.getAttribute('data-act')];
        if (fn) b.onclick = fn;
      });
    }

    paint();

    // onMount loads
    try { domains = await WB.api.listDomains(); paint(); } catch {}
    try { tokens = await WB.api.listTokens(); paint(); } catch {}
  }
});
