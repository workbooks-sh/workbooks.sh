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

  function route() {
    var id = (location.hash.replace(/^#\/?/, '') || 'overview');
    if (!byId[id]) id = 'overview';
    var n = byId[id];
    document.querySelectorAll('.nav a').forEach(function (a) { a.classList.toggle('on', a.getAttribute('data-id') === id); });
    document.getElementById('top-title').textContent = n.title;
    var view = document.getElementById('view');
    view.innerHTML =
      '<div class="head"><div class="h-txt"><h2>' + esc(n.title) + '</h2><p>' + esc(n.lede) + '</p></div></div>' +
      (id === 'overview' ? overviewBody() : emptyBody(id));
    if (id === 'overview') wireOverview();
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
        stat('Credit balance', '&mdash;', 'top up in Billing') +
        stat('Usage this month', '&mdash;', 'see Usage') +
        stat('Connected tools', '&mdash;', 'add in Integrations') +
      '</div>';
  }
  function stat(k, n, sub) {
    return '<div class="card stat"><div class="eyebrow">' + esc(k) + '</div>' +
      '<div class="n">' + n + '</div><div class="k">' + esc(sub) + '</div></div>';
  }

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

  async function signOut() {
    try { await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }); } catch (e) {}
    location.assign('/login/');
  }

  boot();
})();
