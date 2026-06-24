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
  // The Studio is now JUST the full-bleed chat — sessions + spaces live in the left SIDEBAR (app.js),
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
  // no toolkit (Workhorse, Autopilot) are always available.
  // Roster comes from /cloud/agents; fall back to the canonical client catalog so the selector always
  // renders (e.g. before the nexus has recompiled the route, or on a cold/odd response).
  var AG = (_p[4] && _p[4].agents && _p[4].agents.length) ? _p[4].agents : (WB.AGENT_CATALOG || []);
  var TK = (_p[5] && _p[5].toolkits) || [];
  var tkOn = {}; TK.forEach(function(t){ if (t && t.kind === 'standalone') tkOn[t.id] = t.enabled !== false; });
  var AGENTS = AG.filter(function(a){ return !a.toolkit || tkOn[a.toolkit] !== false; });

  // Session/workspace state (the sidebar sets WB._pending* before routing here). Agent + workspace are
  // pinned for a session's life — captured on the first turn, sent with every turn so the server stores
  // them. Workspaces are the declared subtrees (WB.ws.list); '' / "General" = system-level (no workspace).
  var curSession = WB._pendingSession || null;
  var curWorkspace = WB._pendingWorkspace || null;
  WB._pendingSession = null; WB._pendingWorkspace = null;
  var WORKSPACES = [{ id: '', name: 'General' }].concat(((WB.ws && WB.ws.list) || []).map(function(w){ return { id: w.id, name: w.name }; }));

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
    // Capabilities the composer can plug into the driver agent (toolkits-as-capabilities). Gated by each
    // agent's admission: Workhorse (:all) → everything; Autopilot/Autopoet (:none) → disabled. Admission comes
    // from the /cloud/agents feed (a.capabilities) with a safe fallback.
    capabilityCatalog: TK,
    capabilityAdmission: function(name){
      var a = AGENTS.filter(function(x){ return agentName(x) === name; })[0];
      if (a && a.capabilities != null) return a.capabilities;   // "all" | "none" | [ids]
      return name === 'autopilot' ? 'none' : 'all';
    },
    // The workspace this session runs in (composer selector, left of attachments). '' = General. Pinned
    // once the session has messages (you don't move a session out of its workspace).
    workspaces: WORKSPACES,
    workspace: (curWorkspace || ''),
    onWorkspace: function(id){ curWorkspace = id || null; },
    // "Add context" (the composer paperclip) opens the searchable multi-select picker (files / workspaces,
    // plus drop-to-attach). Chosen items become context chips and ride along with the turn.
    onAttach: function(){ return (WB.contextPicker ? WB.contextPicker() : Promise.resolve([])); },
    send: function(text, ctx){
      // Attachment gating: if the chosen brain can't see images, drop image attachments (it can't read
      // them) and tell the user, rather than silently shipping bytes the model ignores.
      var curModel = MODELS.filter(function(m){ return (m.id || m) === (ctx && ctx.model); })[0];
      var canSee = !curModel || !curModel.modal_in || curModel.modal_in.indexOf('image') >= 0;
      var isImage = function(f){ return (f.type === 'image') || /\.(png|jpe?g|gif|webp|bmp|svg|heic)$/i.test(f.name || ''); };
      var files = (ctx && ctx.files) || [];
      if (!canSee && files.some(isImage)) {
        files = files.filter(function(f){ return !isImage(f); });
        WB.toast((curModel.label || 'This model') + " can't see images — image attachments were skipped", 'bad');
      }
      var context = files.map(function(f){ return { name: f.name, type: f.type || 'file', ref: f.ref || f.path || f.id || f.name }; });
      return api('/cloud/agent/chat', { method: 'POST', body: JSON.stringify({
        u: U, id: curSession, message: text,
        model: ctx && ctx.model, agent: agentName(ctx && ctx.agent), workspace: curWorkspace, context: context,
        capabilities: (ctx && ctx.capabilities) || []
      }) }).then(function(d){
        if (d && d.id) { curSession = d.id; if (WB._paintStudio) { WB.cache.set('agent-sessions', null); WB._paintStudio(); } }
        return (d && d.reply) || '(no reply)';
      });
    }
  });
  if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());

  // Open an existing session — load its messages and pin its saved agent + workspace (the composer locks
  // both once messages are present, so they stay fixed).
  async function openSession(id){
    try {
      var d = await api('/cloud/agent/session?u=' + encodeURIComponent(U) + '&id=' + encodeURIComponent(id));
      if (!d || d.error) return;
      curSession = id; curWorkspace = d.workspace || null;
      if (d.agent && chat.setAgent) chat.setAgent(d.agent);
      if (chat.setWorkspace) chat.setWorkspace(d.workspace || '');
      chat.setMessages(d.messages || []);
      chat.focus();
    } catch (e) {}
  }
  // Hooks the sidebar calls when we're ALREADY on /studio (a re-nav wouldn't re-render the view).
  WB._studioOpen = function(id){ openSession(id); };
  WB._studioNew = function(workspace){ curSession = null; curWorkspace = workspace || null; if (chat.setWorkspace) chat.setWorkspace(workspace || ''); chat.clear(); chat.focus(); };

  if (curSession) openSession(curSession);
}});
// "Create" is now the + (new chat) inside Studio; keep the old route as a redirect.
WB.view('/create', { title: 'Studio', render(el){ WB.nav('/studio'); } });

// ── New agent / New workflow — Studio creation surfaces (reached from the sidebar "New ▾" menu). ──
// Both live in the Studio rail section (sectionFor maps /studio/* → studio), so the sidebar stays put,
// and both are full-bleed with their OWN backdrop:
//   • New agent    → a minimal creation FORM on a subtle graph-paper grid + vignetted mesh wash.
//   • New workflow → a full-bleed node-graph CANVAS on a dot grid (a Svelte-Flow-style editor), with a
//     composer docked at the bottom. NOTE: the cloud app is build-free vanilla JS, so this is a
//     hand-rolled look-alike (draggable nodes + bezier edges), not the actual @xyflow/svelte package.
// Content on both is illustrative/stubbed — the Create + Generate actions just toast for now.
var AGICO = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M8 15.4V8.6C8 8.26863 8.26863 8 8.6 8H15.4C15.7314 8 16 8.26863 16 8.6V15.4C16 15.7314 15.7314 16 15.4 16H8.6C8.26863 16 8 15.7314 8 15.4Z"/><path d="M20 4.6V19.4C20 19.7314 19.7314 20 19.4 20H4.6C4.26863 20 4 19.7314 4 19.4V4.6C4 4.26863 4.26863 4 4.6 4H19.4C19.7314 4 20 4.26863 20 4.6Z"/><path d="M17 4V2M12 4V2M7 4V2M7 20V22M12 20V22M17 20V22M20 17H22M20 12H22M20 7H22M4 17H2M4 12H2M4 7H2"/></svg>';

WB.scopedStyles('/studio/agent', `
  .agbg { position:absolute; inset:0; z-index:0; pointer-events:none; overflow:hidden;
    background-image:
      linear-gradient(color-mix(in srgb, var(--ink) 6%, transparent) 1px, transparent 1px),
      linear-gradient(90deg, color-mix(in srgb, var(--ink) 6%, transparent) 1px, transparent 1px);
    background-size: 26px 26px; }
  .agbg::before { content:""; position:absolute; inset:-20%; filter:blur(90px) saturate(1.05); opacity:.5;
    background:
      radial-gradient(38% 44% at 28% 24%, color-mix(in srgb, var(--violet) 42%, transparent), transparent 72%),
      radial-gradient(40% 46% at 74% 72%, color-mix(in srgb, var(--sky) 34%, transparent), transparent 74%); }
  .agbg::after { content:""; position:absolute; inset:0;
    background: radial-gradient(120% 120% at 50% 42%, transparent 52%, color-mix(in srgb, var(--paper) 78%, transparent) 100%); }
  [data-theme="dark"] .agbg::before { opacity:.32; }

  .agscroll { position:absolute; inset:0; overflow-y:auto; z-index:1; }
  .agform { max-width:560px; margin:0 auto; padding:40px 24px 64px; }
  .aghead { display:flex; align-items:center; gap:13px; margin-bottom:24px; }
  .aghead .agic { width:48px; height:48px; flex:none; border-radius:14px; display:grid; place-items:center;
    color:var(--ink); background:color-mix(in srgb, var(--violet) 30%, transparent); }
  .aghead h2 { font-family:var(--display); font-weight:600; font-size:21px; margin:0; }
  .aghead p { color:var(--dim); font:400 13px var(--read); margin:2px 0 0; }
  .agfield { margin-bottom:18px; }
  .agfield > label { display:block; font:600 11px var(--mono); letter-spacing:.05em; text-transform:uppercase;
    color:var(--dim); margin-bottom:7px; }
  .agin, .agsel, .agta { width:100%; box-sizing:border-box; border:1px solid var(--line); border-radius:11px;
    background:var(--card); color:var(--ink); font:500 14px var(--read); padding:11px 13px; outline:none; }
  .agin:focus, .agsel:focus, .agta:focus { border-color:var(--stroke); box-shadow:0 0 0 3px color-mix(in srgb, var(--violet) 22%, transparent); }
  .agta { resize:vertical; min-height:96px; line-height:1.5; }
  .agcaps { display:flex; flex-wrap:wrap; gap:8px; }
  .agcap { font:500 13px var(--read); color:var(--ink); border:1px solid var(--line); background:var(--card);
    border-radius:999px; padding:7px 13px; cursor:pointer; user-select:none; }
  .agcap.on { border-color:transparent; background:color-mix(in srgb, var(--violet) 24%, transparent); }
  .agfoot { display:flex; justify-content:flex-end; gap:10px; margin-top:28px; }
`);
WB.view('/studio/agent', { title: 'New agent', accent: 'var(--violet)', fullbleed: true, render(el){
  var CAPS = ['Files', 'Web search', 'Code', 'Database', 'Email'];
  el.innerHTML =
    '<div class="agbg"></div>' +
    '<div class="agscroll"><form class="agform" autocomplete="off">' +
      '<div class="aghead"><span class="agic">' + AGICO + '</span>' +
        '<div><h2>New agent</h2><p>A purpose-built brain you can launch from the Studio composer.</p></div></div>' +
      '<div class="agfield"><label>Name</label><input class="agin" name="name" placeholder="e.g. Release notes writer"></div>' +
      '<div class="agfield"><label>Description</label><input class="agin" name="desc" placeholder="One line on what it does"></div>' +
      '<div class="agfield"><label>Brain</label><select class="agsel" name="model">' +
        '<option>Claude Opus 4.8</option><option>Claude Sonnet 4.6</option><option>Claude Haiku 4.5</option></select></div>' +
      '<div class="agfield"><label>Instructions</label><textarea class="agta" name="prompt" placeholder="Describe how the agent should behave, its tone, and any rules…"></textarea></div>' +
      '<div class="agfield"><label>Capabilities</label><div class="agcaps">' +
        CAPS.map(function(c){ return '<button type="button" class="agcap" data-cap>' + c + '</button>'; }).join('') +
      '</div></div>' +
      '<div class="agfoot"><button type="button" class="btn sm" data-cancel>Cancel</button>' +
        '<button type="submit" class="btn sm primary">Create agent</button></div>' +
    '</form></div>';
  el.querySelectorAll('[data-cap]').forEach(function(b){ b.addEventListener('click', function(){ b.classList.toggle('on'); }); });
  el.querySelector('[data-cancel]').addEventListener('click', function(){ WB.nav('/studio'); });
  el.querySelector('.agform').addEventListener('submit', function(e){ e.preventDefault(); WB.toast('Agent creation is coming soon'); });
}});

WB.scopedStyles('/studio/workflow', `
  .wfwrap { position:absolute; inset:0; overflow:hidden; }
  .wfcanvas { position:absolute; inset:0;
    background-image: radial-gradient(color-mix(in srgb, var(--ink) 14%, transparent) 1.4px, transparent 1.4px);
    background-size: 22px 22px; background-position:-1px -1px; }
  .wfedges { position:absolute; inset:0; width:100%; height:100%; pointer-events:none; overflow:visible; }
  .wfedges path { fill:none; stroke:color-mix(in srgb, var(--ink) 26%, transparent); stroke-width:2; }
  .wfnode { position:absolute; width:178px; box-sizing:border-box; background:var(--card); border:1px solid var(--line);
    border-radius:13px; padding:11px 13px; cursor:grab; user-select:none; box-shadow:0 4px 16px rgba(0,0,0,.08);
    border-left:3px solid var(--nc, var(--sky)); }
  .wfnode:active { cursor:grabbing; }
  .wfnode .wfkind { display:flex; align-items:center; gap:7px; font:600 9.5px var(--mono); letter-spacing:.07em;
    text-transform:uppercase; color:var(--dim); margin-bottom:5px; }
  .wfnode .wfkind i { width:9px; height:9px; border-radius:3px; background:var(--nc, var(--sky)); display:inline-block; }
  .wfnode .wflbl { font:600 14px var(--read); color:var(--ink); }
  .wfcomposer { position:absolute; left:0; right:0; bottom:0; padding:14px 16px 18px; z-index:5;
    background:linear-gradient(to top, var(--paper) 40%, transparent); }
  .wfcomp-inner { max-width:680px; margin:0 auto; display:flex; align-items:flex-end; gap:8px;
    background:var(--card); border:1px solid var(--line); border-radius:16px; padding:10px 10px 10px 16px;
    box-shadow:0 6px 28px rgba(0,0,0,.12); }
  .wfcomp-inner:focus-within { border-color:var(--stroke); box-shadow:0 0 0 3px color-mix(in srgb, var(--sky) 24%, transparent); }
  .wfta { flex:1; border:none; background:none; outline:none; resize:none; color:var(--ink); font:500 14.5px var(--read);
    line-height:1.5; min-height:24px; max-height:140px; padding:4px 0; }
  .wfta::placeholder { color:var(--dim); }
  .wfsend { flex:none; width:34px; height:34px; border:none; border-radius:11px; cursor:pointer; display:grid; place-items:center;
    background:var(--ink); color:var(--paper); }
  .wfsend svg { width:17px; height:17px; }
`);
WB.view('/studio/workflow', { title: 'New workflow', accent: 'var(--sky)', fullbleed: true, render(el){
  // Illustrative graph: a trigger → a step that fans out to two parallel steps → a notify. Nodes are
  // draggable; edges are bezier paths recomputed live. (Hand-rolled — see the note above.)
  var NODES = [
    { id:'trigger', x:60,  y:150, kind:'Trigger',  label:'On schedule', c:'--mint' },
    { id:'fetch',   x:320, y:150, kind:'Step',     label:'Fetch data',  c:'--sky' },
    { id:'sum',     x:580, y:60,  kind:'Parallel', label:'Summarize',   c:'--violet' },
    { id:'cls',     x:580, y:250, kind:'Parallel', label:'Classify',    c:'--violet' },
    { id:'notify',  x:840, y:150, kind:'Step',     label:'Notify',      c:'--peach' }
  ];
  var EDGES = [['trigger','fetch'],['fetch','sum'],['fetch','cls'],['sum','notify'],['cls','notify']];
  var NW = 178, NH = 56;

  el.innerHTML =
    '<div class="wfwrap"><div class="wfcanvas" id="wfCanvas">' +
      '<svg class="wfedges" id="wfEdges"></svg>' +
      NODES.map(function(n){
        return '<div class="wfnode" data-node="' + n.id + '" style="--nc:var(' + n.c + ');left:' + n.x + 'px;top:' + n.y + 'px">' +
          '<div class="wfkind"><i></i>' + n.kind + '</div><div class="wflbl">' + n.label + '</div></div>';
      }).join('') +
    '</div>' +
    '<div class="wfcomposer"><div class="wfcomp-inner">' +
      '<textarea class="wfta" rows="1" placeholder="Describe a workflow to generate…"></textarea>' +
      '<button class="wfsend" aria-label="Generate"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M12 5L6 11M12 5L18 11"/></svg></button>' +
    '</div></div></div>';

  var canvas = el.querySelector('#wfCanvas'), svg = el.querySelector('#wfEdges');
  var byId = {}; NODES.forEach(function(n){ byId[n.id] = n; });
  function drawEdges(){
    svg.innerHTML = EDGES.map(function(e){
      var a = byId[e[0]], b = byId[e[1]];
      var sx = a.x + NW, sy = a.y + NH / 2, tx = b.x, ty = b.y + NH / 2;
      var dx = Math.max(40, (tx - sx) / 2);
      return '<path d="M ' + sx + ' ' + sy + ' C ' + (sx + dx) + ' ' + sy + ', ' + (tx - dx) + ' ' + ty + ', ' + tx + ' ' + ty + '"/>';
    }).join('');
  }
  function placeNode(n){ var d = canvas.querySelector('[data-node="' + n.id + '"]'); d.style.left = n.x + 'px'; d.style.top = n.y + 'px'; }
  drawEdges();

  // Drag — pointer-based, window-scoped listeners only while a node is held.
  var drag = null;
  canvas.addEventListener('pointerdown', function(e){
    var d = e.target.closest && e.target.closest('[data-node]'); if (!d) return;
    var n = byId[d.getAttribute('data-node')];
    drag = { n: n, ox: e.clientX - n.x, oy: e.clientY - n.y };
    d.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener('pointermove', function(e){
    if (!drag) return;
    drag.n.x = Math.max(0, e.clientX - drag.ox); drag.n.y = Math.max(0, e.clientY - drag.oy);
    placeNode(drag.n); drawEdges();
  });
  canvas.addEventListener('pointerup', function(){ drag = null; });

  var ta = el.querySelector('.wfta');
  ta.addEventListener('input', function(){ ta.style.height = 'auto'; ta.style.height = Math.min(140, ta.scrollHeight) + 'px'; });
  el.querySelector('.wfsend').addEventListener('click', function(){ WB.toast('Workflow generation is coming soon'); });
}});
// The studio-shell CSS (.studio / .studio-rail / .studio-railbtn) is GLOBAL in app.css so it's shared
// by every surface in the shell (Studio chat + Activity feed), keeping the floating rail locked in.
// Studio is now just the full-bleed chat — sessions/spaces + the agent picker live elsewhere (the
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
