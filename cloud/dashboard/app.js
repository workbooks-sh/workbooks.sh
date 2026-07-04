/* Workbooks Cloud dashboard — vanilla SPA (no framework, no build). Reads /api/platform like the CLI.
   Step 1: the shell + routing + empty surfaces. Data wiring lands per SPEC §8 steps 3–9. */
(function () {
  'use strict';
  var h = function (html) { var t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };

  async function api(path, opts) {
    opts = opts || {};
    var r = await fetch('/api/platform' + path, {
      method: opts.method || 'GET', credentials: 'same-origin',
      headers: opts.body ? { 'content-type': 'application/json' } : undefined,
      body: opts.body ? JSON.stringify(opts.body) : undefined
    });
    if (r.status === 401) { toLogin(); throw new Error('unauthorized'); }
    if (!r.ok) throw new Error((opts.method || 'GET') + ' /api/platform' + path + ' -> ' + r.status);
    var ct = r.headers.get('content-type') || '';
    return ct.indexOf('json') >= 0 ? r.json() : r.text();
  }
  function toLogin() {
    if (location.pathname.indexOf('/login') === 0) return;
    location.assign('/login/?next=' + encodeURIComponent(location.pathname + location.hash));
  }

  // ---- line icons (16/24 viewbox, stroke=currentColor) ----
  var IC = {
    overview: '<path d="M3 12l9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M9 20v-6h6v6"/>',
    usage: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
    integrations: '<path d="M6 3v6M18 3v6"/><rect x="4" y="9" width="16" height="5" rx="2"/><path d="M12 14v4a3 3 0 0 0 3 3"/>',
    channels: '<path d="M4 5a2 2 0 0 1 2-2h2l2 5-2 1a11 11 0 0 0 5 5l1-2 5 2v2a2 2 0 0 1-2 2A16 16 0 0 1 4 5z"/>',
    secrets: '<circle cx="8" cy="15" r="4"/><path d="M11 13l9-9 2 2M17 7l2 2"/>',
    team: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20a6 6 0 0 1 12 0"/><path d="M16 6a3 3 0 0 1 0 6M15 20a6 6 0 0 1 6-4"/>',
    billing: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M3 10h18"/>',
    domains: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    out: '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 12H3m0 0l3-3m-3 3l3 3"/>',
    rocket: '<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="M12 15l-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>'
  };
  var icon = function (k, cls) { return '<svg viewBox="0 0 24 24" ' + (cls ? 'class="' + cls + '" ' : '') + 'aria-hidden="true">' + (IC[k] || '') + '</svg>'; };

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

  // ---- the eight surfaces ----
  var NAV = [
    { id: 'overview', label: 'Overview', title: 'Overview', lede: 'Your autopoet at a glance — its status, this month’s usage, and anything that needs you.' },
    { id: 'usage', label: 'Usage', title: 'AI usage', lede: 'Every model call your autopoet makes, what it cost, and how much credit you have left.' },
    { id: 'integrations', label: 'Integrations', title: 'Integrations', lede: 'Connect the tools your autopoet acts through — Gmail, GitHub, Slack, and hundreds more.' },
    { id: 'channels', label: 'Channels', title: 'Channels', lede: 'Give your autopoet a phone number. Text it or call it from anywhere.' },
    { id: 'secrets', label: 'Secrets', title: 'Secrets', lede: 'Your API keys and credentials, encrypted at rest. Your autopoet uses them; no one else sees them.' },
    { id: 'team', label: 'Team', title: 'Team', lede: 'Who can see and manage this workspace.' },
    { id: 'billing', label: 'Billing', title: 'Billing', lede: 'Your plan, invoices, and payment method.' },
    { id: 'domains', label: 'Domains', title: 'Domains', lede: 'Point your own domain at your hosted autopoet.' }
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

  var BODY = { overview: overviewBody, secrets: secretsBody, team: teamBody, usage: usageBody, billing: billingBody };
  var WIRE = { overview: wireOverview, secrets: wireSecrets, team: wireTeam, usage: wireUsage, billing: wireBilling };
  function canManage() { return !!(me && (me.role === 'owner' || me.role === 'admin')); }
  function route() {
    var id = (location.hash.replace(/^#\/?/, '') || 'overview');
    if (!byId[id]) id = 'overview';
    var n = byId[id];
    document.querySelectorAll('.nav a').forEach(function (a) { a.classList.toggle('on', a.getAttribute('data-id') === id); });
    document.getElementById('top-title').textContent = n.title;
    var view = document.getElementById('view');
    view.innerHTML =
      '<div class="head"><div class="h-txt"><h2>' + esc(n.title) + '</h2><p>' + esc(n.lede) + '</p></div></div>' +
      (BODY[id] ? BODY[id]() : emptyBody(id));
    if (WIRE[id]) WIRE[id]();
  }

  function overviewBody() {
    return '' +
      '<div class="card" id="ap-card" style="margin-bottom:14px">' +
        '<div style="display:flex;align-items:center;gap:14px">' +
          '<div class="empty ic" style="width:44px;height:44px;padding:0;border:0;background:var(--line-2)">' + icon('rocket') + '</div>' +
          '<div style="flex:1"><div class="eyebrow">Your autopoet</div>' +
            '<div id="ap-status" style="margin-top:4px;display:flex;align-items:center;gap:10px">' +
              '<span class="pill"><span class="spin" style="width:12px;height:12px;border-width:2px"></span>checking…</span></div></div>' +
        '</div>' +
      '</div>' +
      '<div class="grid g3">' +
        stat('Usage this month', '&mdash;', 'compute + storage', 'ov-mtd') +
        stat('Team', '&mdash;', 'members', 'ov-team') +
        stat('Credit balance', '&mdash;', 'top up in Billing') +
      '</div>';
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
        el.innerHTML = '<span style="color:var(--dim);font-size:13px">No autopoet running yet.</span>' +
          '<button class="btn" style="margin-left:2px" disabled title="Wired in step 3">' + icon('rocket', '') + 'Provision</button>';
      }
    } catch (e) {
      el.innerHTML = '<span class="pill warn"><span class="dot"></span>status unavailable</span>';
    }
    // real local stats: month-to-date spend + team size
    api('/usage').then(function (u) { setText('ov-mtd', (u && u.monthToDate) || '$0.00'); }).catch(function () {});
    api('/members').then(function (r) { var n = (r && r.members || []).length; setText('ov-team', String(n) + (n === 1 ? ' member' : ' members')); }).catch(function () {});
  }

  function emptyBody(id) {
    var copy = {
      usage: 'Once your autopoet starts working, every model call, its cost, and your remaining credit show up here.',
      integrations: 'Browse the catalog and connect an account — your autopoet gains that tool the moment you link it.',
      channels: 'Provision a phone number and your autopoet can text and call. Toll-free verification runs here too.',
      secrets: 'Add a provider key or credential; it’s encrypted at rest and handed only to your autopoet at runtime.',
      team: 'Invite people and set roles. Everyone here shares this workspace’s autopoet, usage, and billing.',
      billing: 'Pick a plan, add a card, buy credits, and download invoices — all through our billing partner.',
      domains: 'Add a domain and point one CNAME at us; we issue the certificate and your autopoet answers on it.'
    };
    return '<div class="empty"><div class="ic">' + icon(id) + '</div>' +
      '<div class="soon">Wiring in progress</div>' +
      '<h2>' + esc(byId[id].title) + '</h2>' +
      '<p>' + esc(copy[id] || '') + '</p></div>';
  }

  // ---- Secrets (step 5): full CRUD over /api/platform/env ----
  var SCOPE_LABEL = { nexus: 'autopoet', user: 'you', workspace: 'workspace', package: 'package', org: 'org' };
  function secretsBody() {
    return '' +
      '<div class="card" style="margin-bottom:16px">' +
        '<form id="sec-add" class="sec-form" autocomplete="off">' +
          '<input id="sec-name" placeholder="NAME  ·  e.g. OPENAI_API_KEY" spellcheck="false" required>' +
          '<input id="sec-val" type="password" placeholder="value" autocomplete="new-password" required>' +
          '<select id="sec-scope" title="Who this secret is for">' +
            '<option value="nexus">your autopoet</option><option value="user">just you</option></select>' +
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
          '<h2>No secrets yet</h2><p>Add a provider key above — it’s encrypted at rest and handed only to your autopoet at runtime. No one else, including us, can read it back.</p></div>';
        return;
      }
      host.innerHTML = '<div class="card" style="padding:0;overflow:hidden"><table class="tbl"><thead><tr>' +
        '<th>Name</th><th>For</th><th>Value</th><th></th></tr></thead><tbody>' +
        list.map(function (s) {
          return '<tr data-id="' + esc(s.id) + '" data-name="' + esc(s.name) + '">' +
            '<td class="mono">' + esc(s.name) + '</td>' +
            '<td><span class="pill">' + esc(SCOPE_LABEL[s.scope] || s.scope || 'autopoet') + '</span></td>' +
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
      if (!confirm('Delete “' + name + '”? Your autopoet will lose access to it.')) return;
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
      host.innerHTML =
        '<div class="grid g3" style="margin-bottom:14px">' +
          stat('Month to date', esc(u.monthToDate || '$0.00'), 'compute + storage') +
          stat('Compute', esc(u.compute || '$0.00'), (u.activeHrs || 0) + ' active hours') +
          stat('Plan', esc((u.tier && u.tier.name) || '—'), (u.tier && u.tier.price) || '') +
        '</div>' +
        '<div class="grid g2" style="margin-bottom:26px">' + gauge('Memory', u.ram) + gauge('Storage', u.storage) + '</div>' +
        '<div class="eyebrow" style="margin:0 0 10px">AI usage</div>' +
        '<div class="empty"><div class="ic">' + icon('usage') + '</div><div class="soon">Wiring in progress</div>' +
        '<h2>Token &amp; credit metering</h2><p>Per-model spend, your credit balance, and monthly caps land here next — the Cloudflare-gateway migration (SPEC step 4).</p></div>';
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load usage — ' + esc(err.message) + '</p></div>'; }
  }

  // ---- Billing (surface 2.7): the tier ladder now; checkout/invoices need Polar (via Secrets) ----
  function billingBody() { return '<div id="bill-body"><div class="center" style="min-height:160px"><div class="spin"></div></div></div>'; }
  async function wireBilling() {
    var host = document.getElementById('bill-body');
    try {
      var res = await api('/tiers'); var tiers = (res && res.tiers) || [];
      var u = await api('/usage').catch(function () { return {}; });
      var curId = (u.tier && u.tier.id) || 'default';
      host.innerHTML =
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
      host.addEventListener('click', function (e) {
        if (e.target.closest('button[data-plan]')) toast('Checkout needs billing connected — add POLAR_ACCESS_TOKEN in Secrets', 'err');
      });
    } catch (err) { host.innerHTML = '<div class="empty"><p>Couldn’t load plans — ' + esc(err.message) + '</p></div>'; }
  }

  async function signOut() {
    try { await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }); } catch (e) {}
    location.assign('/login/');
  }

  boot();
})();
