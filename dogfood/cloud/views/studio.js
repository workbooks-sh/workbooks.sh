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
  var curAgent = WB._pendingAgent || null;   // set when launched from an agent card
  WB._pendingSession = null; WB._pendingWorkspace = null; WB._pendingAgent = null;
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
        // Refused at the money boundary — pop the credit/policy modal (admin vs member copy inside it).
        if (d && d.blocked && WB.handleInferenceBlock) WB.handleInferenceBlock(d.reason);
        if (d && d.id) {
          curSession = d.id;
          // Surface this conversation as an open-session tab in the sidebar (closable; close ≠ delete).
          var ag = agentName(ctx && ctx.agent) || curAgent;
          if (WB.tabs) WB.tabs.open('studio', { id: d.id, label: (d.title || text || 'Session').slice(0, 40), kind: 'agent',
            seed: ag ? ('agent-' + ag) : ('s-' + d.id), color: WB.agentColor ? WB.agentColor('agent:' + (ag || d.id)) : '--mint' });
          if (WB._paintStudio) { WB.cache.set('agent-sessions', null); WB._paintStudio(); }
        }
        return (d && d.reply) || '(no reply)';
      });
    }
  });
  if (CDEMO && DEMO.demoMessages) chat.setMessages(DEMO.demoMessages());
  // Launched from an agent card → preselect that agent for the fresh chat.
  if (curAgent && chat.setAgent) chat.setAgent(curAgent);

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
  WB._studioNew = function(workspace, agent){ curSession = null; curWorkspace = workspace || null; curAgent = agent || null;
    if (chat.setWorkspace) chat.setWorkspace(workspace || ''); chat.clear();
    if (agent && chat.setAgent) chat.setAgent(agent); chat.focus(); };

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
  .aghead { display:flex; align-items:center; gap:14px; margin-bottom:24px; }
  .agswatches { display:flex; gap:8px; flex-wrap:wrap; }
  .agsw { width:26px; height:26px; border-radius:8px; border:2px solid transparent; cursor:pointer; padding:0; }
  .agsw.on { border-color:var(--ink); box-shadow:0 0 0 2px var(--card) inset; }
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
      '<div class="aghead"><span id="agAvatar"></span>' +
        '<div><h2>New agent</h2><p>A purpose-built brain you can launch from the Studio composer.</p></div></div>' +
      '<div class="agfield"><label>Name</label><input class="agin" name="name" placeholder="e.g. Release notes writer"></div>' +
      '<div class="agfield"><label>Avatar color</label><div class="agswatches" id="agSwatches"></div></div>' +
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

  // Avatar setup — a live DiceBear preview seeded by the name, color-coded by a swatch (the same
  // WB.avatar the grid + tabs use, so what you pick is exactly how the agent will appear everywhere).
  var COLORS = WB.AGCOLORS || ['--violet','--sky','--mint','--peach','--cream','--sage','--blue'];
  var color = COLORS[0], nameEl = el.querySelector('input[name="name"]'), avEl = el.querySelector('#agAvatar');
  function seed(){ return (nameEl.value.trim() || 'new-agent'); }
  function paintAv(){ if (WB.avatar) avEl.innerHTML = WB.avatar(seed(), color, 52); }
  el.querySelector('#agSwatches').innerHTML = COLORS.map(function(c){
    return '<button type="button" class="agsw' + (c === color ? ' on' : '') + '" data-color="' + c + '" style="background:var(' + c + ')" title="' + c.replace('--','') + '"></button>';
  }).join('');
  el.querySelectorAll('[data-color]').forEach(function(b){ b.addEventListener('click', function(){
    color = b.getAttribute('data-color');
    el.querySelectorAll('.agsw').forEach(function(x){ x.classList.toggle('on', x === b); });
    paintAv();
  }); });
  nameEl.addEventListener('input', paintAv);
  paintAv();
}});

WB.scopedStyles('/studio/workflow', `
  .wfwrap { position:absolute; inset:0; overflow:hidden; }
  .wfcanvas { position:absolute; inset:0; touch-action:none; cursor:grab;
    background-image: radial-gradient(color-mix(in srgb, var(--ink) 14%, transparent) 1.4px, transparent 1.4px);
    background-size: 22px 22px; }
  .wfcanvas.panning { cursor:grabbing; }
  /* The transformed viewport — pan/zoom apply here; nodes + edges share its coordinate space. */
  .wfview { position:absolute; left:0; top:0; transform-origin:0 0; }
  .wfedges { position:absolute; left:0; top:0; overflow:visible; pointer-events:none; }
  .wfedges path { fill:none; stroke:color-mix(in srgb, var(--ink) 28%, transparent); stroke-width:2; }
  .wfedges path.tmp { stroke:var(--sky); stroke-dasharray:5 4; }
  .wfnode { position:absolute; width:178px; box-sizing:border-box; background:var(--card); border:1px solid var(--line);
    border-radius:13px; padding:11px 13px; cursor:grab; user-select:none; box-shadow:0 4px 16px rgba(0,0,0,.08);
    border-left:3px solid var(--nc, var(--sky)); }
  .wfnode:active { cursor:grabbing; }
  .wfnode.sel { border-color:var(--nc, var(--sky)); box-shadow:0 0 0 2px color-mix(in srgb, var(--nc, var(--sky)) 45%, transparent), 0 4px 16px rgba(0,0,0,.10); }
  .wfnode .wfkind { display:flex; align-items:center; gap:7px; font:600 9.5px var(--mono); letter-spacing:.07em;
    text-transform:uppercase; color:var(--dim); margin-bottom:5px; }
  .wfnode .wfkind i { width:9px; height:9px; border-radius:3px; background:var(--nc, var(--sky)); display:inline-block; }
  .wfnode .wflbl { font:600 14px var(--read); color:var(--ink); }
  /* Connection ports — a dot on each side; drag from the output (right) to another node to link. */
  .wfport { position:absolute; top:50%; width:12px; height:12px; margin-top:-6px; border-radius:50%;
    background:var(--card); border:2px solid var(--nc, var(--sky)); cursor:crosshair; }
  .wfport.in { left:-7px; } .wfport.out { right:-7px; }
  .wfport:hover { background:var(--nc, var(--sky)); }
  /* Delete affordance — appears on hover. */
  .wfdel { position:absolute; top:-9px; right:-9px; width:20px; height:20px; border-radius:50%; border:1px solid var(--line);
    background:var(--card); color:var(--dim); cursor:pointer; display:none; place-items:center; font:600 13px var(--read); line-height:1; }
  .wfnode:hover .wfdel { display:grid; } .wfdel:hover { color:var(--ink); border-color:var(--stroke); }
  /* Top floating toolbar — icon buttons for node/canvas actions (add step, add trigger, group, …). */
  .wftoolbar { position:absolute; left:50%; top:14px; transform:translateX(-50%); z-index:6; display:flex; align-items:center; gap:2px;
    background:var(--card); border:1px solid var(--line); border-radius:12px; padding:5px; box-shadow:0 4px 18px rgba(0,0,0,.10); }
  .wftbtn { width:34px; height:34px; border:none; background:none; color:var(--ink); border-radius:8px; cursor:pointer; display:grid; place-items:center; }
  .wftbtn:hover { background:color-mix(in srgb, var(--ink) 7%, transparent); }
  .wftbtn:disabled { color:var(--dim); cursor:default; background:none; }
  .wftbtn svg { width:18px; height:18px; }
  .wftsep { width:1px; align-self:stretch; margin:3px 4px; background:var(--line); }
  /* Pan/zoom — a separate control, bottom-right. */
  .wfzoom { position:absolute; right:16px; bottom:90px; z-index:6; display:flex; align-items:center; gap:1px;
    background:var(--card); border:1px solid var(--line); border-radius:10px; padding:4px; box-shadow:0 4px 18px rgba(0,0,0,.10); }
  .wfzbtn { width:30px; height:30px; border:none; background:none; color:var(--ink); border-radius:7px; cursor:pointer; display:grid; place-items:center; }
  .wfzbtn:hover { background:color-mix(in srgb, var(--ink) 7%, transparent); }
  .wfzbtn svg { width:16px; height:16px; }
  .wfzlvl { min-width:48px; text-align:center; border:none; background:none; color:var(--ink); font:600 12px var(--mono); cursor:pointer; padding:0 4px; }
  .wfzlvl:hover { color:var(--dim); }
  /* Composer floats over the canvas — no backdrop, and only the pill itself catches pointer events so
     the canvas stays pannable in the strip around it (the canvas reaches the very bottom). */
  .wfcomposer { position:absolute; left:0; right:0; bottom:0; padding:14px 16px 18px; z-index:5; pointer-events:none; }
  .wfcomp-inner { max-width:680px; margin:0 auto; pointer-events:auto; display:flex; align-items:flex-end; gap:8px;
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
  // Illustrative graph: a trigger → a step that fans out to two parallel steps → a notify. Hand-rolled
  // (build-free vanilla — see the note above): draggable nodes, live bezier edges, pan/zoom, add/remove,
  // and drag-a-port-to-connect. Coordinates live in graph space; the .wfview layer carries pan+zoom.
  var NODES = [
    { id:'trigger', x:60,  y:170, kind:'Trigger',  label:'On schedule', c:'--mint' },
    { id:'fetch',   x:320, y:170, kind:'Step',     label:'Fetch data',  c:'--sky' },
    { id:'sum',     x:580, y:80,  kind:'Parallel', label:'Summarize',   c:'--violet' },
    { id:'cls',     x:580, y:270, kind:'Parallel', label:'Classify',    c:'--violet' },
    { id:'notify',  x:840, y:170, kind:'Step',     label:'Notify',      c:'--peach' }
  ];
  var EDGES = [['trigger','fetch'],['fetch','sum'],['fetch','cls'],['sum','notify'],['cls','notify']];
  var NW = 178, NH = 56, seq = 0, sel = null;
  var view = { x: 0, y: 0, k: 1 };
  var esc = function(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); };
  var svgI = function(d){ return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round">' + d + '</svg>'; };
  var I = {
    add:     svgI('<path d="M12 5v14M5 12h14"/>'),
    trigger: svgI('<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z"/>'),
    group:   svgI('<rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="13" width="8" height="8" rx="1.5"/><path d="M11 7h4a2 2 0 0 1 2 2v4"/>'),
    minus:   svgI('<path d="M5 12h14"/>'),
    plus:    svgI('<path d="M12 5v14M5 12h14"/>')
  };

  el.innerHTML =
    '<div class="wfwrap"><div class="wfcanvas" id="wfCanvas">' +
      '<div class="wfview" id="wfView"><svg class="wfedges" id="wfEdges"></svg></div>' +
      '<div class="wftoolbar">' +
        '<button class="wftbtn" data-add title="Add step">' + I.add + '</button>' +
        '<button class="wftbtn" data-trigger title="Add trigger">' + I.trigger + '</button>' +
        '<span class="wftsep"></span>' +
        '<button class="wftbtn" data-group title="Group selection">' + I.group + '</button>' +
      '</div>' +
      '<div class="wfzoom">' +
        '<button class="wfzbtn" data-zout title="Zoom out">' + I.minus + '</button>' +
        '<button class="wfzlvl" data-fit title="Reset view">100%</button>' +
        '<button class="wfzbtn" data-zin title="Zoom in">' + I.plus + '</button>' +
      '</div>' +
    '</div>' +
    '<div class="wfcomposer"><div class="wfcomp-inner">' +
      '<textarea class="wfta" rows="1" placeholder="Describe a workflow to generate…"></textarea>' +
      '<button class="wfsend" aria-label="Generate"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M12 5L6 11M12 5L18 11"/></svg></button>' +
    '</div></div></div>';

  var canvas = el.querySelector('#wfCanvas'), viewEl = el.querySelector('#wfView'), svg = el.querySelector('#wfEdges');
  var byId = function(id){ for (var i=0;i<NODES.length;i++) if (NODES[i].id===id) return NODES[i]; return null; };
  function applyView(){ viewEl.style.transform = 'translate(' + view.x + 'px,' + view.y + 'px) scale(' + view.k + ')';
    var lvl = el.querySelector('[data-fit]'); if (lvl) lvl.textContent = Math.round(view.k * 100) + '%'; }
  // Zoom to a target scale, keeping the (cx,cy) canvas point fixed under the cursor/anchor.
  function zoomTo(k2, cx, cy){ k2 = Math.min(2, Math.max(0.4, k2));
    view.x = cx - (cx - view.x) * (k2 / view.k); view.y = cy - (cy - view.y) * (k2 / view.k); view.k = k2; applyView(); }
  function zoomBtn(factor){ var r = canvas.getBoundingClientRect(); zoomTo(view.k * factor, r.width / 2, r.height / 2); }
  // clientX/Y → graph-space coords (undo the canvas origin, pan and zoom).
  function toGraph(cx, cy){ var r = canvas.getBoundingClientRect(); return { x: (cx - r.left - view.x) / view.k, y: (cy - r.top - view.y) / view.k }; }
  function path(sx, sy, tx, ty, cls){ var dx = Math.max(40, (tx - sx) / 2);
    return '<path' + (cls ? ' class="' + cls + '"' : '') + ' d="M ' + sx + ' ' + sy + ' C ' + (sx+dx) + ' ' + sy + ', ' + (tx-dx) + ' ' + ty + ', ' + tx + ' ' + ty + '"/>'; }
  function drawEdges(tmp){
    var s = EDGES.map(function(e){ var a = byId(e[0]), b = byId(e[1]); if (!a || !b) return '';
      return path(a.x + NW, a.y + NH/2, b.x, b.y + NH/2); }).join('');
    if (tmp) s += path(tmp.sx, tmp.sy, tmp.tx, tmp.ty, 'tmp');
    svg.innerHTML = s;
  }
  function nodeHtml(n){
    return '<div class="wfnode' + (sel === n.id ? ' sel' : '') + '" data-node="' + n.id + '" style="--nc:var(' + n.c + ');left:' + n.x + 'px;top:' + n.y + 'px">' +
      '<button class="wfdel" data-del aria-label="Delete">×</button>' +
      '<div class="wfkind"><i></i>' + esc(n.kind) + '</div><div class="wflbl">' + esc(n.label) + '</div>' +
      '<div class="wfport in" data-port="in"></div><div class="wfport out" data-port="out"></div></div>';
  }
  function render(){
    canvas.querySelectorAll('.wfnode').forEach(function(d){ d.remove(); });
    NODES.forEach(function(n){ viewEl.insertAdjacentHTML('beforeend', nodeHtml(n)); });
    drawEdges();
  }
  function place(n){ var d = canvas.querySelector('[data-node="' + n.id + '"]'); if (d){ d.style.left = n.x + 'px'; d.style.top = n.y + 'px'; } }
  function select(id){ sel = id; canvas.querySelectorAll('.wfnode').forEach(function(d){ d.classList.toggle('sel', d.getAttribute('data-node') === id); }); }
  function removeNode(id){ NODES = NODES.filter(function(n){ return n.id !== id; });
    EDGES = EDGES.filter(function(e){ return e[0] !== id && e[1] !== id; }); if (sel === id) sel = null; render(); }
  applyView(); render();

  // ── Gestures: one pointerdown router → node drag / port connect / canvas pan. Window-scoped move/up
  // listeners only run while a gesture is active (removed on up), so nothing leaks between views. ──
  var g = null;
  function onMove(e){
    if (!g) return;
    if (g.mode === 'pan'){ view.x = g.vx + (e.clientX - g.sx); view.y = g.vy + (e.clientY - g.sy); applyView(); }
    else if (g.mode === 'drag'){ var p = toGraph(e.clientX, e.clientY); g.n.x = p.x - g.ox; g.n.y = p.y - g.oy; place(g.n); drawEdges(); }
    else if (g.mode === 'connect'){ var a = byId(g.from); var pt = toGraph(e.clientX, e.clientY);
      drawEdges({ sx: a.x + NW, sy: a.y + NH/2, tx: pt.x, ty: pt.y }); }
  }
  function onUp(e){
    if (g && g.mode === 'connect'){
      var t = document.elementFromPoint(e.clientX, e.clientY);
      var nd = t && t.closest && t.closest('[data-node]');
      var to = nd && nd.getAttribute('data-node');
      if (to && to !== g.from && !EDGES.some(function(x){ return x[0] === g.from && x[1] === to; })) EDGES.push([g.from, to]);
      drawEdges();
    }
    if (g && g.mode === 'pan') canvas.classList.remove('panning');
    g = null; window.removeEventListener('pointermove', onMove); window.removeEventListener('pointerup', onUp);
  }
  function startGesture(e, mode, extra){ g = Object.assign({ mode: mode }, extra);
    window.addEventListener('pointermove', onMove); window.addEventListener('pointerup', onUp); }

  canvas.addEventListener('pointerdown', function(e){
    if (e.target.closest('.wftoolbar') || e.target.closest('.wfzoom') || e.target.closest('.wfcomposer') || e.target.closest('[data-del]')) return;
    var port = e.target.closest('[data-port]');
    var nd = e.target.closest('[data-node]');
    if (port && nd && port.getAttribute('data-port') === 'out'){ e.preventDefault();
      select(nd.getAttribute('data-node')); startGesture(e, 'connect', { from: nd.getAttribute('data-node') }); return; }
    if (nd){ e.preventDefault(); var n = byId(nd.getAttribute('data-node')); select(n.id);
      var p = toGraph(e.clientX, e.clientY); startGesture(e, 'drag', { n: n, ox: p.x - n.x, oy: p.y - n.y }); return; }
    // empty canvas → pan (and clear selection)
    select(null); canvas.classList.add('panning');
    startGesture(e, 'pan', { sx: e.clientX, sy: e.clientY, vx: view.x, vy: view.y });
  });

  // Wheel zoom, anchored on the cursor so the point under the pointer stays put.
  canvas.addEventListener('wheel', function(e){
    e.preventDefault(); var r = canvas.getBoundingClientRect();
    zoomTo(view.k * (e.deltaY < 0 ? 1.1 : 0.9), e.clientX - r.left, e.clientY - r.top);
  }, { passive: false });

  function addNode(kind, label, color){
    var r = canvas.getBoundingClientRect(); var c = toGraph(r.left + r.width/2, r.top + r.height/3);
    var n = { id: 'n' + (++seq), x: c.x - NW/2, y: c.y, kind: kind, label: label, c: color };
    NODES.push(n); render(); select(n.id); return n;
  }
  el.querySelector('[data-fit]').addEventListener('click', function(){ view = { x: 0, y: 0, k: 1 }; applyView(); });
  el.querySelector('[data-zin]').addEventListener('click', function(){ zoomBtn(1.2); });
  el.querySelector('[data-zout]').addEventListener('click', function(){ zoomBtn(1 / 1.2); });
  el.querySelector('[data-add]').addEventListener('click', function(){ addNode('Step', 'New step', '--sky'); });
  el.querySelector('[data-trigger]').addEventListener('click', function(){ addNode('Trigger', 'On schedule', '--mint'); });
  el.querySelector('[data-group]').addEventListener('click', function(){ WB.toast('Grouping is coming soon'); });
  canvas.addEventListener('click', function(e){ var del = e.target.closest('[data-del]');
    if (del){ var nd = del.closest('[data-node]'); if (nd) removeNode(nd.getAttribute('data-node')); } });

  function onKey(e){ if ((e.key === 'Delete' || e.key === 'Backspace') && sel && document.activeElement &&
    !/^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName)){ e.preventDefault(); removeNode(sel); } }
  document.addEventListener('keydown', onKey);
  WB._cleanup = function(){ document.removeEventListener('keydown', onKey);
    window.removeEventListener('pointermove', onMove); window.removeEventListener('pointerup', onUp); };

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
