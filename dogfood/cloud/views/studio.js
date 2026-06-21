WB.scopedStyles('/usage', `
  .dial { padding:10px 0; border-bottom:1px solid var(--line-soft); }
  .dial:last-of-type { border:0; }
  .dial-top { display:flex; align-items:baseline; justify-content:space-between; margin-bottom:6px; }
  .dl { font:600 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
  .dv { font:600 13px var(--mono); color:var(--ink); }
  .dv.near { color:var(--peach-ink, #9a6a3a); }
  .dv.over { color:#c0392b; }
  .bar { height:8px; border-radius:6px; background:var(--line-soft); overflow:hidden; }
  .fill { height:100%; border-radius:6px; background:var(--live); transition:width .4s ease; }
  .fill.near { background:var(--peach, #f3c5a3); }
  .fill.over { background:#e07a5f; }
  .hot { margin-top:12px; padding:12px 14px; border:1.5px solid var(--peach, #f3c5a3); border-radius:10px; background:color-mix(in srgb, var(--peach, #f3c5a3) 14%, transparent); }
  .hot p { font-size:13px; margin:0 0 8px; }
  .shed { margin-top:10px; }
  .sh { display:block; font:600 10px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim); margin-bottom:4px; }
  .srow2 { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:3px 0; font-size:12.5px; }
  .srow2 .mono { font-size:12px; }
`);

// ═══════════════════════ Create — agent chat (wbchat: our vanilla chat library) ═══════════════════
// SolidJS shell (session rail) + the wbchat library (dogfood/cloud/wbchat/*) for the conversation —
// our framework-agnostic createChat() core, themed via --wbc-* vars. Session history
// is scoped to the user (within the org) via /cloud/agent/* — "New chat" + a rail of past sessions.
// ═══════════════════════ Studio — full-bleed agent workspace (wbchat + floating rail) ═════════════
// Full-bleed wbchat conversation with a FLOATING overlay icon rail on the left: + (new chat) and
// Activity (toggle the collapsible activity/sessions drawer). Custom tooltips on hover. The rail is the
// seam for future agent surfaces (issues an agent files, etc.). "Create" is the + (new chat) action here.
WB.view('/studio', { title: 'Studio', accent: 'var(--mint)', fullbleed: true, async render(el){
  // NOTE: no ?bundle — that inlines a SEPARATE solid-js core per import, so signals from one aren't
  // reactive in another's templates (For/class bindings silently never update). Plain imports let
  // esm.sh share ONE solid-js core across core/web/html, restoring reactivity.
  var S = await import('https://esm.sh/solid-js@1.9.5');
  var W = await import('https://esm.sh/solid-js@1.9.5/web');
  var html = (await import('https://esm.sh/solid-js@1.9.5/html')).default;
  var createSignal = S.createSignal, For = S.For, Show = S.Show;
  var vurl = WB.vurl || function (u) { return u; };
  var WBC = await import(vurl('../wbchat/core.js'));
  await import(vurl('../wbchat/components/index.js'));  // registers all parts + actions + composer add-ons
  var DEMO = await import(vurl('../wbchat/demo.js'));   // dev-only seed (?cdemo=1) exercising every part type
  (function(){ if (!document.getElementById('wbchat-theme')){ var l = document.createElement('link'); l.id = 'wbchat-theme'; l.rel = 'stylesheet'; l.href = vurl('./wbchat/theme.css'); document.head.appendChild(l); } })();
  var CDEMO = new URLSearchParams(location.search).get('cdemo') === '1';

  var U = (WB.user && WB.user.email) || 'anon';
  function api(path, opts){ return fetch(path, Object.assign({ credentials: 'same-origin', headers: { 'content-type': 'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  var ICONS = {
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>',
    projects: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.93a2 2 0 0 1-1.66-.9l-.82-1.2A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13c0 1.1.9 2 2 2Z"/></svg>',
    agent: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/></svg>'
  };
  // The models you can route the run through (the composer dropdown). Live from the nexus —
  // /cloud/models returns the provider's (OpenRouter) catalog, with a curated fallback. The selected
  // model id is passed to the agent run. (Agent selection moved out of the composer; this is models.)
  var MODELS = [];
  try { var mr = await api('/cloud/models'); MODELS = (mr && mr.models) || []; } catch (e) {}

  // Projects = draft / private workspaces — a purgatory for ideas you work on with the agent before
  // promoting them to a real workspace. v1: persisted client-side (wb-projects); promote → WB.ws.create.
  function loadProjects(){ try { return JSON.parse(localStorage.getItem('wb-projects') || '[]'); } catch (e) { return []; } }
  function saveProjects(p){ try { localStorage.setItem('wb-projects', JSON.stringify(p)); } catch (e) {} }
  function gid(){ return 'p' + Math.random().toString(36).slice(2, 9); }

  function Studio(){
    var ps = createSignal(loadProjects()); var projects = ps[0], setProjects = ps[1];
    var cp = createSignal(null); var curProj = cp[0], setCurProj = cp[1];
    var po = createSignal(false); var projOpen = po[0], setProjOpen = po[1];
    var chat = null;

    function persist(list){ setProjects(list.slice()); saveProjects(list); }
    function current(){ return projects().find(function(p){ return p.id === curProj(); }); }

    function newProject(){
      var p = { id: gid(), name: 'Untitled project', messages: [], updated: Date.now() };
      var list = projects().concat([p]); persist(list); setCurProj(p.id); setProjOpen(false);
      if (chat) { chat.clear(); chat.focus(); }
    }
    function openProject(id){
      setCurProj(id); setProjOpen(false);
      var p = projects().find(function(x){ return x.id === id; });
      if (chat && p) chat.setMessages(p.messages || []);
    }
    async function promote(id){
      var p = projects().find(function(x){ return x.id === id; }); if (!p) return;
      try { var ws = await WB.ws.create(p.name); WB.toast('Promoted “' + p.name + '” to a workspace'); }
      catch (e) { WB.toast('Couldn’t promote — ' + (e && e.message || 'try again'), 'bad'); return; }
      persist(projects().filter(function(x){ return x.id !== id; }));
      if (curProj() === id) setCurProj(null);
    }
    function recordTurn(userText, reply){
      var p = current(); if (!p) { newProject(); p = current(); }
      p.messages = (p.messages || []).concat([{ role: 'user', text: userText }, { role: 'assistant', text: reply }]);
      if (p.name === 'Untitled project' && userText) p.name = userText.slice(0, 40);
      p.updated = Date.now(); persist(projects());
    }
    function editAgent(){
      // Open the project/workspace's agent file in the Workspaces editor (a .work file you can edit + ⌘S).
      var ws = (WB.ws.active && (WB.ws.active.folder || WB.ws.active.id || WB.ws.active.name)) || 'workspace';
      WB._pendingFile = ws + '/agent.work'; WB.nav('/workspaces');
    }

    function mountChat(node){
      chat = WBC.createChat(node, {
        splash: true,
        placeholder: 'What do you want to build?',
        suggestions: ['Scaffold a new app', 'Draft a data model', 'Wire up an integration'],
        models: MODELS,
        send: function(text, ctx){
          return api('/cloud/agent/chat', { method: 'POST', body: JSON.stringify({ u: U, id: curProj(), message: text, model: ctx && ctx.model }) })
            .then(function(d){ var reply = (d && d.reply) || '(no reply)'; recordTurn(text, reply); return reply; });
        }
      });
      if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());
    }

    return html`
      <div class=${function(){ return 'studio' + (projOpen() ? ' projopen' : ''); }}>
        <section class="studio-chat" ref=${mountChat}></section>
        <aside class="studio-projects">
          <div class="studio-projects-hd"><span>Projects</span><button class="studio-pnew" title="New project" onClick=${newProject} innerHTML=${ICONS.plus}></button></div>
          <div class="studio-plist">
            <${For} each=${projects}>${function(p){
              return html`<div class=${function(){ return 'studio-prow' + (curProj() === p.id ? ' on' : ''); }}>
                <button class="studio-popen" onClick=${function(){ openProject(p.id); }} title=${p.name}>${p.name || 'Untitled'}</button>
                <button class="studio-ppromote" title="Promote to workspace" onClick=${function(){ promote(p.id); }}>↗</button>
              </div>`;
            }}<//>
            <${Show} when=${function(){ return projects().length === 0; }}><div class="studio-pempty">No projects yet. Start one with the agent, then promote it.</div><//>
          </div>
        </aside>
        <nav class="studio-rail">
          <button class="studio-railbtn" data-tip="New" aria-label="New" onClick=${newProject} innerHTML=${ICONS.plus}></button>
          <button class=${function(){ return 'studio-railbtn' + (projOpen() ? ' on' : ''); }} data-tip="Projects" aria-label="Projects" onClick=${function(){ setProjOpen(!projOpen()); }} innerHTML=${ICONS.projects}></button>
          <button class="studio-railbtn" data-tip="Edit agent" aria-label="Edit agent" onClick=${editAgent} innerHTML=${ICONS.agent}></button>
        </nav>
      </div>`;
  }
  el.innerHTML = '';
  W.render(Studio, el);
}});
// "Create" is now the + (new chat) inside Studio; keep the old route as a redirect.
WB.view('/create', { title: 'Studio', render(el){ WB.nav('/studio'); } });
// The studio-shell CSS (.studio / .studio-rail / .studio-railbtn) is GLOBAL in app.css so it's shared
// by every surface in the shell (Studio chat + Activity feed), keeping the floating rail locked in.
WB.scopedStyles('/studio', `
/* Projects drawer — slides in from the left (behind the floating rail), toggled by the rail. */
.studio-projects { position: absolute; left: 0; top: 0; bottom: 0; width: 300px; z-index: 20; box-sizing: border-box; padding: 12px 0 0 58px;
  display: flex; flex-direction: column; background: var(--card); border-right: 1px solid var(--line); box-shadow: 6px 0 22px rgba(0,0,0,.16);
  transform: translateX(-100%); transition: transform .2s ease; }
.studio.projopen .studio-projects { transform: translateX(0); }
.studio-projects-hd { display: flex; align-items: center; justify-content: space-between; padding: 4px 14px 8px; font: 700 11px var(--read); letter-spacing: .08em; text-transform: uppercase; color: var(--dim); }
.studio-pnew { width: 26px; height: 26px; border: 1px solid var(--line); background: none; color: var(--dim); border-radius: 7px; cursor: pointer; display: grid; place-items: center; }
.studio-pnew:hover { color: var(--ink); border-color: var(--stroke); }
.studio-pnew svg { width: 14px; height: 14px; }
.studio-plist { display: flex; flex-direction: column; gap: 1px; overflow-y: auto; padding: 0 8px 12px; }
.studio-prow { display: flex; align-items: center; border-radius: 8px; }
.studio-prow:hover, .studio-prow.on { background: var(--line); }
.studio-popen { flex: 1; min-width: 0; text-align: left; border: none; background: none; color: var(--ink); border-radius: 8px; padding: 8px 10px; font: 500 13px var(--read); cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.studio-ppromote { flex: none; width: 26px; height: 28px; border: none; background: none; color: var(--dim); cursor: pointer; opacity: 0; font-size: 14px; }
.studio-prow:hover .studio-ppromote { opacity: .7; }
.studio-ppromote:hover { opacity: 1; color: var(--ink); }
.studio-pempty { color: var(--dim); font: 500 12.5px var(--read); padding: 12px 10px; }
`);


WB.view('/usage', {
  title: 'Usage & billing',
  accent: 'var(--sage)',
  async render(el, ctx) {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // Paint-first (the load-time rule): show the header + a skeleton immediately, then fill after fetch.
    el.innerHTML = `<section><div class="sechead"><div><h2>Usage &amp; billing</h2><p class="dim">Loading…</p></div></div>` +
      `<div class="card faint" style="text-align:center;color:var(--dim)">Loading usage…</div></section>`;

    // +page.js loader: { usage: await nexusUsage() }
    const u = await WB.api.nexusUsage();
    const s = u.summary;
    const cap = u.capacity;   // {tier, next, ram, storage, topRam, topObjects}
    const hot = cap && (cap.ram.status !== 'ok' || cap.storage.status !== 'ok');

    let rowsHtml = '';
    if (u.rows.length === 0) {
      rowsHtml = `
    <div class="card faint" style="text-align:center;color:var(--dim)">
      No usage yet. Costs accrue as your nexuses run — idle time is free.
    </div>`;
    } else {
      rowsHtml = `
    <div class="card" style="padding:0;overflow:hidden">
      <table>
        <thead><tr><th>Nexus</th><th>Plan</th><th class="num">Active hrs</th><th class="num">Storage</th><th class="num">Database</th><th class="num">Cost</th></tr></thead>
        <tbody>
          ${u.rows.map((r) => `
            <tr>
              <td><b>${esc(r.name)}</b></td>
              <td class="dim">${esc(r.plan)}</td>
              <td class="num">${esc(r.activeHrs)}</td>
              <td class="num">${esc(r.storage)}</td>
              <td class="num${r.database === '—' ? ' faint' : ''}">${esc(r.database)}</td>
              <td class="num" style="color:var(--live)">${esc(r.cost)}</td>
            </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
    }

    let capHtml = '';
    if (cap) {
      const dials = [cap.ram, cap.storage].map((d, i) => `
        <div class="dial">
          <div class="dial-top"><span class="dl">${i === 0 ? 'RAM' : 'Storage'}</span><span class="dv${d.status === 'near' ? ' near' : ''}${d.status === 'over' ? ' over' : ''}">${esc(d.label)}</span></div>
          <div class="bar"><div class="fill${d.status === 'near' ? ' near' : ''}${d.status === 'over' ? ' over' : ''}" style="width:${Math.max(2, d.pct)}%"></div></div>
        </div>`).join('');

      let bottom = '';
      if (hot) {
        bottom = `
        <div class="hot">
          <p><b>Near capacity.</b> You're auto-scaling against your ${esc(cap.tier.name)} ceiling.
            ${cap.next ? `Move to <b>${esc(cap.next.name)}</b> (${esc(cap.next.ram_mb)} MB · ${esc(cap.next.storage_gb)} GB · ${esc(cap.next.price)}/mo) to keep growing` : `You're on the top tier — split into a new organization for more headroom`}.</p>
          ${cap.next ? `<a class="btn sm primary" href="/upgrade">Scale to ${esc(cap.next.name)}</a>` : ''}
        </div>
        ${cap.topRam.length ? `
        <div class="shed"><span class="sh">Top RAM</span>
            ${cap.topRam.slice(0, 4).map((r) => `<div class="srow2"><span class="dim">${esc(r.name)}</span><span class="mono">${esc(r.label)}</span></div>`).join('')}
          </div>` : ''}
        ${cap.topObjects.length ? `
        <div class="shed"><span class="sh">Biggest objects</span>
            ${cap.topObjects.slice(0, 4).map((o) => `<div class="srow2"><span class="mono dim">${esc(o.key)}</span><span class="mono">${esc(o.label)}</span></div>`).join('')}
          </div>` : ''}`;
      } else {
        bottom = `
        <p class="note">Healthy — plenty of headroom. We scale you up automatically as you grow, up to your tier ceiling.</p>`;
      }

      capHtml = `
    <div class="card">
      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:12px">
        <h3>Capacity — ${esc(cap.tier.name)} plan</h3>
        <span class="dim" style="font-size:12.5px">auto-scales within your tier · ${esc(cap.tier.ram_mb)} MB · ${esc(cap.tier.storage_gb)} GB</span>
      </div>
      ${dials}
      ${bottom}
    </div>`;
    }

    el.innerHTML = `
<section>
  <div class="sechead">
    <div><h2>Usage &amp; billing</h2><p>${esc(u.period)}</p></div>
    <button class="btn sm" data-invoice>Download invoice</button>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">Month to date</div><div class="v">${esc(s.monthToDate)}</div><div class="d dim">${esc(s.nexusCount)} nexuses</div></div>
    <div class="stat"><div class="k">Compute</div><div class="v">${esc(s.compute)}</div><div class="d dim">${esc(s.activeHrs)} active hrs</div></div>
    <div class="stat"><div class="k">Storage</div><div class="v">${esc(s.storage)}</div><div class="d dim">zero egress</div></div>
    <div class="stat"><div class="k">Database</div><div class="v">${esc(s.database)}</div><div class="d dim">managed Postgres</div></div>
  </div>
  ${rowsHtml}
  ${capHtml}
  <div class="card">
    <h3>Plan</h3>
    <div class="kv"><span class="k">Pricing</span><span class="v">No seat billing · unlimited users</span></div>
    <div class="kv"><span class="k">Model</span><span class="v">storage-gated tiers + metered active compute</span></div>
    <div class="note">Idle nexuses scale to zero, so you're billed for active compute, storage, and any database addon — not for sitting still, and never per seat.</div>
  </div>
</section>`;

    el.querySelector('[data-invoice]').addEventListener('click', () => WB.toast('Invoice downloading…'));
  }
});
