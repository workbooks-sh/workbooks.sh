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
  // Brand SVG + toolkit glyph resolvers live globally (glyphs.js) so the sidebar shares them.
  function brandGlyph(id){ return (window.WB && WB.brandGlyph) ? WB.brandGlyph(id) : null; }

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
      // No "name this account" step — go straight to OAuth; the connection is auto-labeled from the
      // authorized identity (GitHub login, Google email, …) server-side. New or existing, same flow.
      var info;
      try { info = await getJSON('/cloud/integrations/authorize?provider=' + encodeURIComponent(p.id) +
        '&origin=' + encodeURIComponent(location.origin)); }
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

  // Human-readable names for the delegation scopes (the raw URLs are what Google needs pasted, but a
  // person shouldn't have to read a wall of them). Unknown scopes fall back to their short tail.
  var SCOPE_LABELS = {
    'openid': 'Verify identity',
    'email': 'Email address',
    'https://www.googleapis.com/auth/admin.directory.user': 'Create & manage users',
    'https://www.googleapis.com/auth/admin.directory.user.alias': 'Manage user aliases',
    'https://www.googleapis.com/auth/admin.directory.domain': 'Manage domains',
    'https://www.googleapis.com/auth/admin.directory.group': 'Manage groups',
    'https://www.googleapis.com/auth/gmail.settings.basic': 'Gmail settings',
    'https://www.googleapis.com/auth/gmail.settings.sharing': 'Gmail send-as & forwarding',
    'https://www.googleapis.com/auth/gmail.modify': 'Read & send mail',
    'https://www.googleapis.com/auth/drive.file': 'Drive files it creates',
    'https://www.googleapis.com/auth/cloud-platform': 'Google Cloud'
  };
  function scopeName(u){ return SCOPE_LABELS[u] || u.replace('https://www.googleapis.com/auth/', ''); }

  // Google Workspace via domain-wide delegation — a guided two-step flow: (1) authorize our service
  // account in Google Admin (copy client id + scopes, open the console), (2) name the domain + admin.
  function googleModal(d){
    return new Promise(function(resolve){
      var scopes = d.scopes || [];
      var scopeList = scopes.map(function(s){ return '<li>' + esc(scopeName(s)) + '</li>'; }).join('');
      var modal = document.createElement('div'); modal.className = 'modal';
      modal.innerHTML =
        '<div class="sheet gw" style="width:600px">' +
          '<h2>Connect Google Workspace</h2>' +
          '<p class="sub">Give your agents access to your Workspace — users, email, Drive, Cloud. A super-admin authorizes this once.</p>' +

          '<div class="gwstep">' +
            '<div class="gwnum">1</div>' +
            '<div class="gwsbody">' +
              '<div class="gwsh">Authorize in Google Admin</div>' +
              '<p class="gwhint">Open Domain-wide delegation, click <b>Add new</b>, then paste the Client ID and scopes below.</p>' +
              '<a class="gwopen" href="' + esc(d.admin_console_url) + '" target="_blank" rel="noopener">Open Google Admin console ↗</a>' +
              '<div class="gwfield"><span class="gwk">Client ID</span><code class="gwv">' + esc(d.client_id || '') + '</code>' +
                '<button class="gwcopy" data-copy="cid">Copy</button></div>' +
              '<div class="gwfield col"><div class="gwfhead"><span class="gwk">Scopes <em>' + scopes.length + '</em></span>' +
                '<button class="gwcopy" data-copy="scopes">Copy all</button></div>' +
                '<ul class="gwscopes">' + scopeList + '</ul></div>' +
            '</div>' +
          '</div>' +

          '<div class="gwstep">' +
            '<div class="gwnum">2</div>' +
            '<div class="gwsbody">' +
              '<div class="gwsh">Confirm your Workspace</div>' +
              '<input class="winput" id="gwDomain" placeholder="Your domain — e.g. acme.com" autocomplete="off" spellcheck="false" />' +
              '<input class="winput" id="gwAdmin" placeholder="Super-admin email — e.g. admin@acme.com" autocomplete="off" spellcheck="false" />' +
              '<p class="gwhint">The admin the agent acts as for directory operations.</p>' +
            '</div>' +
          '</div>' +

          '<div class="foot"><span></span><div style="display:flex;gap:8px">' +
            '<button class="btn" data-x="0">Cancel</button><button class="btn primary" data-x="1">Connect</button></div></div>' +
        '</div>';
      function done(v){ modal.remove(); resolve(v); }
      modal.addEventListener('click', function(e){
        if (e.target === modal) return done(null);
        var cp = e.target.closest('[data-copy]');
        if (cp){ var which = cp.getAttribute('data-copy');
          WB.copy(which === 'cid' ? d.client_id : d.scopes_csv, which === 'cid' ? 'Client ID' : 'Scopes'); return; }
        var x = e.target.closest('[data-x]');
        if (x){ if (x.getAttribute('data-x') !== '1') return done(null);
          var domain = (modal.querySelector('#gwDomain').value || '').trim().replace(/^@/, '');
          var admin = (modal.querySelector('#gwAdmin').value || '').trim();
          if (!domain || admin.indexOf('@') < 0){ WB.toast('Enter your domain and a super-admin email'); return; }
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

  // Toolkit pastel themes live in glyphs.js (WB.TOOLKIT_GLYPHS), shared with the sidebar + agent selector.
  function tkTheme(id){ return (window.WB && WB.TOOLKIT_GLYPHS && WB.TOOLKIT_GLYPHS[id]) || { color:'var(--dim)', bg:'var(--line)', icon: WB.ICO_TOOLBOX || '' }; }

  // ── render ──────────────────────────────────────────────────────────────────────────────────
  // The chip (logo for an integration, themed pastel glyph for a built-in toolkit). Shared by card + modal.
  function chipHTML(it, big){
    var cls = 'tkchip' + (big ? ' big' : '');
    if (it.kind === 'standalone'){
      var th = tkTheme(it.id);
      return '<span class="' + cls + ' tint" style="background:' + th.bg + ';color:' + th.color + '">' + th.icon + '</span>';
    }
    var svg = brandGlyph(it.id);
    if (svg) return '<span class="' + cls + ' brand">' + svg + '</span>';
    // No curated glyph (e.g. fal) → a clean lettermark on the neutral chip.
    return '<span class="' + cls + ' brand letter">' + esc((it.name || '?').slice(0, 1).toUpperCase()) + '</span>';
  }

  // The label + dataset for an item's primary action, by kind/state.
  function actionFor(it){
    var soon = it.status !== 'ready';
    if (soon) return { soon: true };
    if (it.kind === 'standalone'){
      var on = it.enabled !== false;
      return { kind: 'toggle', id: it.id, label: on ? 'Disable' : 'Add', add: on };
    }
    var has = (it.accounts || []).length > 0;
    return { kind: 'conn', id: it.id, label: has ? '+ Add account' : 'Connect', add: has };
  }

  function actionBtn(it){
    var a = actionFor(it);
    if (a.soon) return '';
    var ds = a.kind === 'toggle' ? 'data-toggle="' + esc(a.id) + '"' : 'data-conn="' + esc(a.id) + '"';
    return '<button class="tkbtn' + (a.add ? ' add' : '') + '" ' + ds + '>' + a.label + '</button>';
  }

  // A card (integration or toolkit). The whole card is clickable → Learn-more modal; the action button
  // acts directly (stops propagation).
  function card(it){
    var soon = it.status !== 'ready';
    var on = it.kind === 'standalone' ? (it.enabled !== false && !soon) : ((it.accounts || []).length > 0);
    return '<div class="tkcard clickable' + (on ? ' on' : '') + (soon ? ' soon' : '') + '" data-info="' + esc(it.id) + '">' +
      '<div class="tktop">' + chipHTML(it) +
        '<span class="tkname">' + esc(it.name) + '</span>' +
        (soon ? '<span class="tkpill soon">Coming soon</span>' : (on ? '<span class="tkdot" title="Active"></span>' : '')) + '</div>' +
      '<p class="tkblurb">' + esc(it.blurb || '') + '</p>' +
      capMeta(it) +
      actionBtn(it) +
    '</div>';
  }

  // Small capability meta line: agent-led badge + model requirements (e.g. "Needs vision").
  function capMeta(it){
    if (it.kind !== 'standalone') return '';
    var bits = [];
    if (it.cap_kind === 'agent-led') bits.push('<span class="capbadge agent">Agent-led</span>');
    if (it.requires && it.requires.length) bits.push('<span class="capbadge req">Needs ' + esc(it.requires.join(', ')) + '</span>');
    return bits.length ? '<div class="capmeta">' + bits.join('') + '</div>' : '';
  }

  async function toggleToolkit(id){
    try { await send('/cloud/toolkits/' + encodeURIComponent(id) + '/toggle', 'POST'); paint(); }
    catch (e) { WB.toast(String(e)); }
  }

  function act(it){
    var a = actionFor(it);
    if (a.kind === 'toggle') return toggleToolkit(a.id);
    if (a.kind === 'conn') return connect(it);
  }

  // Learn-more modal — bigger chip, full description, status, and the same primary action.
  function infoModal(it){
    var soon = it.status !== 'ready';
    var a = actionFor(it);
    var modal = document.createElement('div'); modal.className = 'modal';
    modal.innerHTML =
      '<div class="sheet tkinfo" style="width:520px">' +
        '<div class="tkinfohd">' + chipHTML(it, true) +
          '<div><h2 style="margin:0">' + esc(it.name) + '</h2>' +
            '<div class="tkinfosub">' + (it.kind === 'standalone' ? ((it.cap_kind === 'agent-led' ? 'Agent-led' : 'Skill') + ' toolkit') : 'Integration') +
              (soon ? ' · Coming soon' : '') + '</div></div></div>' +
        '<p class="tkinfobody">' + esc(it.detail || it.blurb || '') + '</p>' +
        ((it.requires && it.requires.length) || it.recommends
          ? '<div class="tkreq">' +
              ((it.requires && it.requires.length) ? '<div><span class="tkreqk">Requires</span> ' + esc(it.requires.join(', ')) + '</div>' : '') +
              (it.recommends ? '<div><span class="tkreqk">Recommended model</span> ' + esc(it.recommends) + '</div>' : '') +
            '</div>' : '') +
        '<div class="foot"><span></span><div style="display:flex;gap:8px">' +
          '<button class="btn" data-x="0">Close</button>' +
          (soon ? '<button class="btn" disabled>Coming soon</button>'
                : '<button class="btn primary" data-act="1">' + esc(a.label.replace(/^\+ /, '')) + '</button>') +
        '</div></div>' +
      '</div>';
    function done(){ modal.remove(); }
    modal.addEventListener('click', function(e){
      if (e.target === modal) return done();
      if (e.target.closest('[data-x]')) return done();
      if (e.target.closest('[data-act]')){ done(); act(it); }
    });
    document.body.appendChild(modal);
  }

  async function paint(){
    var all = await load();
    var providers = all.filter(function(t){ return t.kind === 'provider'; });
    var standalone = all.filter(function(t){ return t.kind === 'standalone'; });
    el.innerHTML =
      '<section class="tk">' +
        '<div class="tkhd"><h1 class="tktitle">Toolkits</h1>' +
          '<p class="tksub">Capabilities your agents and apps use. <b>Integrations</b> connect an external account (credentials seal as secrets). <b>Toolkits</b> are built-in — no account needed.</p></div>' +
        '<div class="tkgroup"><span class="tkgrouptt">Integrations</span><span class="tkgroupct">' + providers.length + '</span></div>' +
        '<div class="tkgrid">' + providers.map(card).join('') + '</div>' +
        '<div class="tkgroup"><span class="tkgrouptt">Toolkits</span><span class="tkgroupct">' + standalone.length + '</span></div>' +
        '<div class="tkgrid">' + standalone.map(card).join('') + '</div>' +
      '</section>';

    var byId = {}; all.forEach(function(it){ byId[it.id] = it; });
    el.querySelectorAll('[data-conn]').forEach(function(b){ b.onclick = function(e){ e.stopPropagation(); connect(byId[b.getAttribute('data-conn')]); }; });
    el.querySelectorAll('[data-toggle]').forEach(function(b){ b.onclick = function(e){ e.stopPropagation(); toggleToolkit(b.getAttribute('data-toggle')); }; });
    el.querySelectorAll('[data-info]').forEach(function(c){ c.onclick = function(){ infoModal(byId[c.getAttribute('data-info')]); }; });
  }
  paint();
}});

// A small toolbox glyph for standalone toolkit cards (matches the rail icon).
WB.ICO_TOOLBOX = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 13h20v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2z"/><path d="M2.5 13 4.6 7.8A2 2 0 0 1 6.45 6.5h11.1a2 2 0 0 1 1.85 1.3L21.5 13"/><path d="M9 6.5V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1.5"/><path d="M2 13h6v2a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1v-2h6"/></svg>';

WB.scopedStyles('/toolkits', `
.tk { max-width: 1120px; }
.tkhd { margin-bottom: 18px; }
.tktitle { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.tksub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; max-width: 640px; line-height: 1.5; }
.tkgroup { display: flex; align-items: center; gap: 8px; margin: 26px 0 12px; }
.tkgrouptt { font: 700 11px var(--read); letter-spacing: .07em; text-transform: uppercase; color: var(--dim); }
.tkgroupct { font: 600 11px var(--mono, monospace); color: var(--dim); background: var(--line); border-radius: 20px; padding: 1px 8px; }
.tkgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(264px, 1fr)); gap: 14px; }
.tkcard { display: flex; flex-direction: column; gap: 8px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px; transition: border-color .12s, transform .08s, box-shadow .12s; }
.tkcard.clickable { cursor: pointer; }
.tkcard.clickable:hover { border-color: var(--stroke); transform: translateY(-2px); box-shadow: var(--soft-1, 0 4px 14px rgba(0,0,0,.18)); }
.tkcard.on { border-color: color-mix(in srgb, var(--live) 50%, var(--line)); }
.tkcard.soon { opacity: .72; }
.tktop { display: flex; align-items: center; gap: 10px; }
.tkname { font: 600 15px var(--read); color: var(--ink); }
.tkpill { margin-left: auto; font: 600 10px var(--read); text-transform: uppercase; letter-spacing: .04em; border-radius: 20px; padding: 2px 8px; }
.tkpill.soon { color: var(--dim); background: var(--line); }
.tkpill.ready { color: var(--live, #2e9e5b); background: color-mix(in srgb, var(--live, #2e9e5b) 14%, transparent); }
.tkdot { margin-left: auto; width: 8px; height: 8px; border-radius: 50%; background: var(--live); flex: none; }
.tkblurb { font: 500 12.5px var(--read); color: var(--dim); line-height: 1.4; flex: 1; }
.capmeta { display: flex; flex-wrap: wrap; gap: 5px; }
.capbadge { font: 600 10px var(--read); text-transform: uppercase; letter-spacing: .04em; border-radius: 20px; padding: 2px 8px; }
.capbadge.agent { color: var(--sky, #4a90d9); background: color-mix(in srgb, var(--sky, #4a90d9) 16%, transparent); }
.capbadge.req { color: var(--dim); background: var(--line); }
.tkmeta { font: 600 10.5px var(--mono, monospace); color: var(--dim); text-transform: uppercase; letter-spacing: .04em; }
.tkaccs { display: flex; flex-direction: column; gap: 4px; }
.tkacc { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 5px 8px; }
.tkacclbl { font: 600 12px var(--read); color: var(--ink); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tkx { border: none; background: none; color: var(--dim); cursor: pointer; font-size: 12px; padding: 2px 4px; border-radius: 5px; }
.tkx:hover { color: var(--bad, #d33); background: var(--card); }
.tkbtn { border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 9px; padding: 8px 0; font: 600 13px var(--read); cursor: pointer; }
.tkbtn:hover { border-color: var(--ink); }
.tkbtn.add { background: none; border-style: dashed; color: var(--dim); }
`);

// The Google connect modal mounts on document.body — OUTSIDE the route's [data-view] scope — so its
// styles MUST be global (scopedStyles would prefix them with [data-view="/toolkits"] and never match).
WB.styles(`
/* Chip styles are GLOBAL — used on cards (inside the view) AND in the Learn-more modal (on body). */
.tkchip { width: 32px; height: 32px; border-radius: 8px; flex: none; display: flex; align-items: center; justify-content: center;
  background: var(--line); border: 1px solid transparent; font: 700 14px var(--read); color: var(--ink); overflow: hidden; }
.tkchip.glyph { background: var(--line); border-color: transparent; color: var(--dim); }
.tkchip.tint { border-color: transparent; }
/* Brand chip: a neutral theme-adaptive tile holding the inlined full-color (or theme-picked mono) SVG. */
.tkchip.brand { background: color-mix(in srgb, var(--ink) 7%, transparent); border-color: var(--line); }
/* Fixed square box + the SVG's own preserveAspectRatio (xMidYMid meet) fits + CENTERS the logo. The
   prior max-height/height:auto combo let tall logos overflow (browsers ignore max-height when height is
   auto), so they clipped at the top. A fixed height keeps them vertically centered. */
.tkchip svg { width: 20px; height: 20px; display: block; }
.tkchip.big { width: 44px; height: 44px; border-radius: 11px; }
.tkchip.big svg { width: 26px; height: 26px; }
/* Learn-more modal */
.tkinfohd { display: flex; align-items: center; gap: 14px; margin-bottom: 14px; }
.tkinfosub { font: 600 11px var(--read); text-transform: uppercase; letter-spacing: .05em; color: var(--dim); margin-top: 3px; }
.tkinfobody { font: 500 14px var(--read); color: var(--prose, var(--ink)); line-height: 1.55; margin: 0; }
.tkreq { margin-top: 14px; display: flex; flex-direction: column; gap: 6px; font: 500 13px var(--read); color: var(--ink); }
.tkreq .tkreqk { font: 600 11px var(--read); text-transform: uppercase; letter-spacing: .04em; color: var(--dim); margin-right: 6px; }
.sheet.gw { max-height: 88vh; overflow: auto; }
.sheet.gw .sub { margin-bottom: 6px; }
.gwstep { display: flex; gap: 12px; padding: 14px 0; border-top: 1px solid var(--line); }
.gwstep:first-of-type { border-top: none; }
.gwnum { flex: none; width: 22px; height: 22px; border-radius: 50%; display: grid; place-items: center;
  background: var(--sky, #4a90d9); color: #fff; font: 700 12px var(--read); margin-top: 1px; }
.gwsbody { flex: 1; min-width: 0; }
.gwsh { font: 700 14px var(--read); color: var(--ink); margin-bottom: 3px; }
.gwhint { font: 500 12px var(--read); color: var(--dim); line-height: 1.45; margin: 0 0 10px; }
.gwopen { display: inline-block; margin-bottom: 12px; font: 600 12.5px var(--read); color: var(--sky, #4a90d9); text-decoration: none; }
.gwopen:hover { text-decoration: underline; }
.gwfield { display: flex; align-items: center; gap: 8px; background: var(--bg); border: 1px solid var(--line);
  border-radius: 8px; padding: 8px 10px; margin-bottom: 8px; }
.gwfield.col { flex-direction: column; align-items: stretch; gap: 8px; }
.gwfhead { display: flex; align-items: center; }
.gwk { font: 600 11px var(--read); text-transform: uppercase; letter-spacing: .04em; color: var(--dim); }
.gwk em { font-style: normal; margin-left: 6px; background: var(--line); border-radius: 20px; padding: 0 6px; font-size: 10px; }
.gwv { flex: 1; min-width: 0; font: 500 12.5px var(--mono, monospace); color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.gwcopy { margin-left: auto; flex: none; border: 1px solid var(--stroke); background: var(--card); color: var(--ink);
  border-radius: 6px; padding: 3px 10px; font: 600 11px var(--read); cursor: pointer; }
.gwcopy:hover { border-color: var(--ink); }
.gwscopes { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: 1fr 1fr; gap: 4px 14px;
  max-height: 150px; overflow: auto; }
.gwscopes li { font: 500 12px var(--read); color: var(--ink); position: relative; padding-left: 16px; line-height: 1.5; }
.gwscopes li::before { content: "✓"; position: absolute; left: 0; color: var(--live, #2e9e5b); font-size: 11px; }
.sheet.gw .winput { margin-bottom: 8px; }
`);
