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
  var S = await import('https://esm.sh/solid-js@1.9.5?bundle');
  var W = await import('https://esm.sh/solid-js@1.9.5/web?bundle');
  var html = (await import('https://esm.sh/solid-js@1.9.5/html?bundle')).default;
  var createSignal = S.createSignal, For = S.For, Show = S.Show;
  var WBC = await import('./wbchat/core.js');
  await import('./wbchat/components/index.js');  // registers all parts + actions + composer add-ons
  var DEMO = await import('./wbchat/demo.js');   // dev-only seed (?cdemo=1) exercising every part type
  (function(){ if (!document.getElementById('wbchat-theme')){ var l = document.createElement('link'); l.id = 'wbchat-theme'; l.rel = 'stylesheet'; l.href = './wbchat/theme.css'; document.head.appendChild(l); } })();
  var CDEMO = new URLSearchParams(location.search).get('cdemo') === '1';

  var U = (WB.user && WB.user.email) || 'anon';
  function api(path, opts){ return fetch(path, Object.assign({ credentials: 'same-origin', headers: { 'content-type': 'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  var ICONS = {
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>',
    activity: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>'
  };

  function Studio(){
    var ss = createSignal([]); var sessions = ss[0], setSessions = ss[1];
    var ci = createSignal(null); var curId = ci[0], setCurId = ci[1];
    var saved; try { saved = localStorage.getItem('wb-studio-activity'); } catch (e) {}
    // Activity is a toggleable panel that OVERLAYS the full-bleed chat — closed by default (open only if the user opened it before).
    var co = createSignal(saved !== 'open'); var collapsed = co[0], setCollapsedSig = co[1];
    function setCollapsed(v){ setCollapsedSig(v); try { localStorage.setItem('wb-studio-activity', v ? 'closed' : 'open'); } catch (e) {} }
    var chat = null;

    function loadSessions(){ api('/cloud/agent/sessions?u=' + encodeURIComponent(U)).then(function(d){ setSessions((d && d.sessions) || []); }); }
    function newChat(){ setCurId(null); if (chat) { chat.clear(); chat.focus(); } }
    function openSession(id){ api('/cloud/agent/session?u=' + encodeURIComponent(U) + '&id=' + encodeURIComponent(id)).then(function(d){ if (d && d.messages){ setCurId(d.id); if (chat) chat.setMessages(d.messages); } }); }
    loadSessions();

    function mountChat(node){
      chat = WBC.createChat(node, {
        placeholder: 'Message the agent…',
        greeting: { title: 'Build on your nexus', text: 'Ask the agent to build, deploy, or change something here.' },
        suggestions: ['Scaffold a new app', 'Show my workspaces', 'Deploy the docs site'],
        models: ['auto', 'gpt-4o-mini', 'claude-sonnet-4'],
        send: function(text, ctx){
          return api('/cloud/agent/chat', { method: 'POST', body: JSON.stringify({ u: U, id: curId(), message: text, model: ctx && ctx.model }) })
            .then(function(d){ if (d && d.id){ if (!curId()) setCurId(d.id); loadSessions(); return d.reply || ''; } return '(no reply)'; });
        }
      });
      if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());
    }

    return html`
      <div class=${function(){ return 'studio' + (collapsed() ? ' collapsed' : ''); }}>
        <section class="studio-chat" ref=${mountChat}></section>
        <aside class="studio-activity">
          <div class="studio-activity-hd"><span>Activity</span><button class="studio-newchat" title="New chat" onClick=${newChat} innerHTML=${ICONS.plus}></button></div>
          <div class="studio-sessions">
            <${For} each=${sessions}>${function(s){
              return html`<button class=${function(){ return 'studio-session' + (curId() === s.id ? ' on' : ''); }} onClick=${function(){ openSession(s.id); }} title=${s.title}>${s.title || 'Untitled'}</button>`;
            }}<//>
            <${Show} when=${function(){ return sessions().length === 0; }}><div class="studio-empty">No activity yet.</div><//>
          </div>
        </aside>
        <nav class="studio-rail">
          <button class="studio-railbtn" data-tip="New chat" aria-label="New chat" onClick=${newChat} innerHTML=${ICONS.plus}></button>
          <button class=${function(){ return 'studio-railbtn' + (collapsed() ? '' : ' on'); }} data-tip="Activity" aria-label="Activity" onClick=${function(){ setCollapsed(!collapsed()); }} innerHTML=${ICONS.activity}></button>
        </nav>
      </div>`;
  }
  el.innerHTML = '';
  W.render(Studio, el);
}});
// "Create" is now the + (new chat) inside Studio; keep the old route as a redirect.
WB.view('/create', { title: 'Studio', render(el){ WB.nav('/studio'); } });
WB.scopedStyles('/studio', `
.studio { position: absolute; inset: 0; }
/* full-bleed chat fills everything; the rail + drawer overlay it */
.studio-chat { position: absolute; inset: 0; display: flex; }
.studio-chat > .wb-chat { flex: 1; min-width: 0; }
/* floating overlay icon rail */
.studio-rail { position: absolute; left: 0; top: 0; bottom: 0; width: 52px; z-index: 30; display: flex; flex-direction: column;
  align-items: center; gap: 6px; padding: 12px 0; background: color-mix(in srgb, var(--card) 72%, transparent); backdrop-filter: blur(8px); border-right: 1px solid var(--line); }
.studio-railbtn { position: relative; width: 36px; height: 36px; border: none; background: none; color: var(--dim); cursor: pointer; border-radius: 9px; display: grid; place-items: center; }
.studio-railbtn:hover { background: var(--line); color: var(--ink); }
.studio-railbtn.on { background: var(--line); color: var(--ink); }
.studio-railbtn svg { width: 19px; height: 19px; }
.studio-railbtn[data-tip]:hover::after { content: attr(data-tip); position: absolute; left: calc(100% + 10px); top: 50%; transform: translateY(-50%);
  white-space: nowrap; background: var(--ink); color: var(--card); font: 600 11.5px var(--read); padding: 5px 9px; border-radius: 7px; pointer-events: none; z-index: 40; box-shadow: 0 4px 14px rgba(0,0,0,.25); }
/* collapsible activity drawer (overlays the chat from behind the rail) */
.studio-activity { position: absolute; left: 0; top: 0; bottom: 0; width: 300px; z-index: 20; box-sizing: border-box; padding-left: 52px;
  display: flex; flex-direction: column; background: var(--card); border-right: 1px solid var(--line); box-shadow: 6px 0 22px rgba(0,0,0,.16);
  transform: translateX(0); transition: transform .2s ease; }
.studio.collapsed .studio-activity { transform: translateX(-100%); box-shadow: none; }
.studio-activity-hd { display: flex; align-items: center; justify-content: space-between; padding: 14px 14px 8px; font: 700 11px var(--read); letter-spacing: .08em; text-transform: uppercase; color: var(--dim); }
.studio-newchat { width: 26px; height: 26px; border: 1px solid var(--line); background: none; color: var(--dim); border-radius: 7px; cursor: pointer; display: grid; place-items: center; }
.studio-newchat:hover { color: var(--ink); border-color: var(--stroke); }
.studio-newchat svg { width: 14px; height: 14px; }
.studio-sessions { display: flex; flex-direction: column; gap: 2px; overflow-y: auto; padding: 0 8px 12px; }
.studio-session { text-align: left; border: none; background: none; color: var(--dim); border-radius: 8px; padding: 8px 10px; font: 500 13px var(--read); cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.studio-session:hover { background: var(--line); color: var(--ink); }
.studio-session.on { background: var(--line); color: var(--ink); font-weight: 600; }
.studio-empty { color: var(--dim); font: 500 12.5px var(--read); padding: 12px 10px; }
`);

// ═══════════════════════ Apps — SolidJS beachhead (no-build: solid-js/html via ESM) ═══════════════
// Validates SolidJS inside the vanilla WB shell: fine-grained reactivity, no build lane. The app
// catalog is mocked for now; this is the seed of the "open your apps" surface (web-container view).
WB.view('/apps', { title: 'Apps', accent: 'var(--sky)', async render(el){
  var S = await import('https://esm.sh/solid-js@1.9.5?bundle');
  var W = await import('https://esm.sh/solid-js@1.9.5/web?bundle');
  var html = (await import('https://esm.sh/solid-js@1.9.5/html?bundle')).default;
  var createSignal = S.createSignal, For = S.For, Show = S.Show;

  var APPS = [
    { name: 'Orders', blurb: 'Customer order pipeline + fulfillment', icon: '🧾', color: 'var(--sky)', tag: 'app', status: 'running' },
    { name: 'Waitlist', blurb: 'Signup capture with live count', icon: '📋', color: 'var(--sage)', tag: 'app', status: 'running' },
    { name: 'Docs', blurb: 'Your team documentation site', icon: '📚', color: 'var(--peach)', tag: 'site', status: 'running' },
    { name: 'Analytics', blurb: 'Usage dashboards + funnels', icon: '📈', color: 'var(--violet)', tag: 'app', status: 'idle' },
    { name: 'Inbox', blurb: 'Shared support inbox + triage', icon: '✉️', color: 'var(--mint)', tag: 'app', status: 'idle' },
    { name: 'CRM', blurb: 'Contacts, deals, and notes', icon: '🤝', color: 'var(--cream)', tag: 'app', status: 'running' }
  ];

  function Apps(){
    var sig = createSignal(''); var q = sig[0], setQ = sig[1];
    var shown = function(){ var t = q().toLowerCase(); return APPS.filter(function(a){ return !t || a.name.toLowerCase().indexOf(t) >= 0 || a.blurb.toLowerCase().indexOf(t) >= 0; }); };
    return html`
      <div class="appswrap">
        <div class="appshdr">
          <div><h1 class="appstitle">Apps</h1><p class="appssub">Everything deployed on this nexus — open one in place.</p></div>
          <button class="appsnew" onClick=${function(){ WB.nav('/create'); }}>+ New app</button>
        </div>
        <input class="appssearch" placeholder="Search apps…" value=${q()} onInput=${function(e){ setQ(e.target.value); }} />
        <div class="appsgrid">
          <${For} each=${shown}>${function(a){
            return html`<button class="appcard" onClick=${function(){ WB.toast(a.name + ' — opening apps is coming (web-container view)'); }}>
              <span class="appicon" style=${'background:' + a.color + '22;'}>${a.icon}</span>
              <span class="appmeta"><span class="appname">${a.name}</span><span class="appblurb">${a.blurb}</span></span>
              <span class=${'appdot ' + a.status} title=${a.status}></span>
            </button>`;
          }}<//>
        </div>
        <${Show} when=${function(){ return shown().length === 0; }}><div class="appsempty">No apps match “${q()}”.</div><//>
      </div>`;
  }
  el.innerHTML = '';
  W.render(Apps, el);
}});
WB.scopedStyles('/apps', `
.appswrap { max-width: 980px; }
.appshdr { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
.appstitle { font: 700 26px var(--read); letter-spacing: -0.02em; color: var(--ink); margin: 0; }
.appssub { font: 500 13px var(--read); color: var(--dim); margin: 4px 0 0; }
.appsnew { flex: none; border: 1px solid var(--stroke); background: var(--card); color: var(--ink); border-radius: 9px; padding: 8px 13px; font: 600 13px var(--read); cursor: pointer; }
.appsnew:hover { border-color: var(--ink); }
.appssearch { width: 100%; box-sizing: border-box; border: 1px solid var(--line); background: var(--card); color: var(--ink); border-radius: 10px; padding: 10px 13px; font: 500 14px var(--read); margin-bottom: 16px; }
.appssearch:focus { outline: none; border-color: var(--stroke); }
.appsgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
.appcard { display: flex; align-items: center; gap: 12px; text-align: left; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 14px 16px; cursor: pointer; transition: border-color 0.12s, transform 0.08s; }
.appcard:hover { border-color: var(--stroke); transform: translateY(-1px); }
.appicon { width: 40px; height: 40px; border-radius: 11px; display: grid; place-items: center; font-size: 20px; flex: none; }
.appmeta { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.appname { font: 600 15px var(--read); color: var(--ink); }
.appblurb { font: 500 12.5px var(--read); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.appdot { width: 9px; height: 9px; border-radius: 50%; flex: none; background: var(--dim); }
.appdot.running { background: #34d399; }
.appdot.idle { background: var(--dim); opacity: 0.5; }
.appsempty { color: var(--dim); padding: 30px 4px; font: 500 14px var(--read); }
`);



WB.view('/usage', {
  title: 'Usage & billing',
  accent: 'var(--sage)',
  async render(el, ctx) {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

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
