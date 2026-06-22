// Integrations — connected services for the nexus, wired to the real backend (server :integrations in
// integrations.work). The catalog + connection state come from GET /cloud/integrations; connecting runs
// the genuine flow per mode: OAuth2 = popup handshake, API-key = sealed paste, Google = domain-wide
// delegation (the cheapest broad-Workspace path — admin authorizes our service account once). Secrets
// themselves live under Admin → Secrets; this view never sees a client secret.

WB.view('/integrations', { title: 'Integrations', accent: 'var(--sky)', async render(el){
  var esc = WB.esc;
  // Brand → simpleicons slug (logo CDN). Falls back to a hidden img on miss.
  var SLUG = { github:'github', google:'google', composio:'composio', clerk:'clerk',
    cloudflare:'cloudflare', linear:'linear', asana:'asana', jira:'jira' };
  function logo(id){ return 'https://cdn.simpleicons.org/' + (SLUG[id] || id); }

  function getJSON(url){ return fetch(url, { credentials:'same-origin' }).then(function(r){ return r.json(); }); }
  function send(url, method, body){
    return fetch(url, { method:method, credentials:'same-origin',
      headers:{ 'content-type':'application/json' }, body: body ? JSON.stringify(body) : undefined })
      .then(async function(r){ var j = await r.json().catch(function(){return {};}); if (!r.ok) throw (j.error || ('HTTP '+r.status)); return j; });
  }

  async function load(){
    var data = {};
    try { data = await getJSON('/cloud/integrations'); } catch (e) {}
    return data.providers || [];
  }

  // ── connect flows ───────────────────────────────────────────────────────────────────────────
  async function connectApiKey(p){
    var label = await WB.prompt({ title:'Connect ' + p.name, placeholder:'Name this account', confirm:'Next' });
    if (!label) return false;
    var credential = await WB.prompt({ title: p.name + ' ' + (p.field || 'credential'), placeholder: p.hint || '', confirm:'Connect' });
    if (!credential) return false;
    try { await send('/cloud/integrations', 'POST', { provider:p.id, label:label, credential:credential }); WB.toast(p.name + ' connected'); return true; }
    catch (e) { WB.toast(String(e)); return false; }
  }

  function connectOauth(p){
    return new Promise(async function(resolve){
      var label = await WB.prompt({ title:'Connect ' + p.name, placeholder:'Name this account', confirm:'Authorize' });
      if (!label) return resolve(false);
      var info;
      try { info = await getJSON('/cloud/integrations/authorize?provider=' + encodeURIComponent(p.id) +
        '&label=' + encodeURIComponent(label) + '&origin=' + encodeURIComponent(location.origin)); }
      catch (e) { WB.toast('Could not start authorization'); return resolve(false); }
      if (!info || !info.url) { WB.toast(info && info.error ? info.error : 'Not configured'); return resolve(false); }
      var popup = window.open(info.url, 'wb-oauth', 'width=520,height=680');
      function onMsg(ev){ if (ev.data === 'wb-integration-connected'){ cleanup(); WB.toast(p.name + ' connected'); resolve(true); } }
      function cleanup(){ window.removeEventListener('message', onMsg); clearInterval(poll); }
      window.addEventListener('message', onMsg);
      // If the popup is closed without a message, stop waiting (treat as no-op refresh).
      var poll = setInterval(function(){ if (popup && popup.closed){ cleanup(); resolve(true); } }, 700);
    });
  }

  // Google Workspace via domain-wide delegation — the cheapest full-Workspace path. A purpose-built
  // modal: copyable client-id + scopes for the admin-console paste, then domain + admin inputs.
  function googleModal(d){
    return new Promise(function(resolve){
      var modal = document.createElement('div'); modal.className = 'modal';
      modal.innerHTML =
        '<div class="sheet" style="width:560px"><h2>Connect Google Workspace</h2>' +
        '<p class="sub">A Workspace super-admin authorizes our service account once, in ' +
          '<a href="' + esc(d.admin_console_url) + '" target="_blank" rel="noopener">Admin console → Security → API controls → Domain-wide delegation</a> → Add new.</p>' +
        '<label class="gwlbl">Client ID <button class="gwcopy" data-copy="cid">Copy</button></label>' +
        '<textarea class="gwro" id="gwCid" readonly rows="1">' + esc(d.client_id || '') + '</textarea>' +
        '<label class="gwlbl">OAuth scopes (comma-separated) <button class="gwcopy" data-copy="scopes">Copy</button></label>' +
        '<textarea class="gwro" id="gwScopes" readonly rows="3">' + esc(d.scopes_csv || '') + '</textarea>' +
        '<label class="gwlbl">Your Workspace domain</label>' +
        '<input class="winput" id="gwDomain" placeholder="example.com" autocomplete="off" spellcheck="false" />' +
        '<label class="gwlbl">Super-admin email to impersonate</label>' +
        '<input class="winput" id="gwAdmin" placeholder="admin@example.com" autocomplete="off" spellcheck="false" />' +
        '<div class="foot"><span></span><div style="display:flex;gap:8px">' +
        '<button class="btn" data-x="0">Cancel</button><button class="btn primary" data-x="1">Connect</button></div></div></div>';
      function done(v){ modal.remove(); resolve(v); }
      modal.addEventListener('click', function(e){
        if (e.target === modal) return done(null);
        var cp = e.target.closest('[data-copy]');
        if (cp){ WB.copy(cp.getAttribute('data-copy') === 'cid' ? d.client_id : d.scopes_csv, cp.getAttribute('data-copy') === 'cid' ? 'Client ID' : 'Scopes'); return; }
        var x = e.target.closest('[data-x]');
        if (x){ if (x.getAttribute('data-x') !== '1') return done(null);
          var domain = (modal.querySelector('#gwDomain').value || '').trim();
          var admin = (modal.querySelector('#gwAdmin').value || '').trim();
          if (!domain || admin.indexOf('@') < 0){ WB.toast('Domain + super-admin email required'); return; }
          done({ domain:domain, admin_email:admin }); }
      });
      document.body.appendChild(modal); modal.querySelector('#gwDomain').focus();
    });
  }

  async function connectGoogle(){
    var d = {};
    try { d = await getJSON('/cloud/integrations/google/delegation'); } catch (e) {}
    if (!d.configured){ WB.toast('Delegation service account not configured on this nexus'); return false; }
    var vals = await googleModal(d);
    if (!vals) return false;
    try { await send('/cloud/integrations/google/delegation', 'POST', vals); WB.toast('Google Workspace connected'); return true; }
    catch (e) { WB.toast(String(e)); return false; }
  }

  async function connect(p){
    var changed = p.id === 'google' ? await connectGoogle()
      : p.mode === 'api_key' ? await connectApiKey(p)
      : await connectOauth(p);
    if (changed) paint();
  }

  async function disconnect(p, acc){
    var ok = await WB.confirm({ title:'Disconnect ' + (acc.label || p.name) + '?',
      body:'The sealed credentials for this connection will be deleted.', confirm:'Disconnect', danger:true });
    if (!ok) return;
    try { await send('/cloud/integrations/' + encodeURIComponent(acc.id), 'DELETE'); WB.toast('Disconnected'); paint(); }
    catch (e) { WB.toast(String(e)); }
  }

  // ── render ──────────────────────────────────────────────────────────────────────────────────
  async function paint(){
    var providers = await load();
    el.innerHTML =
      '<section class="intg">' +
        '<div class="intghd"><h1 class="intgtitle">Integrations</h1>' +
          '<p class="intgsub">Connect services your agents and apps can use. Credentials are sealed as secrets; nothing here exposes a client secret.</p></div>' +
        '<div class="intggrid">' + providers.map(function(p){
          var accs = p.accounts || [];
          var on = accs.length > 0;
          return '<div class="intgcard' + (on ? ' on' : '') + '">' +
            '<div class="intgtop"><img class="intglogo" src="' + esc(logo(p.id)) + '" alt="" loading="lazy" onerror="this.style.visibility=\'hidden\'">' +
              '<span class="intgname">' + esc(p.name) + '</span>' +
              (p.configured === false && p.mode !== 'api_key' && p.id !== 'google' ? '<span class="intgwarn" title="OAuth app not configured on this nexus">needs setup</span>' : '') +
              (on ? '<span class="intgdot" title="Connected"></span>' : '') + '</div>' +
            '<p class="intgblurb">' + esc(p.blurb || '') + '</p>' +
            (on ? '<div class="intgaccs">' + accs.map(function(a){
              return '<div class="intgacc"><span class="intgacclbl">' + esc(a.label || a.id) + '</span>' +
                '<button class="intgx" data-disc="' + esc(p.id) + '|' + esc(a.id) + '" title="Disconnect">✕</button></div>';
            }).join('') + '</div>' : '') +
            '<button class="intgbtn' + (on ? ' add' : '') + '" data-conn="' + esc(p.id) + '">' + (on ? '+ Add account' : 'Connect') + '</button>' +
          '</div>';
        }).join('') + '</div>' +
      '</section>';

    var byId = {}; providers.forEach(function(p){ byId[p.id] = p; });
    el.querySelectorAll('[data-conn]').forEach(function(b){ b.onclick = function(){ connect(byId[b.getAttribute('data-conn')]); }; });
    el.querySelectorAll('[data-disc]').forEach(function(b){ b.onclick = function(){
      var parts = b.getAttribute('data-disc').split('|'); var p = byId[parts[0]];
      disconnect(p, (p.accounts || []).find(function(a){ return a.id === parts[1]; }) || { id: parts[1] });
    }; });
  }
  paint();
}});

WB.scopedStyles('/integrations', `
.intg { max-width: 920px; }
.intghd { margin-bottom: 18px; }
.intgtitle { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.intgsub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; max-width: 560px; }
.intggrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; }
.intgcard { display: flex; flex-direction: column; gap: 8px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; transition: border-color .12s; }
.intgcard:hover { border-color: var(--stroke); }
.intgcard.on { border-color: color-mix(in srgb, var(--live) 50%, var(--line)); }
.intgtop { display: flex; align-items: center; gap: 10px; }
.intglogo { width: 22px; height: 22px; object-fit: contain; flex: none; }
.intgname { font: 600 15px var(--read); color: var(--ink); }
.intgwarn { margin-left: auto; font: 600 10.5px var(--read); color: var(--gold, #b8860b); text-transform: uppercase; letter-spacing: .04em; }
.intgdot { margin-left: auto; width: 8px; height: 8px; border-radius: 50%; background: var(--live); flex: none; }
.intgblurb { font: 500 12.5px var(--read); color: var(--dim); line-height: 1.4; flex: 1; }
.intgaccs { display: flex; flex-direction: column; gap: 4px; }
.intgacc { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 5px 8px; }
.intgacclbl { font: 600 12px var(--read); color: var(--ink); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.intgx { border: none; background: none; color: var(--dim); cursor: pointer; font-size: 12px; padding: 2px 4px; border-radius: 5px; }
.intgx:hover { color: var(--bad, #d33); background: var(--card); }
.intgbtn { border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 9px; padding: 8px 0; font: 600 13px var(--read); cursor: pointer; }
.intgbtn:hover { border-color: var(--ink); }
.intgbtn.add { background: none; border-style: dashed; color: var(--dim); }
.gwlbl { display: flex; align-items: center; gap: 8px; font: 600 12px var(--read); color: var(--dim); margin: 12px 0 4px; }
.gwcopy { margin-left: auto; border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 6px; padding: 2px 8px; font: 600 11px var(--read); cursor: pointer; }
.gwro { width: 100%; resize: none; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 8px; font: 500 12px var(--mono, monospace); color: var(--ink); box-sizing: border-box; }
`);
