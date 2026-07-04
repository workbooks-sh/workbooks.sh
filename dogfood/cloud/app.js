/* Workbooks Cloud dashboard — vanilla SPA (no framework, no build). Reads /api/platform like the CLI.
   Step 1: the shell + routing + empty surfaces. Data wiring lands per SPEC §8 steps 3–9. */
(function () {
  'use strict';
  var h = function (html) { var t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var fmtUSD = function (n) { n = +n || 0; return '$' + n.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ','); };

  async function api(path, opts) {
    opts = opts || {};
    var r = await fetch((opts.base || '/api/platform') + path, {
      method: opts.method || 'GET', credentials: 'same-origin',
      headers: opts.body ? { 'content-type': 'application/json' } : undefined,
      body: opts.body ? JSON.stringify(opts.body) : undefined
    });
    if (r.status === 401) { toLogin(); throw new Error('unauthorized'); }
    var ct = r.headers.get('content-type') || '';
    var payload = ct.indexOf('json') >= 0 ? await r.json().catch(function () { return null; }) : await r.text();
    if (!r.ok) throw new Error((payload && (payload.detail || payload.error)) || ((opts.method || 'GET') + ' ' + path + ' → ' + r.status));
    return payload;
  }
  function toLogin() {
    if (location.pathname.indexOf('/login') === 0) return;
    location.assign('/login/?next=' + encodeURIComponent(location.pathname + location.hash));
  }

  // ---- icons: inlined Lucide paths (lucide.dev, ISC) — real set, no CDN/build, 24x24 stroke ----
  var IC = {
    overview: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>', // layout-dashboard
    agents: '<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>', // bot
    usage: '<path d="M3 3v18h18"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>', // bar-chart-3
    data: '<path d="M12 3v18"/><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/>', // table
    integrations: '<path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/>', // plug
    channels: '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/>', // phone
    secrets: '<circle cx="7.5" cy="15.5" r="5.5"/><path d="m21 2-9.6 9.6"/><path d="m15.5 7.5 3 3L22 7l-3-3"/>', // key
    team: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>', // users
    billing: '<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/>', // credit-card
    domains: '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>', // globe
    out: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>', // log-out
    rocket: '<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>' // rocket
  };
  var icon = function (k, cls) { return '<svg viewBox="0 0 24 24" class="ico' + (cls ? ' ' + cls : '') + '" aria-hidden="true">' + (IC[k] || '') + '</svg>'; };

  // pastel DNA strip (ported from the old dashboard): weighted pastel segments, seeded-shuffled,
  // doubled so the track loops seamlessly under the drift animation.
  function dna(seed, height) {
    seed = seed == null ? 11 : seed; height = height == null ? 7 : height;
    var MIX = [['#f3c5a3', 0.30], ['#aee5c2', 0.24], ['#a8d4f0', 0.20], ['#9fc4e8', 0.14], ['#f2ddb0', 0.12]];
    var out = [], k = seed, i, j, r;
    for (var m = 0; m < MIX.length; m++) { var c = MIX[m][0], f = MIX[m][1]; var n = f > 0.3 ? 3 : f > 0.12 ? 2 : 1; for (j = 0; j < n; j++) out.push([c, f / n]); }
    for (i = out.length - 1; i > 0; i--) { k++; r = (((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1; j = Math.floor(r * (i + 1)); var t = out[i]; out[i] = out[j]; out[j] = t; }
    var bars = out.concat(out).map(function (b) { return '<i style="width:' + (b[1] * 50).toFixed(2) + '%;background:' + b[0] + '"></i>'; }).join('');
    return '<div class="dna" style="--h:' + height + 'px" aria-hidden="true"><div class="track">' + bars + '</div></div>';
  }
  var PETAL = '<svg viewBox="0 0 113.444 65.6002" aria-label="Workbooks"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>';

  // ---- surfaces ----
  var NAV = [
    { id: 'overview', label: 'Overview', title: 'Overview', lede: 'Your workspace at a glance — what’s running, this month’s usage, and anything that needs you.' },
    { id: 'agents', label: 'Agents', title: 'Agents', lede: 'The agents running in your workspace — their status, and how to deploy, roll, or pause them.' },
    { id: 'usage', label: 'Usage', title: 'AI usage', lede: 'Every model call and unit of compute your agents and apps use — and what it costs.' },
    { id: 'data', label: 'Data', title: 'Data', lede: 'Your tables, rows, and queries — create a table, browse and edit data, or run SQL.' },
    { id: 'integrations', label: 'Integrations', title: 'Integrations', lede: 'Connect the tools your agents and apps act through — Gmail, GitHub, Slack, and hundreds more.' },
    { id: 'channels', label: 'Channels', title: 'Channels', lede: 'Give an agent a phone number. Text it or call it from anywhere.' },
    { id: 'secrets', label: 'Secrets', title: 'Secrets', lede: 'Your API keys and credentials, encrypted at rest. Your agents and apps read them at runtime; no one else can.' },
    { id: 'team', label: 'Team', title: 'Team', lede: 'Who can see and manage this workspace.' },
    { id: 'billing', label: 'Billing', title: 'Billing', lede: 'Your plan, invoices, and payment method.' },
    { id: 'domains', label: 'Domains', title: 'Domains', lede: 'Point your own domain at what you’ve deployed.' }
  ];
  var byId = {}; NAV.forEach(function (n) { byId[n.id] = n; });

  var me = null, root = null;

  async function boot() {
    root = document.getElementById('root');
    try { me = await api('/me'); }
    catch (e) { return; } // 401 already redirected; any other error falls through to a minimal shell
    renderShell();
    window.addEventListener('hashchange', route);
    route();
  }

  function initials(s) { s = String(s == null ? '?' : s).trim() || '?'; var at = s.indexOf('@'); var base = at > 0 ? s.slice(0, at) : s; return (base[0] || '?').toUpperCase(); }

  function renderShell() {
    var u = (me && me.user) || {};
    var email = u.email || u.name || (me && me.email) || 'you';
    var o0 = (me && me.orgs && me.orgs[0]) || {};
    var org = o0.name || o0.id || (me && me.active_org) || 'your workspace';
    root.innerHTML = '';
    root.appendChild(h(
      '<div id="app">' +
        '<aside class="rail">' +
          dna(11, 7) +
          '<div class="brand">' + PETAL + '<b>Workbooks</b></div>' +
          '<nav class="nav">' + NAV.map(function (n) {
            return '<a href="#/' + n.id + '" data-id="' + n.id + '">' + icon(n.id) + '<span class="lbl">' + esc(n.label) + '</span></a>';
          }).join('') + '</nav>' +
          '<div class="rail-grow"></div>' +
          '<div class="who">' +
            '<span class="av">' + esc(initials(email)) + '</span>' +
            '<span class="meta"><b>' + esc(email) + '</b><span>' + esc(org) + '</span></span>' +
            '<button class="out" id="signout" title="Sign out" aria-label="Sign out">' + icon('out') + '</button>' +
          '</div>' +
        '</aside>' +
        '<div class="main">' +
          '<header class="top"><h1 id="top-title">Overview</h1><span class="spacer"></span></header>' +
          '<div class="wrap"><div class="view" id="view"></div></div>' +
        '</div>' +
      '</div>'
    ));
    document.getElementById('signout').addEventListener('click', signOut);
  }

  function capi(path, opts) { opts = opts || {}; opts.base = '/api/cloud'; return api(path, opts); }
  function listOf(x) { return !x ? [] : (Array.isArray(x) ? x : (x.items || x.data || x.connections || x.toolkits || x.auth_configs || [])); }

  var BODY = { overview: overviewBody, agents: agentsBody, usage: usageBody, data: explorerBody, secrets: secretsBody, team: teamBody, billing: billingBody, domains: domainsBody, integrations: integrationsBody };
  var WIRE = { overview: wireOverview, agents: wireAgents, usage: wireUsage, data: wireExplorer, secrets: wireSecrets, team: wireTeam, billing: wireBilling, domains: wireDomains, integrations: wireIntegrations };
  function canManage() { return !!(me && (me.role === 'owner' || me.role === 'admin')); }
  function route() {
    var id = (location.hash.replace(/^#\/?/, '') || 'overview');
    if (!byId[id]) id = 'overview';
    var n = byId[id];
    document.querySelectorAll('.nav a').forEach(function (a) { a.classList.toggle('on', a.getAttribute('data-id') === id); });
    document.getElementById('top-title').textContent = n.title;
    var full = id === 'data';
    var view = document.getElementById('view');
    view.className = 'view' + (full ? ' full' : '');
    view.innerHTML =
      (full ? '' : '<p class="view-lede">' + esc(n.lede) + '</p>') +
      (BODY[id] ? BODY[id]() : emptyBody(id));
    if (WIRE[id]) WIRE[id]();
  }

  function overviewBody() {
    return '' +
      '<div class="card" id="ap-card" style="margin-bottom:14px">' +
        '<div style="display:flex;align-items:center;gap:14px">' +
          '<div class="empty ic" style="width:44px;height:44px;padding:0;border:0;background:var(--line-2)">' + icon('rocket') + '</div>' +
          '<div style="flex:1"><div class="eyebrow">Your agent</div>' +
            '<div id="ap-status" style="margin-top:4px;display:flex;align-items:center;gap:10px">' +
              '<span class="pill"><span class="spin" style="width:12px;height:12px;border-width:2px"></span>checking…</span></div></div>' +
        '</div>' +
      '</div>' +
      '<div class="grid g3">' +
        stat('Usage this month', '&mdash;', 'compute + storage', 'ov-mtd') +
        stat('Team', '&mdash;', 'members', 'ov-team') +
        stat('Credit balance', '&mdash;', 'AI credits · top up in Billing', 'ov-credit') +
      '</div>' +
      '<div class="eyebrow" style="margin:28px 0 12px">Storage</div>' +
      '<div id="ov-storage"><div class="center" style="min-height:120px"><div class="spin"></div></div></div>';
  }
  function stat(k, n, sub, id) {
    return '<div class="card stat"><div class="eyebrow">' + esc(k) + '</div>' +
      '<div class="n"' + (id ? ' id="' + id + '"' : '') + '>' + n + '</div><div class="k">' + esc(sub) + '</div></div>';
  }
  function setText(id, t) { var el = document.getElementById(id); if (el) el.textContent = t; }

  async function wireOverview() {
    // one-nexus-per-org: show the autopoet's real status, or a provision CTA if none
    var el = document.getElementById('ap-status'); if (!el) return;
    try {
      var list = await api('/nexuses').catch(function () { return null; });
      var nx = list && (Array.isArray(list) ? list[0] : (list.nexuses && list.nexuses[0]));
      if (nx) {
        var state = (nx.state || nx.status || 'unknown');
        var ok = /run|start|healthy|live|up/i.test(state);
        el.innerHTML = '<span class="pill ' + (ok ? 'ok' : 'warn') + '"><span class="dot"></span>' + esc(state) + '</span>' +
          '<span style="color:var(--dim);font-size:12.5px">' + esc(nx.name || nx.id || '') + '</span>';
      } else {
        el.innerHTML = '<span style="color:var(--dim);font-size:13px">No agent running yet.</span>' +
          '<button class="btn" style="margin-left:2px" disabled title="Wired in step 3">' + icon('rocket', '') + 'Provision</button>';
      }
    } catch (e) {
      el.innerHTML = '<span class="pill warn"><span class="dot"></span>status unavailable</span>';
    }
    // real local stats: month-to-date spend + team size
    api('/usage').then(function (u) { setText('ov-mtd', (u && u.monthToDate) || '$0.00'); }).catch(function () {});
    api('/members').then(function (r) { var n = (r && r.members || []).length; setText('ov-team', String(n) + (n === 1 ? ' member' : ' members')); }).catch(function () {});
    api('/credits').then(function (c) { setText('ov-credit', fmtUSD(c && c.balance)); }).catch(function () {});
    renderStorage(document.getElementById('ov-storage'));
  }

  function emptyBody(id) {
    var copy = {
      usage: 'Once your agents and apps start working, every model call, its cost, and your remaining credit show up here.',
      integrations: 'Browse the catalog and connect an account — your agents and apps gain that tool the moment you link it.',
      channels: 'Provision a phone number and an agent can text and call. Toll-free verification runs here too.',
      secrets: 'Add a provider key or credential; it’s encrypted at rest and handed only to your agents and apps at runtime.',
      team: 'Invite people and set roles. Everyone here shares this workspace’s deployments, usage, and billing.',
      billing: 'Pick a plan, add a card, buy credits, and download invoices — all through our billing partner.',
      domains: 'Add a domain and point one CNAME at us; we issue the certificate and your app answers on it.'
    };
    return '<div class="empty"><div class="ic">' + icon(id) + '</div>' +
      '<div class="soon">Wiring in progress</div>' +
      '<h2>' + esc(byId[id].title) + '</h2>' +
      '<p>' + esc(copy[id] || '') + '</p></div>';
  }

  // ---- Secrets (step 5): full CRUD over /api/platform/env ----
  var SCOPE_LABEL = { nexus: 'shared', user: 'you', workspace: 'workspace', package: 'package', org: 'org' };
  function secretsBody() {
    return '' +
      '<div class="card" style="margin-bottom:16px">' +
        '<form id="sec-add" class="sec-form" autocomplete="off">' +
          '<input id="sec-name" placeholder="NAME  ·  e.g. OPENAI_API_KEY" spellcheck="false" required>' +
          '<input id="sec-val" type="password" placeholder="value" autocomplete="new-password" required>' +
          '<select id="sec-scope" title="Who this secret is for">' +
            '<option value="nexus">agents &amp; apps</option><option value="user">just you</option></select>' +
          '<button class="btn" type="submit">Add secret</button>' +
        '</form>' +
      '</div>' +
      '<div id="sec-list"><div class="center" style="min-height:120px"><div class="spin"></div></div></div>';
  }

  function wireSecrets() {
    var f = document.getElementById('sec-add');
    f.addEventListener('submit', async function (e) {
      e.preventDefault();
      var name = document.getElementById('sec-name').value.trim();
      var value = document.getElementById('sec-val').value;
      var scope = document.getElementById('sec-scope').value;
      if (!name || !value) return;
      var btn = f.querySelector('button'); btn.disabled = true;
      try {
        await api('/env', { method: 'POST', body: { name: name, value: value, scope: scope } });
        document.getElementById('sec-name').value = ''; document.getElementById('sec-val').value = '';
        toast('Secret “' + name + '” saved', 'ok'); loadSecrets();
      } catch (err) { toast('Could not save — ' + err.message, 'err'); }
      finally { btn.disabled = false; }
    });
    loadSecrets();
  }

  async function loadSecrets() {
    var host = document.getElementById('sec-list'); if (!host) return;
    try {
      var res = await api('/env');
      var list = (res && res.env) || [];
      if (!list.length) {
        host.innerHTML = '<div class="empty"><div class="ic">' + icon('secrets') + '</div>' +
          '<h2>No secrets yet</h2><p>Add a provider key above — it’s encrypted at rest and handed only to your agents and apps at runtime. No one else, including us, can read it back.</p></div>';
        return;
      }
      host.innerHTML = '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr>' +
        '<th>Name</th><th>For</th><th>Value</th><th></th></tr></thead><tbody>' +
        list.map(function (s) {
          return '<tr data-id="' + esc(s.id) + '" data-name="' + esc(s.name) + '">' +
            '<td class="mono">' + esc(s.name) + '</td>' +
            '<td><span class="pill">' + esc(SCOPE_LABEL[s.scope] || s.scope || 'shared') + '</span></td>' +
            '<td class="mono val">' + (s.present !== false
              ? '•••••••• <span class="dim">' + (s.length ? s.length + ' chars' : '') + '</span>'
              : '<span class="dim">empty</span>') + '</td>' +
            '<td class="row-act"><button class="btn ghost sm" data-act="reveal">Reveal</button>' +
            '<button class="btn ghost sm danger" data-act="del">Delete</button></td></tr>';
        }).join('') + '</tbody></table></div>';
      host.querySelector('tbody').addEventListener('click', onSecretAction);
    } catch (err) {
      host.innerHTML = '<div class="empty"><p>Couldn’t load secrets — ' + esc(err.message) + '</p></div>';
    }
  }

  async function onSecretAction(e) {
    var btn = e.target.closest('button[data-act]'); if (!btn) return;
    var tr = btn.closest('tr'), id = tr.getAttribute('data-id'), name = tr.getAttribute('data-name'), act = btn.getAttribute('data-act');
    if (act === 'del') {
      if (!confirm('Delete “' + name + '”? Your agents and apps will lose access to it.')) return;
      try { await api('/env/' + encodeURIComponent(id), { method: 'DELETE' }); toast('Deleted “' + name + '”', 'ok'); loadSecrets(); }
      catch (err) { toast('Delete failed — ' + err.message, 'err'); }
    } else if (act === 'reveal') {
      if (btn.textContent === 'Hide') { loadSecrets(); return; }
      try {
        var r = await api('/env/' + encodeURIComponent(id) + '/reveal');
        tr.querySelector('.val').innerHTML = '<span class="reveal">' + esc(r.value) + '</span>';
        btn.textContent = 'Hide';
      } catch (err) { toast('Reveal failed — ' + err.message, 'err'); }
    }
  }

  function toast(msg, kind) {
    var t = document.createElement('div'); t.className = 'toast ' + (kind || ''); t.textContent = msg;
    document.body.appendChild(t);
    requestAnimationFrame(function () { t.classList.add('in'); });
    setTimeout(function () { t.classList.remove('in'); setTimeout(function () { t.remove(); }, 250); }, 2600);
  }

  // ---- Team (surface 2.6): members + invites over /api/platform/members ----
  var ROLE_CLS = { owner: 'ok', admin: '', member: '', viewer: '' };
  function teamBody() {
    var invite = canManage() ? '<div class="card" style="margin-bottom:16px"><form id="tm-add" class="sec-form" autocomplete="off">' +
      '<input id="tm-email" type="email" placeholder="teammate@company.com" required style="flex:2;min-width:220px">' +
      '<select id="tm-role"><option value="member">Member</option><option value="admin">Admin</option></select>' +
      '<button class="btn" type="submit">Send invite</button></form></div>' : '';
    return invite + '<div id="tm-list"><div class="center" style="min-height:120px"><div class="spin"></div></div></div>';
  }
  function wireTeam() {
    var f = document.getElementById('tm-add');
    if (f) f.addEventListener('submit', async function (e) {
      e.preventDefault();
      var email = document.getElementById('tm-email').value.trim(), role = document.getElementById('tm-role').value;
      if (!email) return;
      var btn = f.querySelector('button'); btn.disabled = true;
      try { await api('/members/invite', { method: 'POST', body: { email: email, role: role } });
        document.getElementById('tm-email').value = ''; toast('Invited ' + email, 'ok'); loadTeam(); }
      catch (err) { toast('Invite failed — ' + err.message, 'err'); }
      finally { btn.disabled = false; }
    });
    document.getElementById('tm-list').addEventListener('click', onTeamAction); // once; survives innerHTML swaps
    loadTeam();
  }
  async function loadTeam() {
    var host = document.getElementById('tm-list'); if (!host) return;
    try {
      var res = await api('/members');
      var members = (res && res.members) || [], pending = (res && res.pending) || [];
      var rows = members.map(function (m) {
        var mine = me && me.user && m.id === me.user.id;
        var canRemove = canManage() && !mine;
        return '<tr data-id="' + esc(m.id) + '" data-email="' + esc(m.email) + '" data-kind="member">' +
          '<td><div style="display:flex;align-items:center;gap:10px"><span class="av2">' + esc((m.name || m.email)[0].toUpperCase()) + '</span>' +
            '<div><b>' + esc(m.name || '') + (mine ? ' <span class="dim" style="font-weight:400">· you</span>' : '') + '</b>' +
            '<div class="dim" style="font-size:12px">' + esc(m.email) + '</div></div></div></td>' +
          '<td><span class="pill ' + (ROLE_CLS[m.role] || '') + '">' + esc(m.role || 'member') + '</span></td>' +
          '<td class="row-act">' + (canRemove ? '<button class="btn ghost sm danger" data-act="remove">Remove</button>' : '') + '</td></tr>';
      }).join('');
      var pend = pending.length ? '<div class="eyebrow" style="margin:22px 0 10px">Pending invites</div>' +
        '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><tbody>' + pending.map(function (p) {
          return '<tr data-id="' + esc(p.id) + '" data-email="' + esc(p.email) + '" data-kind="invite">' +
            '<td class="mono">' + esc(p.email) + '</td><td><span class="pill warn"><span class="dot"></span>invited</span></td>' +
            '<td class="row-act">' + (canManage() ? '<button class="btn ghost sm" data-act="revoke">Revoke</button>' : '') + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '';
      host.innerHTML = '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr>' +
        '<th>Member</th><th>Role</th><th></th></tr></thead><tbody>' + rows + '</tbody></table></div>' + pend;
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load the team — ' + esc(err.message) + '</p></div>'; }
  }
  async function onTeamAction(e) {
    var btn = e.target.closest('button[data-act]'); if (!btn) return;
    var tr = btn.closest('tr'), id = tr.getAttribute('data-id'), email = tr.getAttribute('data-email'), act = btn.getAttribute('data-act');
    if (act === 'remove') {
      if (!confirm('Remove ' + email + ' from the workspace?')) return;
      try { await api('/members/' + encodeURIComponent(id), { method: 'DELETE' }); toast('Removed ' + email, 'ok'); loadTeam(); }
      catch (err) { toast(err.message, 'err'); }
    } else if (act === 'revoke') {
      try { await api('/invitations/' + encodeURIComponent(id) + '/revoke', { method: 'POST' }); toast('Invite revoked', 'ok'); loadTeam(); }
      catch (err) { toast('Revoke failed — ' + err.message, 'err'); }
    }
  }

  // ---- Usage (surface 2.2): capacity + compute now; AI-token metering lands in step 4 ----
  function usageBody() { return '<div id="usage-body"><div class="center" style="min-height:160px"><div class="spin"></div></div></div>'; }
  function gauge(label, m) {
    m = m || {}; var pct = Math.max(0, Math.min(100, m.pct || 0));
    return '<div class="card"><div class="eyebrow">' + esc(label) + '</div>' +
      '<div style="display:flex;justify-content:space-between;align-items:baseline;margin:7px 0 9px">' +
      '<span class="mono" style="font-size:15px">' + esc(m.label || '—') + '</span>' +
      '<span class="pill ' + (m.status === 'warn' ? 'warn' : m.status === 'crit' ? 'crit' : 'ok') + '">' + esc(m.status || 'ok') + '</span></div>' +
      '<div class="bar"><i style="width:' + pct + '%"></i></div></div>';
  }
  async function wireUsage() {
    var host = document.getElementById('usage-body');
    try {
      var u = await api('/usage');
      var c = await api('/credits').catch(function () { return { balance: 0, spent_mtd: 0 }; });
      host.innerHTML =
        '<div class="eyebrow" style="margin:0 0 10px">AI credits</div>' +
        '<div class="grid g3" style="margin-bottom:14px">' +
          stat('Credit balance', fmtUSD(c.balance), c.enforce ? 'metered per call' : 'not enforced yet') +
          stat('AI spend · this month', fmtUSD(c.spent_mtd), c.monthly_cap ? 'of ' + fmtUSD(c.monthly_cap) + ' cap' : 'no monthly cap') +
          '<div class="card stat"><div class="eyebrow">Top up</div><div style="margin:8px 0 6px"><button class="btn" id="usage-topup">Add credits</button></div><div class="k">buy more AI credit</div></div>' +
        '</div>' +
        (c.monthly_cap ? '<div class="card" style="margin-bottom:22px">' + capGauge(c) + '</div>' : '') +
        '<div class="empty" style="border-style:solid;margin-bottom:28px"><p>Per-model spend breakdown lands here with the inference ledger. Your balance, spend, and cap above are <b>live</b>.</p></div>' +
        '<div class="eyebrow" style="margin:0 0 10px">Compute &amp; storage</div>' +
        '<div class="grid g3" style="margin-bottom:14px">' +
          stat('Month to date', esc(u.monthToDate || '$0.00'), 'compute + storage') +
          stat('Compute', esc(u.compute || '$0.00'), (u.activeHrs || 0) + ' active hours') +
          stat('Plan', esc((u.tier && u.tier.name) || '—'), (u.tier && u.tier.price) || '') +
        '</div>' +
        '<div class="grid g2">' + gauge('Memory', u.ram) + gauge('Storage', u.storage) + '</div>';
      var tu = document.getElementById('usage-topup'); if (tu) tu.addEventListener('click', topUpModal);
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load usage — ' + esc(err.message) + '</p></div>'; }
  }
  function capGauge(c) {
    var pct = c.cap_pct || 0;
    return '<div class="eyebrow">Monthly cap</div>' +
      '<div style="display:flex;justify-content:space-between;align-items:baseline;margin:7px 0 9px">' +
      '<span class="mono" style="font-size:15px">' + fmtUSD(c.spent_mtd) + ' / ' + fmtUSD(c.monthly_cap) + '</span>' +
      '<span class="pill ' + (pct >= 90 ? 'crit' : pct >= 70 ? 'warn' : 'ok') + '">' + pct + '%</span></div>' +
      '<div class="bar"><i style="width:' + Math.min(100, pct) + '%"></i></div>';
  }
  function topUpModal() {
    var amt = 25;
    var m = modal('Add AI credits',
      '<label class="fld-l">Amount</label><div class="topup-amts">' +
        [10, 25, 50, 100].map(function (a) { return '<button type="button" class="topup-a' + (a === amt ? ' on' : '') + '" data-a="' + a + '">$' + a + '</button>'; }).join('') + '</div>' +
      '<label class="fld-l" style="margin-top:14px">Or a custom amount (USD)</label><input class="fld-i" id="topup-custom" type="number" min="1" placeholder="e.g. 40">' +
      '<p class="dim" style="font-size:12px;margin:14px 0 0;line-height:1.5">In production this opens Polar checkout. As an owner/admin it also works right now as a direct grant (support · comps).</p>',
      '<button class="btn ghost" id="topup-cancel">Cancel</button><button class="btn" id="topup-go">Add credits</button>');
    m.el.querySelectorAll('.topup-a').forEach(function (b) { b.addEventListener('click', function () { amt = +b.dataset.a; m.el.querySelector('#topup-custom').value = ''; m.el.querySelectorAll('.topup-a').forEach(function (x) { x.classList.toggle('on', x === b); }); }); });
    m.el.querySelector('#topup-cancel').addEventListener('click', m.close);
    m.el.querySelector('#topup-go').addEventListener('click', async function () {
      var custom = +m.el.querySelector('#topup-custom').value, amount = custom > 0 ? custom : amt;
      // real payment first (Polar checkout); if billing isn't configured, fall back to the admin grant.
      try {
        var r = await api('/credits/checkout', { method: 'POST', body: { amount: amount } });
        if (r && r.url) { window.location.assign(r.url); return; }
      } catch (err) {
        try {
          var g = await api('/credits/topup', { method: 'POST', body: { amount: amount } });
          toast('Added ' + fmtUSD(amount) + ' · balance ' + fmtUSD(g.balance) + ' (grant)', 'ok'); m.close(); route(); return;
        } catch (e2) { toast(e2.message, 'err'); return; }
      }
      toast('Checkout unavailable', 'err');
    });
  }

  // ---- Billing (surface 2.7): the tier ladder now; checkout/invoices need Polar (via Secrets) ----
  function billingBody() { return '<div id="bill-body"><div class="center" style="min-height:160px"><div class="spin"></div></div></div>'; }
  async function wireBilling() {
    var host = document.getElementById('bill-body');
    try {
      var res = await api('/tiers'); var tiers = (res && res.tiers) || [];
      var u = await api('/usage').catch(function () { return {}; });
      var c = await api('/credits').catch(function () { return { balance: 0, spent_mtd: 0 }; });
      var sub = await api('/billing/subscription').catch(function () { return {}; });
      var curId = (sub && sub.tier) || (u.tier && u.tier.id) || 'default';
      host.innerHTML =
        '<div class="eyebrow" style="margin:0 0 10px">AI credits</div>' +
        '<div class="card bill-credits">' +
          '<div><div class="eyebrow">Balance</div><div class="sys-size">' + fmtUSD(c.balance) + '</div></div>' +
          '<div><div class="eyebrow">Spent this month</div><div class="sys-size">' + fmtUSD(c.spent_mtd) + '</div></div>' +
          '<div style="flex:1"></div><button class="btn" id="bill-topup">Add credits</button></div>' +
        '<div class="eyebrow" style="margin:0 0 10px">Plan' + (sub && sub.status === 'active' ? ' · <span style="color:var(--good)">active</span>' : '') + '</div>' +
        '<div class="grid g3">' + tiers.map(function (t) {
          var on = t.id === curId;
          var price = t.price === 0 ? 'Free' : (t.price ? '$' + t.price : '—');
          return '<div class="card tier' + (on ? ' on' : '') + '">' +
            (on ? '<span class="pill ok tier-tag">current</span>' : '') +
            '<div class="eyebrow">' + esc(t.name) + '</div>' +
            '<div class="price">' + esc(price) + '<span>/mo</span></div>' +
            '<ul class="feats">' +
              '<li>' + (t.ram_mb ? t.ram_mb + ' MB RAM' : 'shared RAM') + '</li>' +
              '<li>' + (t.storage_gb ? t.storage_gb + ' GB storage' : 'shared storage') + '</li>' +
              (t['domains?'] ? '<li>custom domains</li>' : '') + '</ul>' +
            (on ? '' : '<button class="btn ghost" data-plan="' + esc(t.id) + '">Choose ' + esc(t.name) + '</button>') +
          '</div>';
        }).join('') + '</div>' +
        '<div class="eyebrow" style="margin:26px 0 10px">Invoices &amp; payment</div>' +
        '<div class="empty"><div class="ic">' + icon('billing') + '</div><div class="soon">Connect billing</div>' +
        '<h2>Billing runs through Polar</h2><p>Add your <span class="mono">POLAR_ACCESS_TOKEN</span> in <b>Secrets</b> to turn on checkout, invoices, and credit top-ups.</p></div>';
      var bt = document.getElementById('bill-topup'); if (bt) bt.addEventListener('click', topUpModal);
      host.addEventListener('click', function (e) {
        var pb = e.target.closest('button[data-plan]');
        if (pb) startCheckout(pb.getAttribute('data-plan'));
      });
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load plans — ' + esc(err.message) + '</p></div>'; }
  }

  // ---- Domains (surface 2.8): custom hostnames over /api/platform/domains ----
  function domainsBody() {
    var add = canManage() ? '<div class="card" style="margin-bottom:16px"><form id="dm-add" class="sec-form" autocomplete="off">' +
      '<input id="dm-host" placeholder="cloud.yourdomain.com" spellcheck="false" required style="flex:2;min-width:220px;font-family:var(--mono);font-size:12.5px">' +
      '<button class="btn" type="submit">Add domain</button></form></div>' : '';
    return add + '<div id="dm-list"><div class="center" style="min-height:120px"><div class="spin"></div></div></div>';
  }
  function wireDomains() {
    var f = document.getElementById('dm-add');
    if (f) f.addEventListener('submit', async function (e) {
      e.preventDefault();
      var hostv = document.getElementById('dm-host').value.trim(); if (!hostv) return;
      var btn = f.querySelector('button'); btn.disabled = true;
      try { await api('/domains', { method: 'POST', body: { host: hostv } }); document.getElementById('dm-host').value = ''; toast('Added ' + hostv, 'ok'); loadDomains(); }
      catch (err) { toast(err.message, 'err'); } finally { btn.disabled = false; }
    });
    document.getElementById('dm-list').addEventListener('click', onDomainAction);
    loadDomains();
  }
  async function loadDomains() {
    var host = document.getElementById('dm-list'); if (!host) return;
    try {
      var res = await api('/domains'); var list = (res && res.domains) || [];
      if (!list.length) {
        host.innerHTML = '<div class="empty"><div class="ic">' + icon('domains') + '</div><h2>No custom domains</h2>' +
          '<p>Add a domain to serve your app on your own hostname — one CNAME/TXT record, we issue the certificate. (You’ll deploy something first.)</p></div>';
        return;
      }
      host.innerHTML = '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr><th>Domain</th><th>Status</th><th></th></tr></thead><tbody>' +
        list.map(function (d) {
          var name = d.host || d.name || '', st = d.status || d.state || 'pending', ok = /verif|active|live|ready/i.test(st);
          var txt = d.txt || d.challenge || d.record;
          return '<tr data-id="' + esc(d.id) + '" data-host="' + esc(name) + '">' +
            '<td class="mono">' + esc(name) + (txt && !ok ? '<div class="dim" style="font-size:11.5px;margin-top:4px;user-select:all">TXT ' + esc(txt) + '</div>' : '') + '</td>' +
            '<td><span class="pill ' + (ok ? 'ok' : 'warn') + '"><span class="dot"></span>' + esc(st) + '</span></td>' +
            '<td class="row-act">' + (ok ? '' : '<button class="btn ghost sm" data-act="verify">Verify</button>') +
            '<button class="btn ghost sm danger" data-act="del">Remove</button></td></tr>';
        }).join('') + '</tbody></table></div>';
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load domains — ' + esc(err.message) + '</p></div>'; }
  }
  async function onDomainAction(e) {
    var btn = e.target.closest('button[data-act]'); if (!btn) return;
    var tr = btn.closest('tr'), id = tr.getAttribute('data-id'), hn = tr.getAttribute('data-host'), act = btn.getAttribute('data-act');
    if (act === 'del') {
      if (!confirm('Remove ' + hn + '?')) return;
      try { await api('/domains/' + encodeURIComponent(id), { method: 'DELETE' }); toast('Removed ' + hn, 'ok'); loadDomains(); } catch (err) { toast(err.message, 'err'); }
    } else if (act === 'verify') {
      try { await api('/domains/' + encodeURIComponent(id) + '/verify', { method: 'POST' }); toast('Verified ' + hn, 'ok'); loadDomains(); } catch (err) { toast(err.message, 'err'); }
    }
  }

  // ---- Integrations (surface 2.3): whitelabel Composio over /api/cloud/tools/* ----
  function integrationsBody() { return '<div id="int-body"><div class="center" style="min-height:160px"><div class="spin"></div></div></div>'; }
  function onboardComposio() {
    return '<div class="empty"><div class="ic">' + icon('integrations') + '</div><div class="soon">Not connected</div>' +
      '<h2>Turn on integrations</h2><p>Integrations run through Composio. Add a <span class="mono">COMPOSIO_API_KEY</span> in <b>Secrets</b> and this becomes a catalog of tools your agents and apps can act through — Gmail, GitHub, Slack, and hundreds more.</p>' +
      '<a class="btn" href="#/secrets" style="margin-top:2px">Open Secrets</a></div>';
  }
  var tkSlug = function (t) { return (t.slug || t.name || t.key || '') + ''; };
  var tkName = function (t) { return (t.name || t.slug || 'Integration') + ''; };
  var tkLogo = function (t) { var m = t.meta || t; return m.logo || m.logo_url || ''; };

  var intState = null;
  function connCard(c) {
    var tk = (c.toolkit && c.toolkit.slug) || c.toolkit || c.appName || 'account';
    var logo = (c.toolkit && c.toolkit.logo) || '', st = (c.status || c.connectionStatus || 'active') + '';
    return '<div class="card int" data-conn="' + esc(c.id || c.nano_id || '') + '"><div class="int-top">' +
      (logo ? '<img class="int-logo" src="' + esc(logo) + '" alt="">' : '<span class="int-logo">' + esc(('' + tk)[0].toUpperCase()) + '</span>') +
      '<b>' + esc('' + tk) + '</b></div><span class="pill ' + (/active/i.test(st) ? 'ok' : 'warn') + '"><span class="dot"></span>' + esc(st.toLowerCase()) + '</span>' +
      '<button class="btn ghost sm danger" data-act="disconnect">Disconnect</button></div>';
  }
  async function wireIntegrations() {
    var host = document.getElementById('int-body'); if (!host) return;
    var tools;
    try { tools = await capi('/tools'); }
    catch (err) {
      if (/not configured|composio|503/i.test(err.message)) { host.innerHTML = onboardComposio(); return; }
      host.innerHTML = '<div class="empty"><p>Couldn’t load integrations — ' + esc(err.message) + '</p></div>'; return;
    }
    var conns = listOf(await capi('/tools/connections').catch(function () { return null; }));
    var acs = listOf(await capi('/tools/auth_configs').catch(function () { return null; }));
    var toolkits = listOf(tools);
    // auth_config.toolkit is an object {slug, logo}; connection likewise
    var acBy = {}; acs.forEach(function (a) { var s = (a.toolkit && a.toolkit.slug) || a.toolkit_slug; if (s) acBy[('' + s).toLowerCase()] = a.id || a.uuid; });
    var connBy = {}; conns.forEach(function (c) { var s = (c.toolkit && c.toolkit.slug) || c.toolkit || c.appName; if (s) connBy[('' + s).toLowerCase()] = c; });
    // connected + connectable first
    var rank = function (t) { var s = tkSlug(t).toLowerCase(); return (connBy[s] ? 2 : 0) + (acBy[s] ? 1 : 0); };
    toolkits.sort(function (a, b) { return rank(b) - rank(a); });
    intState = { toolkits: toolkits, acBy: acBy, connBy: connBy, q: '' };

    host.innerHTML =
      (conns.length ? '<div class="eyebrow" style="margin:0 0 10px">Connected</div><div class="grid g3" style="margin-bottom:24px">' + conns.map(connCard).join('') + '</div>' : '') +
      '<div class="int-search"><input id="int-q" placeholder="Search ' + toolkits.length + ' integrations…" spellcheck="false" autocomplete="off"></div>' +
      '<div class="grid g3" id="int-grid"></div>' +
      '<div class="dim" id="int-more" style="text-align:center;margin-top:16px;font-size:12.5px"></div>';

    renderCatalog();
    var q = document.getElementById('int-q'), deb;
    q.addEventListener('input', function () { clearTimeout(deb); deb = setTimeout(function () { intState.q = q.value.trim(); renderCatalog(); }, 120); });
    host.addEventListener('click', onIntegrationAction);
  }
  function renderCatalog() {
    if (!intState) return;
    var grid = document.getElementById('int-grid'), more = document.getElementById('int-more'); if (!grid) return;
    var q = intState.q.toLowerCase();
    var matched = q ? intState.toolkits.filter(function (t) { return tkName(t).toLowerCase().indexOf(q) >= 0 || tkSlug(t).toLowerCase().indexOf(q) >= 0; }) : intState.toolkits;
    var CAP = 48, shown = matched.slice(0, CAP);
    grid.innerHTML = shown.map(function (t) {
      var slug = tkSlug(t).toLowerCase(), connected = !!intState.connBy[slug], connectable = !!intState.acBy[slug], logo = tkLogo(t);
      return '<div class="card int" data-slug="' + esc(tkSlug(t)) + '"><div class="int-top">' +
        (logo ? '<img class="int-logo" src="' + esc(logo) + '" alt="" loading="lazy">' : '<span class="int-logo">' + esc(tkName(t)[0].toUpperCase()) + '</span>') +
        '<b>' + esc(tkName(t)) + '</b></div>' +
        (connected ? '<span class="pill ok"><span class="dot"></span>connected</span>' :
          connectable ? '<button class="btn ghost sm" data-act="connect" data-ac="' + esc(intState.acBy[slug]) + '">Connect</button>' :
          '<span class="dim" style="font-size:12px">setup needed</span>') + '</div>';
    }).join('');
    more.textContent = matched.length > CAP ? 'Showing ' + CAP + ' of ' + matched.length + ' — refine your search' : (matched.length + ' integration' + (matched.length !== 1 ? 's' : ''));
  }

  async function onIntegrationAction(e) {
    var btn = e.target.closest('button[data-act]'); if (!btn) return;
    var act = btn.getAttribute('data-act');
    if (act === 'connect') {
      var ac = btn.getAttribute('data-ac'); btn.disabled = true;
      try {
        var r = await capi('/tools/connect', { method: 'POST', body: { auth_config_id: ac } });
        var url = r && (r.redirect_url || r.redirectUrl || (r.connection && r.connection.redirect_url));
        if (url) { window.open(url, '_blank', 'noopener'); toast('Finish the consent in the new tab, then refresh', 'ok'); }
        else { toast('Connection started', 'ok'); }
      } catch (err) { toast('Connect failed — ' + err.message, 'err'); } finally { btn.disabled = false; }
    } else if (act === 'disconnect') {
      var card = btn.closest('[data-conn]'), id = card && card.getAttribute('data-conn');
      if (!confirm('Disconnect this account?')) return;
      try { await capi('/tools/connection/' + encodeURIComponent(id), { method: 'DELETE' }); toast('Disconnected', 'ok'); wireIntegrations(); }
      catch (err) { toast('Disconnect failed — ' + err.message, 'err'); }
    }
  }

  // ---- Agents (workload): list from /api/platform/nexuses, lifecycle via /api/cloud/machine/* ----
  function agentsBody() {
    var deploy = canManage() ? '<button class="btn" id="ag-deploy" style="margin-bottom:16px">' + icon('rocket') + 'Deploy an agent</button>' : '';
    return deploy + '<div id="ag-list"><div class="center" style="min-height:120px"><div class="spin"></div></div></div>';
  }
  function wireAgents() {
    var d = document.getElementById('ag-deploy');
    if (d) d.addEventListener('click', async function () {
      d.disabled = true;
      try { await capi('/provision', { method: 'POST', body: {} }); toast('Deploying your agent…', 'ok'); loadAgents(); }
      catch (err) { toast(err.message, 'err'); } finally { d.disabled = false; }
    });
    document.getElementById('ag-list').addEventListener('click', onAgentAction);
    loadAgents();
  }
  async function loadAgents() {
    var host = document.getElementById('ag-list'); if (!host) return;
    try {
      var res = await api('/nexuses'); var list = (res && res.nexuses) || [];
      if (!list.length) {
        host.innerHTML = '<div class="empty"><div class="ic">' + icon('agents') + '</div><h2>No agents yet</h2>' +
          '<p>Deploy an agent and it runs always-on in your workspace — reachable from desktop, web, and (with a number) phone. Its usage meters against your credits.</p></div>';
        return;
      }
      host.innerHTML = '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr>' +
        '<th>Agent</th><th>Status</th><th>Region</th><th></th></tr></thead><tbody>' +
        list.map(function (n) {
          var st = (n.state || n.status || 'unknown') + '', running = /run|start|healthy|live|up/i.test(st), self = n.self === true;
          var acts = self ? '<span class="dim" style="font-size:12px">this workspace</span>' :
            (canManage() ? (running ? '<button class="btn ghost sm" data-act="suspend">Pause</button>' : '<button class="btn ghost sm" data-act="start">Wake</button>') +
              '<button class="btn ghost sm" data-act="roll">Roll</button><button class="btn ghost sm danger" data-act="kill">Delete</button>' : '');
          return '<tr data-id="' + esc(n.id) + '" data-name="' + esc(n.name || n.id) + '">' +
            '<td><div style="display:flex;align-items:center;gap:10px"><span class="av2" style="background:var(--mint)">' + icon('agents') + '</span>' +
              '<div><b>' + esc(n.name || n.id) + '</b>' + (n.plan ? '<div class="dim" style="font-size:12px">' + esc(n.plan) + '</div>' : '') + '</div></div></td>' +
            '<td><span class="pill ' + (running ? 'ok' : 'warn') + '"><span class="dot"></span>' + esc(st) + '</span></td>' +
            '<td class="dim">' + esc(n.region || '—') + '</td>' +
            '<td class="row-act">' + acts + '</td></tr>';
        }).join('') + '</tbody></table></div>';
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load agents — ' + esc(err.message) + '</p></div>'; }
  }
  async function onAgentAction(e) {
    var btn = e.target.closest('button[data-act]'); if (!btn) return;
    var tr = btn.closest('tr'), name = tr.getAttribute('data-name'), act = btn.getAttribute('data-act');
    var call = { start: ['/machine/start', 'POST'], suspend: ['/machine/suspend', 'POST'], roll: ['/machine/image', 'POST'], kill: ['/machine', 'DELETE'] }[act];
    if (!call) return;
    if (act === 'kill' && !confirm('Delete agent “' + name + '”? This tears down its machine.')) return;
    btn.disabled = true;
    try { await capi(call[0], { method: call[1], body: call[1] === 'POST' ? {} : undefined }); toast(({ start: 'Waking', suspend: 'Pausing', roll: 'Rolling', kill: 'Deleting' })[act] + ' ' + name + '…', 'ok'); loadAgents(); }
    catch (err) { toast(err.message, 'err'); } finally { btn.disabled = false; }
  }

  // ---- Data (surface): storage systems, split by the durable boundary ----
  var DATA_COLORS = { database: '#7fb3e0', repos: '#c4a8e8', cold_cache: '#8fd4ad', components: '#f0b48a', checkouts: '#e8cf8a', hot_cache: '#a8d4f0' };
  function donut(segs, size, sw) {
    size = size || 150; sw = sw || 22; var r = (size - sw) / 2, c = size / 2, C = 2 * Math.PI * r, off = 0;
    var total = segs.reduce(function (s, x) { return s + x.value; }, 0) || 1;
    var arcs = segs.map(function (s) {
      var len = (s.value / total) * C;
      var el = '<circle cx="' + c + '" cy="' + c + '" r="' + r + '" fill="none" stroke="' + s.color + '" stroke-width="' + sw + '" stroke-dasharray="' + len.toFixed(2) + ' ' + (C - len).toFixed(2) + '" stroke-dashoffset="' + (-off).toFixed(2) + '"/>';
      off += len; return el;
    }).join('');
    return '<svg class="donut" viewBox="0 0 ' + size + ' ' + size + '" width="' + size + '" height="' + size + '">' +
      '<circle cx="' + c + '" cy="' + c + '" r="' + r + '" fill="none" stroke="var(--line-2)" stroke-width="' + sw + '"/>' + arcs + '</svg>';
  }
  // DEMO DATA — a preview of the populated explorer (not wired to a real store yet). Clearly labelled.
  var DEMO_TABLES = {
    contacts: { cols: ['id', 'name', 'email', 'company', 'created_at'], rows: [
      ['c_1f4a', 'Ada Lovelace', 'ada@analytical.co', 'Analytical Engines', '2026-06-14'],
      ['c_2b8d', 'Alan Turing', 'alan@bombe.io', 'Bletchley', '2026-06-15'],
      ['c_3c1e', 'Grace Hopper', 'grace@cobol.mil', 'UNIVAC', '2026-06-18'],
      ['c_4d90', 'Katherine Johnson', 'kj@nasa.gov', 'NASA', '2026-06-21'],
      ['c_5a72', 'Margaret Hamilton', 'mh@apollo.io', 'MIT Draper', '2026-06-25'] ] },
    orders: { cols: ['id', 'customer', 'total', 'status', 'placed_at'], rows: [
      ['o_9001', 'Ada Lovelace', '$1,240.00', 'paid', '2026-06-28'],
      ['o_9002', 'Grace Hopper', '$2,400.00', 'paid', '2026-06-29'],
      ['o_9003', 'Alan Turing', '$540.00', 'pending', '2026-06-30'],
      ['o_9004', 'Katherine Johnson', '$60.00', 'refunded', '2026-07-01'],
      ['o_9005', 'Margaret Hamilton', '$380.00', 'pending', '2026-07-02'],
      ['o_9006', 'Ada Lovelace', '$540.00', 'paid', '2026-07-02'] ] },
    events: { cols: ['id', 'kind', 'actor', 'at'], rows: [
      ['e_5501', 'order.paid', 'agent', '2026-07-02 09:14'],
      ['e_5502', 'contact.created', 'you', '2026-07-02 09:20'],
      ['e_5503', 'integration.connected', 'you', '2026-07-02 10:03'],
      ['e_5504', 'order.refunded', 'agent', '2026-07-02 11:40'] ] }
  };
  var DEMO_SNIPPETS = [
    { name: 'Recent orders', sql: 'select id, customer, total, status\nfrom orders\norder by placed_at desc\nlimit 10;', result: 'orders' },
    { name: 'Revenue by status', sql: 'select status, count(*) as orders, sum(total) as revenue\nfrom orders\ngroup by status;', result: { cols: ['status', 'orders', 'revenue'], rows: [['paid', '3', '$4,180.00'], ['pending', '2', '$920.00'], ['refunded', '1', '$60.00']] } },
    { name: 'New contacts', sql: 'select name, company, created_at\nfrom contacts\norder by created_at desc\nlimit 10;', result: 'contacts' }
  ];
  var exTab = 'rows', exTable = 'contacts', exSnip = 0;
  var liveTables = null, liveRows = {}; // real store data (GET /data/tables, /data/tables/:name/rows)

  function modal(title, bodyHtml, footHtml) {
    var back = document.createElement('div'); back.className = 'modal-back';
    back.innerHTML = '<div class="modal-card"><div class="modal-h">' + esc(title) + '<button class="modal-x" aria-label="Close">×</button></div>' +
      '<div class="modal-b">' + bodyHtml + '</div>' + (footHtml ? '<div class="modal-f">' + footHtml + '</div>' : '') + '</div>';
    document.body.appendChild(back);
    function close() { back.remove(); document.removeEventListener('keydown', onKey); }
    function onKey(e) { if (e.key === 'Escape') close(); }
    back.addEventListener('click', function (e) { if (e.target === back || e.target.closest('.modal-x')) close(); });
    document.addEventListener('keydown', onKey);
    return { el: back, close: close };
  }
  var FIELD_TYPES = ['Text', 'Long text', 'Number', 'Date', 'Checkbox', 'Email', 'URL'];
  function createTableModal() {
    var fields = [{ name: 'name', type: 'Text' }];
    var m = modal('New table', '<div id="ct-body"></div>',
      '<button class="btn ghost" id="ct-cancel">Cancel</button><button class="btn" id="ct-create">Create table</button>');
    function draw() {
      m.el.querySelector('#ct-body').innerHTML =
        '<label class="fld-l">Table name</label><input id="ct-name" class="fld-i" placeholder="e.g. customers" autocomplete="off" spellcheck="false">' +
        '<label class="fld-l" style="margin-top:18px">Fields</label>' +
        '<div class="fld-note">Every table gets an <b>id</b> automatically — you don’t manage it.</div>' +
        '<div class="fld-list">' + fields.map(function (f, i) {
          return '<div class="fld-row"><input class="fld-i fld-name" data-i="' + i + '" value="' + esc(f.name) + '" placeholder="Field name" spellcheck="false">' +
            '<select class="fld-i fld-type" data-i="' + i + '">' + FIELD_TYPES.map(function (t) { return '<option' + (t === f.type ? ' selected' : '') + '>' + t + '</option>'; }).join('') + '</select>' +
            '<button class="fld-del" data-i="' + i + '" title="Remove field">×</button></div>';
        }).join('') + '</div><button class="lnk" id="ct-add">+ Add field</button>';
      m.el.querySelectorAll('.fld-name').forEach(function (el) { el.addEventListener('input', function () { fields[+el.dataset.i].name = el.value; }); });
      m.el.querySelectorAll('.fld-type').forEach(function (el) { el.addEventListener('change', function () { fields[+el.dataset.i].type = el.value; }); });
      m.el.querySelectorAll('.fld-del').forEach(function (el) { el.addEventListener('click', function () { fields.splice(+el.dataset.i, 1); if (!fields.length) fields.push({ name: '', type: 'Text' }); draw(); }); });
      m.el.querySelector('#ct-add').addEventListener('click', function () { fields.push({ name: '', type: 'Text' }); draw(); });
    }
    draw();
    m.el.querySelector('#ct-cancel').addEventListener('click', m.close);
    m.el.querySelector('#ct-create').addEventListener('click', function () {
      var name = (m.el.querySelector('#ct-name').value || '').trim().toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_|_$/g, '');
      if (!name) { toast('Give your table a name', 'err'); return; }
      var cols = ['id'].concat(fields.map(function (f) { return (f.name || '').trim(); }).filter(Boolean));
      DEMO_TABLES[name] = { cols: cols, rows: [], types: fields };
      exTable = name; toast('Table “' + name + '” created', 'ok'); m.close(); renderExTab();
    });
  }
  function addRowModal(table) {
    var d = DEMO_TABLES[table]; var editable = d.cols.filter(function (c) { return c !== 'id'; });
    var m = modal('Add row · ' + table,
      editable.map(function (c) { return '<label class="fld-l">' + esc(c) + '</label><input class="fld-i ar-f" data-c="' + esc(c) + '" autocomplete="off">'; }).join('') ||
        '<p class="dim">This table has no fields yet.</p>',
      '<button class="btn ghost" id="ar-cancel">Cancel</button><button class="btn" id="ar-save">Add row</button>');
    m.el.querySelector('#ar-cancel').addEventListener('click', m.close);
    m.el.querySelector('#ar-save').addEventListener('click', function () {
      var row = d.cols.map(function (c) {
        if (c === 'id') return (table[0] || 'r') + '_' + (Date.now ? '' : '') + Math.floor(1000 + Math.random() * 9000);
        var inp = m.el.querySelector('.ar-f[data-c="' + c + '"]'); return inp ? inp.value : '';
      });
      d.rows.push(row); toast('Row added', 'ok'); m.close(); renderExTab();
    });
  }

  function explorerBody() {
    return '<div class="explorer">' +
      '<aside class="ex-side"><div class="ex-sh" id="ex-side-h">Tables</div><div id="ex-side-body"></div></aside>' +
      '<div class="ex-main"><div class="ex-tabbar">' +
        '<button class="ex-tab on" data-tab="rows">Table editor</button>' +
        '<button class="ex-tab" data-tab="sql">SQL</button></div>' +
      '<div id="ex-panel"></div></div></div>';
  }
  function gridHtml(cols, rows) {
    return '<div class="grid-scroll"><table class="dgrid"><thead><tr>' + cols.map(function (c) { return '<th>' + esc(c) + '</th>'; }).join('') +
      '</tr></thead><tbody>' + rows.map(function (r) { return '<tr>' + r.map(function (v) { return '<td>' + esc(v) + '</td>'; }).join('') + '</tr>'; }).join('') +
      '</tbody></table></div>';
  }
  function wireExplorer() {
    renderExTab();
    document.querySelectorAll('.ex-tab').forEach(function (b) {
      b.addEventListener('click', function () {
        exTab = b.getAttribute('data-tab');
        document.querySelectorAll('.ex-tab').forEach(function (x) { x.classList.toggle('on', x === b); });
        renderExTab();
      });
    });
    document.getElementById('ex-side-body').addEventListener('click', function (e) {
      if (e.target.closest('#ex-newtable')) { createTableModal(); return; }
      var t = e.target.closest('[data-table]'), s = e.target.closest('[data-snip]');
      if (t) { exTable = t.getAttribute('data-table'); renderExTab(); }
      else if (s) { exSnip = +s.getAttribute('data-snip'); renderSql(); }
    });
    document.getElementById('ex-panel').addEventListener('click', function (e) {
      if (e.target.closest('#ex-run')) showResult(DEMO_SNIPPETS[exSnip].result);
      else if (e.target.closest('#ex-addrow')) addRowModal(exTable);
    });
  }
  function renderExTab() {
    var h = document.getElementById('ex-side-h'), side = document.getElementById('ex-side-body');
    if (exTab === 'sql') {
      h.textContent = 'Snippets';
      side.innerHTML = DEMO_SNIPPETS.map(function (s, i) { return '<a class="ex-item' + (i === exSnip ? ' on' : '') + '" data-snip="' + i + '">' + icon('usage') + '<span>' + esc(s.name) + '</span></a>'; }).join('') +
        '<a class="ex-item ex-new">+ New query</a>';
      renderSql();
    } else {
      h.textContent = 'Tables';
      // Live, per-org tables from the store (GET /data/tables → [{name, rows}]); rows are fetched on select.
      if (liveTables === null) { side.innerHTML = '<div class="ex-foot">Loading…</div>'; document.getElementById('ex-panel').innerHTML = ''; loadTables(); return; }
      if (!liveTables.length) {
        side.innerHTML = '<a class="ex-item ex-new" id="ex-newtable">+ New table</a>';
        document.getElementById('ex-panel').innerHTML = '<div class="ex-foot">No tables yet — a table is a <code>resource</code> declared in a workbook.</div>';
        return;
      }
      var names = liveTables.map(function (t) { return t.name; });
      if (names.indexOf(exTable) < 0) exTable = names[0];
      side.innerHTML = liveTables.map(function (t) {
        return '<a class="ex-item' + (t.name === exTable ? ' on' : '') + '" data-table="' + esc(t.name) + '"><span>' + esc(t.name) + '</span><span class="ex-count">' + t.rows + '</span></a>';
      }).join('') + '<a class="ex-item ex-new" id="ex-newtable">+ New table</a>';
      var rows = liveRows[exTable];
      if (rows === undefined) {
        document.getElementById('ex-panel').innerHTML = '<div class="ex-toolbar"><b>' + esc(exTable) + '</b></div><div class="ex-foot">Loading rows…</div>';
        loadRows(exTable); return;
      }
      var cols = rows.length ? Object.keys(rows[0]) : [];
      var rowArrays = rows.map(function (r) { return cols.map(function (c) { var v = r[c]; return (v && typeof v === 'object') ? JSON.stringify(v) : v; }); });
      document.getElementById('ex-panel').innerHTML =
        '<div class="ex-toolbar"><b>' + esc(exTable) + '</b><button class="btn ghost sm" id="ex-addrow">+ Add row</button></div>' +
        gridHtml(cols, rowArrays) +
        (rows.length ? '<div class="ex-foot">' + rows.length + ' row' + (rows.length === 1 ? '' : 's') + '</div>' : '<div class="ex-foot">Empty — add your first row.</div>');
    }
  }
  function loadTables() {
    api('/data/tables').then(function (r) { liveTables = (r && r.tables) || []; renderExTab(); })
      .catch(function () { liveTables = []; renderExTab(); });
  }
  function loadRows(name) {
    api('/data/tables/' + encodeURIComponent(name) + '/rows').then(function (r) { liveRows[name] = (r && r.rows) || []; renderExTab(); })
      .catch(function () { liveRows[name] = []; renderExTab(); });
  }
  function renderSql() {
    var s = DEMO_SNIPPETS[exSnip] || { sql: '' };
    document.querySelectorAll('#ex-side-body .ex-item').forEach(function (x, i) { x.classList.toggle('on', i === exSnip); });
    document.getElementById('ex-panel').innerHTML = '<div class="ex-sql"><textarea class="ex-editor" id="ex-ed" spellcheck="false" placeholder="SELECT …">' + esc(s.sql || '') + '</textarea>' +
      '<div class="ex-sqlbar"><button class="btn" id="ex-run">Run</button><span class="dim" style="font-size:12px">Read-only · your workspace · demo data</span></div>' +
      '<div id="ex-result"></div></div>';
    if (s.result) showResult(s.result);
  }
  function showResult(res) {
    var el = document.getElementById('ex-result'); if (!el) return;
    var d = typeof res === 'string' ? DEMO_TABLES[res] : res;
    el.innerHTML = gridHtml(d.cols, d.rows) + '<div class="ex-foot">' + d.rows.length + ' rows · demo</div>';
  }
  var TIER_LABEL = { durable: 'durable', ephemeral: 'ephemeral', memory: 'in memory' };
  var TIER_CLASS = { durable: 'ok', ephemeral: '', memory: '' };
  async function renderStorage(host) {
    if (!host) return;
    try {
      var d = await api('/data');
      var u = await api('/usage').catch(function () { return {}; });
      var store = await api('/storage').catch(function () { return {}; });
      var vol = d.volume || {}, st = u.storage || {}, systems = d.systems || [], buckets = (store && store.buckets) || [];

      var summary = '<div class="grid g3" style="margin-bottom:18px">' +
        stat('Volume used', esc(vol.used || '—'), st.limit ? 'of ' + esc(st.label || st.limit) : 'on disk') +
        stat('Durable', esc(vol.durable || '—'), 'survives restarts · .nexus') +
        stat('Ephemeral', esc(vol.ephemeral || '—'), 'rebuilt on boot') + '</div>';

      var boundary = '<div class="card note" style="margin-bottom:24px">' +
        '<div class="eyebrow">The durable boundary</div>' +
        '<p style="margin:8px 0 0;color:var(--dim);font-size:13.5px;line-height:1.6">Your data splits along one hard line. The <b style="color:var(--ink)">durable volume</b> (<span class="mono">.nexus</span>) survives restarts, redeploys, and machine replacement — your database, workspace history, and cold cache live here. Everything else is <b style="color:var(--ink)">ephemeral</b> — working copies and compiled artifacts, rebuilt on boot, so they never cost you persistent storage.</p></div>';

      var groups = [['durable', 'Durable — survives machine replacement'], ['ephemeral', 'Ephemeral — rebuilt on demand'], ['memory', 'In memory']];
      var systemsHtml = groups.map(function (g) {
        var inGroup = systems.filter(function (s) { return s.tier === g[0]; });
        if (!inGroup.length) return '';
        return '<div class="eyebrow" style="margin:0 0 10px">' + esc(g[1]) + '</div><div class="grid g2" style="margin-bottom:22px">' +
          inGroup.map(function (s) {
            return '<div class="card sys"><div class="sys-top"><b>' + esc(s.name) + '</b>' +
              '<span class="pill ' + (TIER_CLASS[s.tier] || '') + '">' + esc(TIER_LABEL[s.tier] || s.tier) + '</span></div>' +
              '<div class="sys-size">' + esc(s.size || '—') + '</div>' +
              '<p class="sys-role">' + esc(s.role || '') + '</p>' +
              '<code class="sys-path">' + esc(s.path || '') + '</code></div>';
          }).join('') + '</div>';
      }).join('');

      var bucketsHtml = buckets.length ? '<div class="eyebrow" style="margin:0 0 10px">Object storage — your apps’ files (the s3 data method)</div>' +
        '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr><th>Bucket</th><th>Objects</th><th>Size</th><th>Egress</th></tr></thead><tbody>' +
        buckets.map(function (b) {
          return '<tr><td class="mono">' + esc(b.name) + '</td><td class="tabular">' + (b.objects == null ? '—' : b.objects) + '</td>' +
            '<td class="tabular">' + esc(b.size || '—') + '</td><td class="tabular dim">' + esc(b.egress || '$0.00') + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '';

      var access = '<p class="dim" style="font-size:12px;margin:20px 0 0;line-height:1.6">Your code reaches all of this through one unified filesystem — the <b>VFS</b> — and the typed <b>Store</b> (SQLite, WAL-mode, Litestream-replicated to object storage). The systems above are simply where each read and write physically lands, hot to cold. Every byte is partitioned by tenant; one workspace can never read another’s.</p>';

      var sized = systems.filter(function (s) { return s.bytes && s.bytes > 0; });
      var segs = sized.map(function (s) { return { label: s.name, value: s.bytes, color: DATA_COLORS[s.key] || 'var(--dim-2)', size: s.size }; });
      var chart = '<div class="card chart-card" style="margin-bottom:22px">' +
        '<div class="donut-wrap">' + (segs.length ? donut(segs, 148, 22) : donut([{ value: 1, color: 'var(--line-2)' }], 148, 22)) +
          '<div class="donut-center"><b>' + esc(vol.used || '—') + '</b><span>used</span></div></div>' +
        '<div class="leg"><div class="eyebrow" style="margin-bottom:12px">Volume composition</div>' +
          (segs.length ? segs.map(function (s) {
            return '<div class="legrow"><span class="legdot" style="background:' + s.color + '"></span>' +
              '<span class="legname">' + esc(s.label) + '</span><span class="legval tabular">' + esc(s.size) + '</span></div>';
          }).join('') : '<p class="dim" style="font-size:13px">No stored data yet — this fills in as your agents and apps write.</p>') +
        '</div></div>';

      host.innerHTML = summary + chart + boundary + systemsHtml + bucketsHtml + access;
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load data systems — ' + esc(err.message) + '</p></div>'; }
  }

  async function startCheckout(plan) {
    try {
      var r = await api('/billing/checkout', { method: 'POST', body: { plan: plan } });
      if (r && r.url) { window.location.assign(r.url); return; }
      toast('Checkout is unavailable right now', 'err');
    } catch (err) { toast(err.message, 'err'); }
  }

  async function signOut() {
    try { await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }); } catch (e) {}
    location.assign('/login/');
  }

  boot();
})();
