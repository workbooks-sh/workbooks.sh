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
  // Load EVERYTHING the Studio needs in PARALLEL. This was a 7-deep serial await waterfall — each
  // esm.sh / wbchat import AND the /cloud/models call blocked the next, so first paint waited on their
  // SUM (the main reason Studio felt slow on cold load). One Promise.all → total ≈ the slowest single
  // fetch. esm.sh is URL-keyed, so the three solid-js entry points still share ONE core (the reason we
  // avoid ?bundle); firing the requests in parallel doesn't change that. `api` is hoisted (below).
  var vurl = WB.vurl || function (u) { return u; };
  var _p = await Promise.all([
    import('https://esm.sh/solid-js@1.9.5'),
    import('https://esm.sh/solid-js@1.9.5/web'),
    import('https://esm.sh/solid-js@1.9.5/html'),
    import(vurl('../wbchat/core.js')),
    import(vurl('../wbchat/components/index.js')),  // registers all parts + actions + composer add-ons
    import(vurl('../wbchat/demo.js')),              // dev-only seed (?cdemo=1) exercising every part type
    api('/cloud/models').catch(function(){ return { models: [] }; })  // overlaps the imports, no longer serial
  ]);
  var S = _p[0], W = _p[1], html = _p[2].default, WBC = _p[3], DEMO = _p[5], _mr = _p[6];
  var createSignal = S.createSignal, For = S.For, Show = S.Show;
  (function(){ if (!document.getElementById('wbchat-theme')){ var l = document.createElement('link'); l.id = 'wbchat-theme'; l.rel = 'stylesheet'; l.href = vurl('./wbchat/theme.css'); document.head.appendChild(l); } })();
  var CDEMO = new URLSearchParams(location.search).get('cdemo') === '1';

  var U = (WB.user && WB.user.email) || 'anon';
  function api(path, opts){ return fetch(path, Object.assign({ credentials: 'same-origin', headers: { 'content-type': 'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  var ICONS = {
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>',
    agent: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/></svg>',
    sessions: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v5h5"/><path d="M3.05 13A9 9 0 1 0 6 5.3L3 8"/><path d="M12 7v5l4 2"/></svg>'
  };
  // The models you can route the run through (the composer dropdown). Live from the nexus —
  // /cloud/models returns the provider's (OpenRouter) catalog, with a curated fallback. The selected
  // model id is passed to the agent run. (Agent selection moved out of the composer; this is models.)
  var MODELS = (_mr && _mr.models) || [];  // already fetched in the parallel batch above

  function Studio(){
    var ao = createSignal(false); var agentsOpen = ao[0], setAgentsOpen = ao[1];
    var so = createSignal(false); var sessOpen = so[0], setSessOpen = so[1];
    var ss = createSignal([]); var sessions = ss[0], setSessions = ss[1];
    var ag = createSignal([]); var agents = ag[0], setAgents = ag[1];
    var cs = createSignal(null); var curSession = cs[0], setCurSession = cs[1];
    var chat = null;

    // New task = a fresh free-form session (clears the composer). Sessions link to drafts later (Phase 2).
    function newTask(){ setCurSession(null); setAgentsOpen(false); setSessOpen(false); if (chat) { chat.clear(); chat.focus(); } }
    async function toggleAgents(){ setSessOpen(false); var open = !agentsOpen(); setAgentsOpen(open);
      if (open) { try { var d = await api('/cloud/agents'); setAgents((d && d.agents) || []); } catch (e) {} } }
    async function toggleSessions(){ setAgentsOpen(false); var open = !sessOpen(); setSessOpen(open);
      if (open) { try { var d = await api('/cloud/agent/sessions?u=' + encodeURIComponent(U)); setSessions((d && d.sessions) || []); } catch (e) {} } }
    async function openSession(id){ try { var d = await api('/cloud/agent/session?u=' + encodeURIComponent(U) + '&id=' + encodeURIComponent(id));
      if (chat && d && d.messages) chat.setMessages(d.messages); setCurSession(id); setSessOpen(false); } catch (e) {} }
    function fmtWhen(t){ if (!t) return ''; try { return new Date(t * 1000).toLocaleDateString(); } catch (e) { return ''; } }

    function mountChat(node){
      chat = WBC.createChat(node, {
        splash: true,
        placeholder: 'What do you want to build?',
        suggestions: ['Scaffold a new app', 'Draft a data model', 'Wire up an integration'],
        models: MODELS,
        send: function(text, ctx){
          return api('/cloud/agent/chat', { method: 'POST', body: JSON.stringify({ u: U, id: curSession(), message: text, model: ctx && ctx.model }) })
            .then(function(d){ if (d && d.id) setCurSession(d.id); return (d && d.reply) || '(no reply)'; });
        }
      });
      if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());
    }

    return html`
      <div class="studio">
        <nav class="studio-topnav">
          <button class="studio-tab" onClick=${newTask}><span class="ti" innerHTML=${ICONS.plus}></span><span>New task</span></button>
          <button class=${function(){ return 'studio-tab' + (agentsOpen() ? ' on' : ''); }} onClick=${toggleAgents}><span class="ti" innerHTML=${ICONS.agent}></span><span>Agents</span></button>
          <button class=${function(){ return 'studio-tab' + (sessOpen() ? ' on' : ''); }} onClick=${toggleSessions}><span class="ti" innerHTML=${ICONS.sessions}></span><span>Sessions</span></button>
        </nav>
        <section class="studio-chat" ref=${mountChat}></section>
        <${Show} when=${agentsOpen}>
          <aside class="studio-side">
            <div class="studio-side-hd">Agents</div>
            <div class="studio-side-list">
              <${For} each=${agents}>${function(a){ return html`<div class="studio-agent"><span class="studio-agent-ic" innerHTML=${ICONS.agent}></span><span class="studio-agent-nm">${a.name}</span></div>`; }}<//>
              <${Show} when=${function(){ return agents().length === 0; }}><div class="studio-side-empty">No agents defined yet.</div><//>
            </div>
          </aside>
        <//>
        <${Show} when=${sessOpen}>
          <aside class="studio-side">
            <div class="studio-side-hd">Sessions</div>
            <div class="studio-side-list">
              <${For} each=${sessions}>${function(s){ return html`<button data-ctx="session" data-session=${s.id} class=${function(){ return 'studio-sess' + (curSession() === s.id ? ' on' : ''); }} onClick=${function(){ openSession(s.id); }}>
                <span class="studio-sess-nm">${s.title || 'Untitled'}</span>
                <span class="studio-sess-meta"><span class="studio-sess-ctx">free-form</span><span class="studio-sess-when">${fmtWhen(s.updated)}</span></span>
              </button>`; }}<//>
              <${Show} when=${function(){ return sessions().length === 0; }}><div class="studio-side-empty">No sessions yet — start one with New task.</div><//>
            </div>
          </aside>
        <//>
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
/* Studio = horizontal top nav (New task | Agents | Sessions) over the chat. Overrides the global
   .studio/.studio-chat (which were absolute-inset) so the nav stacks above a flex chat. */
.studio { display: flex; flex-direction: column; }
/* Centered FLOATING toolbar over the chat (not a full-width bar). */
.studio-topnav { position: absolute; top: 16px; left: 50%; transform: translateX(-50%); z-index: 15;
  display: flex; align-items: center; gap: 10px; padding: 6px 8px; background: var(--card);
  border: 1px solid var(--line); border-radius: 14px; box-shadow: 0 6px 22px rgba(0,0,0,.16); }
.studio-tab { display: inline-flex; align-items: center; gap: 7px; border: none; background: none; color: var(--dim); cursor: pointer; border-radius: 10px; padding: 7px 14px; font: 600 13px var(--read); }
.studio-tab:hover { background: var(--line); color: var(--ink); }
.studio-tab.on { background: var(--line); color: var(--ink); }
.studio-tab .ti { display: grid; place-items: center; }
.studio-tab .ti svg { width: 16px; height: 16px; }
.studio-chat { position: relative; inset: auto; flex: 1; min-height: 0; }
/* Agents/Sessions side panel — slides over from the right. */
.studio-side { position: absolute; right: 0; top: 0; bottom: 0; width: 300px; z-index: 20; box-sizing: border-box;
  display: flex; flex-direction: column; background: var(--card); border-left: 1px solid var(--line); box-shadow: -6px 0 22px rgba(0,0,0,.16); }
.studio-side-hd { padding: 12px 16px 8px; font: 700 11px var(--read); letter-spacing: .08em; text-transform: uppercase; color: var(--dim); }
.studio-side-list { flex: 1; min-height: 0; overflow-y: auto; padding: 0 8px 12px; display: flex; flex-direction: column; gap: 1px; }
.studio-side-empty { color: var(--dim); font: 500 12.5px var(--read); padding: 8px 10px; }
.studio-agent { display: flex; align-items: center; gap: 9px; padding: 9px 10px; border-radius: 8px; color: var(--ink); font: 500 13px var(--read); }
.studio-agent:hover { background: var(--line); }
.studio-agent-ic { display: grid; place-items: center; color: var(--dim); }
.studio-agent-ic svg { width: 16px; height: 16px; }
.studio-sess { display: flex; flex-direction: column; gap: 4px; text-align: left; border: none; background: none; color: var(--ink); cursor: pointer; border-radius: 8px; padding: 9px 10px; }
.studio-sess:hover, .studio-sess.on { background: var(--line); }
.studio-sess-nm { font: 500 13px var(--read); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.studio-sess-meta { display: flex; align-items: center; gap: 8px; }
.studio-sess-ctx { font: 600 9px var(--read); letter-spacing: .04em; text-transform: uppercase; color: var(--dim); background: var(--paper); border: 1px solid var(--line); border-radius: 5px; padding: 1px 5px; }
.studio-sess-when { font: 500 11px var(--mono); color: var(--dim); }
`);


WB.view('/usage', {
  title: 'Usage & billing',
  accent: 'var(--sage)',
  async render(el, ctx) {
    const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    // Paint-first (the load-time rule): show the header + a skeleton immediately, then fill after fetch.
    el.innerHTML = `<section><div class="sechead"><div><h2>Usage &amp; billing</h2><p class="dim">Loading…</p></div></div>` +
      `<div class="card faint" style="text-align:center;color:var(--dim)">Loading usage…</div></section>`;

    // Stale-while-revalidate: paint cached usage instantly, refresh in the background.
    await WB.swr('usage', () => WB.api.nexusUsage(), (u) => {
    if (!u) return;
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

    var inv = el.querySelector('[data-invoice]'); if (inv) inv.addEventListener('click', () => WB.toast('Invoice downloading…'));
    });
  }
});
