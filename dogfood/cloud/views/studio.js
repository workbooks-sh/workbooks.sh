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
  // The Studio is now JUST the full-bleed chat — sessions + projects live in the left SIDEBAR (app.js),
  // and the agent is chosen from the composer's agent selector (only at the start of a new session).
  // The old top nav (New task | Agents | Sessions) is gone — the sidebar already owns all of it. No
  // solid-js needed anymore (no reactive nav/panels), so we drop those imports too.
  var vurl = WB.vurl || function (u) { return u; };
  function api(path, opts){ return fetch(path, Object.assign({ credentials: 'same-origin', headers: { 'content-type': 'application/json' } }, opts || {})).then(function(r){ return r.json(); }); }
  var _p = await Promise.all([
    // NOTE: import the wbchat modules WITHOUT vurl. The component files statically import '../core.js'
    // (bare), so if Studio loaded core via a ?v= URL it'd get a SEPARATE module instance — and the
    // composer add-ons (model + agent selectors) would register into an instance Studio never uses, so
    // none would appear. Bare keeps ONE shared instance. Assets are served must-revalidate, so no stale
    // cache. (theme.css below can stay versioned — it's a stylesheet, not a module graph.)
    import('../wbchat/core.js'),
    import('../wbchat/components/index.js'),  // registers all parts + actions + composer add-ons
    import('../wbchat/demo.js'),              // dev-only seed (?cdemo=1) exercising every part type
    api('/cloud/inference/models').catch(function(){ return { models: [] }; }),
    api('/cloud/agents').catch(function(){ return { agents: [] }; }),
    api('/cloud/toolkits').catch(function(){ return { toolkits: [] }; }),
    api('/cloud/models').catch(function(){ return { models: [] }; })
  ]);
  var WBC = _p[0], DEMO = _p[2];
  // Prefer the Workbooks Inference catalog (provider/model ids over our gateway); fall back to the raw
  // provider catalog (/cloud/models) if inference isn't available yet.
  var MODELS = (_p[3] && _p[3].models && _p[3].models.length) ? _p[3].models : ((_p[6] && _p[6].models) || []);
  (function(){ if (!document.getElementById('wbchat-theme')){ var l = document.createElement('link'); l.id = 'wbchat-theme'; l.rel = 'stylesheet'; l.href = vurl('./wbchat/theme.css'); document.head.appendChild(l); } })();
  var CDEMO = new URLSearchParams(location.search).get('cdemo') === '1';
  var U = (WB.user && WB.user.email) || 'anon';

  // The Studio agent roster — our toolkit-bound catalog (GET /cloud/agents), FILTERED to those whose
  // toolkit is enabled (disable a toolkit on the Toolkits page and its agent disappears here). Agents with
  // no toolkit (Waldo, Autopilot) are always available.
  // Roster comes from /cloud/agents; fall back to the canonical client catalog so the selector always
  // renders (e.g. before the nexus has recompiled the route, or on a cold/odd response).
  var AG = (_p[4] && _p[4].agents && _p[4].agents.length) ? _p[4].agents : (WB.AGENT_CATALOG || []);
  var TK = (_p[5] && _p[5].toolkits) || [];
  var tkOn = {}; TK.forEach(function(t){ if (t && t.kind === 'standalone') tkOn[t.id] = t.enabled !== false; });
  var AGENTS = AG.filter(function(a){ return !a.toolkit || tkOn[a.toolkit] !== false; });

  // Session/project state (the sidebar sets WB._pending* before routing here). Agent + project are pinned
  // for a session's life — captured on the first turn, sent with every turn so the server stores them.
  var curSession = WB._pendingSession || null;
  var curProject = WB._pendingProject || null;
  WB._pendingSession = null; WB._pendingProject = null;

  function agentName(a){ return a && (a.name || a) || null; }

  var node = document.createElement('section');
  node.className = 'studio-chat';
  el.innerHTML = ''; el.appendChild(node);

  var chat = WBC.createChat(node, {
    splash: true,
    placeholder: 'What do you want to build?',
    suggestions: ['Scaffold a new app', 'Draft a data model', 'Wire up an integration'],
    models: MODELS,
    agents: AGENTS,
    send: function(text, ctx){
      return api('/cloud/agent/chat', { method: 'POST', body: JSON.stringify({
        u: U, id: curSession, message: text,
        model: ctx && ctx.model, agent: agentName(ctx && ctx.agent), project: curProject
      }) }).then(function(d){
        if (d && d.id) { curSession = d.id; if (WB._paintStudio) { WB.cache.set('agent-sessions', null); WB._paintStudio(); } }
        return (d && d.reply) || '(no reply)';
      });
    }
  });
  if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());

  // Open an existing session — load its messages and pin its saved agent + project (the composer locks
  // the agent once messages are present, so it stays fixed).
  async function openSession(id){
    try {
      var d = await api('/cloud/agent/session?u=' + encodeURIComponent(U) + '&id=' + encodeURIComponent(id));
      if (!d || d.error) return;
      curSession = id; curProject = d.project || null;
      if (d.agent && chat.setAgent) chat.setAgent(d.agent);
      chat.setMessages(d.messages || []);
      chat.focus();
    } catch (e) {}
  }
  // Hooks the sidebar calls when we're ALREADY on /studio (a re-nav wouldn't re-render the view).
  WB._studioOpen = function(id){ openSession(id); };
  WB._studioNew = function(project){ curSession = null; curProject = project || null; chat.clear(); chat.focus(); };

  if (curSession) openSession(curSession);
}});
// "Create" is now the + (new chat) inside Studio; keep the old route as a redirect.
WB.view('/create', { title: 'Studio', render(el){ WB.nav('/studio'); } });
// The studio-shell CSS (.studio / .studio-rail / .studio-railbtn) is GLOBAL in app.css so it's shared
// by every surface in the shell (Studio chat + Activity feed), keeping the floating rail locked in.
// Studio is now just the full-bleed chat — sessions/projects + the agent picker live elsewhere (the
// sidebar + the composer). `.studio-chat` (absolute-inset flex holding the .wb-chat) is GLOBAL in
// app.css, so no per-view styles are needed here anymore.


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
