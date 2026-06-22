// Toolkits — the unified library. A toolkit is the unit; it comes in two KINDS:
//   • PROVIDER toolkit — wraps an external service (GitHub, Google, Slack, fal, OpenRouter). Connect an
//     account; OAuth secrets seal as control-plane secrets, nothing here exposes a client secret.
//   • STANDALONE toolkit — needs no account (git, sandbox, ffmpeg, …).
// One feed: GET /cloud/toolkits (provider + standalone, each tagged kind + status). Connect/disconnect
// still hit the real /cloud/integrations/* routes. "Integrations" is gone as a page — it's just this kind.

WB.view('/toolkits', { title: 'Toolkits', accent: 'var(--sky)', async render(el){
  var esc = WB.esc;
  // Brand → real domain. We render the provider's actual full-color logo via the favicon service (every
  // brand has one, always full-color) on a light chip — simpleicons was monochrome-in-brand-color, so
  // dark brands (GitHub, Slack) disappeared on the dark card and some (fal) had no icon at all.
  var DOMAIN = { github:'github.com', google:'google.com', slack:'slack.com', fal:'fal.ai', openrouter:'openrouter.ai' };
  function logo(id){ return 'https://www.google.com/s2/favicons?domain=' + (DOMAIN[id] || (id + '.com')) + '&sz=128'; }

  function getJSON(url){ return fetch(url, { credentials:'same-origin' }).then(function(r){ return r.json(); }); }
  function send(url, method, body){
    return fetch(url, { method:method, credentials:'same-origin',
      headers:{ 'content-type':'application/json' }, body: body ? JSON.stringify(body) : undefined })
      .then(async function(r){ var j = await r.json().catch(function(){return {};}); if (!r.ok) throw (j.error || ('HTTP '+r.status)); return j; });
  }

  async function load(){
    var data = {};
    try { data = await getJSON('/cloud/toolkits'); } catch (e) {}
    return data.toolkits || [];
  }

  // ── connect flows (provider toolkits) ─────────────────────────────────────────────────────────
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
  // A provider toolkit card: logo, name, status, blurb, connected accounts + connect button (or a
  // "Coming soon" pill when the nexus hasn't configured its OAuth app yet).
  function providerCard(p){
    var accs = p.accounts || [];
    var on = accs.length > 0;
    var soon = p.status !== 'ready';
    return '<div class="tkcard' + (on ? ' on' : '') + (soon ? ' soon' : '') + '">' +
      '<div class="tktop"><span class="tkchip"><img class="tklogo" src="' + esc(logo(p.id)) + '" alt="" loading="lazy" onerror="this.style.display=\'none\';this.parentNode.textContent=this.parentNode.getAttribute(\'data-i\')" data-i="' + esc((p.name || '?').slice(0,1).toUpperCase()) + '"></span>' +
        '<span class="tkname">' + esc(p.name) + '</span>' +
        (soon ? '<span class="tkpill soon">Coming soon</span>' : (on ? '<span class="tkdot" title="Connected"></span>' : '')) + '</div>' +
      '<p class="tkblurb">' + esc(p.blurb || '') + '</p>' +
      (on ? '<div class="tkaccs">' + accs.map(function(a){
        return '<div class="tkacc"><span class="tkacclbl">' + esc(a.label || a.id) + '</span>' +
          '<button class="tkx" data-disc="' + esc(p.id) + '|' + esc(a.id) + '" title="Disconnect">✕</button></div>';
      }).join('') + '</div>' : '') +
      (soon ? '' : '<button class="tkbtn' + (on ? ' add' : '') + '" data-conn="' + esc(p.id) + '">' + (on ? '+ Add account' : 'Connect') + '</button>') +
    '</div>';
  }

  // A standalone toolkit card: no account; just availability. "ready" = usable by your agents now.
  function standaloneCard(t){
    var soon = t.status !== 'ready';
    return '<div class="tkcard' + (soon ? ' soon' : ' on') + '">' +
      '<div class="tktop"><span class="tkchip glyph">' + (WB.ICO_TOOLBOX || '') + '</span>' +
        '<span class="tkname">' + esc(t.name) + '</span>' +
        '<span class="tkpill ' + (soon ? 'soon' : 'ready') + '">' + (soon ? 'Coming soon' : 'Available') + '</span></div>' +
      '<p class="tkblurb">' + esc(t.blurb || '') + '</p>' +
      (t.category ? '<div class="tkmeta">' + esc(t.category) + '</div>' : '') +
    '</div>';
  }

  async function paint(){
    var all = await load();
    var providers = all.filter(function(t){ return t.kind === 'provider'; });
    var standalone = all.filter(function(t){ return t.kind === 'standalone'; });
    el.innerHTML =
      '<section class="tk">' +
        '<div class="tkhd"><h1 class="tktitle">Toolkits</h1>' +
          '<p class="tksub">Capabilities your agents and apps use. <b>Provider toolkits</b> wrap an external service — connect an account and its credentials seal as secrets. <b>Standalone toolkits</b> need no account.</p></div>' +
        '<div class="tkgroup"><span class="tkgrouptt">Provider toolkits</span><span class="tkgroupct">' + providers.length + '</span></div>' +
        '<div class="tkgrid">' + providers.map(providerCard).join('') + '</div>' +
        '<div class="tkgroup"><span class="tkgrouptt">Standalone toolkits</span><span class="tkgroupct">' + standalone.length + '</span></div>' +
        '<div class="tkgrid">' + standalone.map(standaloneCard).join('') + '</div>' +
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

// A small toolbox glyph for standalone toolkit cards (matches the rail icon).
WB.ICO_TOOLBOX = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 13h20v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2z"/><path d="M2.5 13 4.6 7.8A2 2 0 0 1 6.45 6.5h11.1a2 2 0 0 1 1.85 1.3L21.5 13"/><path d="M9 6.5V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1.5"/><path d="M2 13h6v2a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1v-2h6"/></svg>';

WB.scopedStyles('/toolkits', `
.tk { max-width: 920px; }
.tkhd { margin-bottom: 18px; }
.tktitle { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.tksub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; max-width: 620px; line-height: 1.5; }
.tkgroup { display: flex; align-items: center; gap: 8px; margin: 22px 0 10px; }
.tkgrouptt { font: 700 11px var(--read); letter-spacing: .07em; text-transform: uppercase; color: var(--dim); }
.tkgroupct { font: 600 11px var(--mono, monospace); color: var(--dim); background: var(--line); border-radius: 20px; padding: 1px 8px; }
.tkgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; }
.tkcard { display: flex; flex-direction: column; gap: 8px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; transition: border-color .12s; }
.tkcard:hover { border-color: var(--stroke); }
.tkcard.on { border-color: color-mix(in srgb, var(--live) 50%, var(--line)); }
.tkcard.soon { opacity: .72; }
.tktop { display: flex; align-items: center; gap: 10px; }
/* App-icon chip: a light rounded tile behind every logo so real brand colors (even dark ones) pop on
   the dark card. Provider chips hold the full-color logo; standalone chips hold the toolbox glyph. */
.tkchip { width: 32px; height: 32px; border-radius: 8px; flex: none; display: grid; place-items: center;
  background: #fff; border: 1px solid var(--line); box-shadow: 0 1px 2px rgba(0,0,0,.18);
  font: 700 14px var(--read); color: #333; overflow: hidden; }
.tkchip.glyph { background: var(--line); border-color: transparent; color: var(--dim); box-shadow: none; }
.tklogo { width: 20px; height: 20px; object-fit: contain; }
.tkname { font: 600 15px var(--read); color: var(--ink); }
.tkpill { margin-left: auto; font: 600 10px var(--read); text-transform: uppercase; letter-spacing: .04em; border-radius: 20px; padding: 2px 8px; }
.tkpill.soon { color: var(--dim); background: var(--line); }
.tkpill.ready { color: var(--live, #2e9e5b); background: color-mix(in srgb, var(--live, #2e9e5b) 14%, transparent); }
.tkdot { margin-left: auto; width: 8px; height: 8px; border-radius: 50%; background: var(--live); flex: none; }
.tkblurb { font: 500 12.5px var(--read); color: var(--dim); line-height: 1.4; flex: 1; }
.tkmeta { font: 600 10.5px var(--mono, monospace); color: var(--dim); text-transform: uppercase; letter-spacing: .04em; }
.tkaccs { display: flex; flex-direction: column; gap: 4px; }
.tkacc { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 5px 8px; }
.tkacclbl { font: 600 12px var(--read); color: var(--ink); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tkx { border: none; background: none; color: var(--dim); cursor: pointer; font-size: 12px; padding: 2px 4px; border-radius: 5px; }
.tkx:hover { color: var(--bad, #d33); background: var(--card); }
.tkbtn { border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 9px; padding: 8px 0; font: 600 13px var(--read); cursor: pointer; }
.tkbtn:hover { border-color: var(--ink); }
.tkbtn.add { background: none; border-style: dashed; color: var(--dim); }
.gwlbl { display: flex; align-items: center; gap: 8px; font: 600 12px var(--read); color: var(--dim); margin: 12px 0 4px; }
.gwcopy { margin-left: auto; border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 6px; padding: 2px 8px; font: 600 11px var(--read); cursor: pointer; }
.gwro { width: 100%; resize: none; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 8px; font: 500 12px var(--mono, monospace); color: var(--ink); box-sizing: border-box; }
`);
