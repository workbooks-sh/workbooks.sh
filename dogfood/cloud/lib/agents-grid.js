// agents-grid.js — the Studio sidebar's Apps-style grid of agents + workflows.
// Cards carry a color-coded DiceBear avatar (WB.avatar), a type badge (agent vs
// workflow) in the top-right, and a name. Clicking a card starts a new session
// with that agent (or opens the workflow editor). A filter funnel groups/sorts by
// type or color. Built on the shared WB.* surface (avatar, tabs, swr, click registry).
(function () {
  var WB = (window.WB = window.WB || {});
  function esc(s) { return (WB.esc || function (x) { return String(x); })(s); }

  // ── type badges (top-right corner of a card) ──
  var ICON = {
    agent: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="8" width="16" height="11" rx="3"/><path d="M12 8V5M12 5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3z"/><path d="M9.5 13.5h.01M14.5 13.5h.01"/></svg>',
    workflow: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="6" height="6" rx="1.5"/><rect x="15" y="15" width="6" height="6" rx="1.5"/><rect x="15" y="3" width="6" height="6" rx="1.5"/><path d="M6 9v4.6A2.4 2.4 0 0 0 8.4 16H15"/></svg>'
  };

  // ── per-surface filter state (persisted) ──
  function ls(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }
  var st = {
    filter: ls('wb-agentfilter', 'all'),  // all | agent | workflow
    view:   ls('wb-agentview', 'none'),   // none | type | color
    sort:   ls('wb-agentsort', 'name')    // name | color
  };
  function set(k, v) { st[k] = v; try { localStorage.setItem('wb-agent' + k, v); } catch (e) {} }

  // ── data: merge the live agent roster (or catalog fallback) + the workflow catalog ──
  function norm(o, type) {
    var name = o.name || o;
    return { type: type, name: name, label: o.label || name, color: WB.agentColor(type + ':' + name), seed: type + '-' + name };
  }
  function items() {
    var ags = (WB._agentRoster && WB._agentRoster.length) ? WB._agentRoster : (WB.AGENT_CATALOG || []);
    var out = ags.map(function (a) { return norm(a, 'agent'); });
    (WB.WORKFLOW_CATALOG || []).forEach(function (w) { out.push(norm(w, 'workflow')); });
    return out;
  }

  function colorIdx(c) { var i = (WB.AGCOLORS || []).indexOf(c); return i < 0 ? 99 : i; }
  function colorName(c) { return c.replace(/^--/, '').replace(/^./, function (m) { return m.toUpperCase(); }); }

  // ── rendering ──
  function card(it) {
    return '<a class="agcard" data-agentcard="' + esc(it.name) + '" data-agtype="' + it.type + '" href="#" title="' + esc(it.label) + '">' +
      '<span class="agtype agtype-' + it.type + '" title="' + (it.type === 'workflow' ? 'Workflow' : 'Agent') + '">' + ICON[it.type] + '</span>' +
      WB.avatar(it.seed, it.color, 40) +
      '<span class="agname">' + esc(it.label) + '</span></a>';
  }
  function grid(list) { return '<div class="appsgrid">' + list.map(card).join('') + '</div>'; }

  function renderInto(g) {
    var list = items().filter(function (it) { return st.filter === 'all' || it.type === st.filter; });
    list.sort(st.sort === 'color'
      ? function (a, b) { return colorIdx(a.color) - colorIdx(b.color) || a.label.localeCompare(b.label); }
      : function (a, b) { return a.label.localeCompare(b.label); });

    var grouped = st.view !== 'none';
    g.classList.toggle('grouped', grouped);
    if (!list.length) { g.innerHTML = '<div class="treemsg" style="padding:8px 4px">No ' + (st.filter !== 'all' ? st.filter + 's' : 'agents') + '</div>'; return; }
    // Flat: cards go straight into the container (it is itself .appsgrid). Grouped: container becomes a
    // block stack of [label + its own .appsgrid].
    if (!grouped) { g.innerHTML = list.map(card).join(''); return; }

    // group by type or color, keep a stable group order
    var groups = {}, order = [];
    list.forEach(function (it) {
      var k = st.view === 'type' ? it.type : it.color;
      if (!groups[k]) { groups[k] = []; order.push(k); }
      groups[k].push(it);
    });
    if (st.view === 'type') order.sort(function (a, b) { return a === 'agent' ? -1 : 1; });
    else order.sort(function (a, b) { return colorIdx(a) - colorIdx(b); });
    g.innerHTML = order.map(function (k) {
      var label = st.view === 'type' ? (k === 'agent' ? 'Agents' : 'Workflows') : colorName(k);
      return '<div class="sgrp">' + esc(label) + '</div>' + grid(groups[k]);
    }).join('');
  }

  // ── openers / actions ──
  function startAgent(name) {
    WB._pendingSession = null; WB._pendingAgent = name; WB._pendingWorkspace = null;
    if (WB.route && WB.route.path === '/studio' && WB._studioNew) WB._studioNew(null, name);
    else WB.nav('/studio');
  }
  var openerWired = false;
  function wireOpener() {
    if (openerWired || !WB.tabs) return; openerWired = true;
    // Re-opening a Studio session tab.
    WB.tabs.onOpen('studio', function (item) {
      WB._pendingSession = item.id; WB._pendingWorkspace = null;
      if (WB.route && WB.route.path === '/studio' && WB._studioOpen) WB._studioOpen(item.id);
      else WB.nav('/studio');
    });
  }

  WB.agentGrid = {
    items: items,
    filterActive: function () { return st.filter !== 'all' || st.view !== 'none' || st.sort !== 'name'; },
    filterMenu: function () {
      function opt(kind, val, label) {
        var cur = st[kind];
        return '<button class="filteropt' + (cur === val ? ' on' : '') + '" data-agent' + kind + '="' + val + '">' +
          '<span class="fopti"></span><span>' + esc(label) + '</span>' + (cur === val ? '<span class="fcheck">✓</span>' : '') + '</button>';
      }
      return '<div class="filtermenu" role="menu">' +
        '<div class="filterhd">Show</div>' + opt('filter', 'all', 'All') + opt('filter', 'agent', 'Agents') + opt('filter', 'workflow', 'Workflows') +
        '<div class="filterhd">Group</div>' + opt('view', 'none', 'Everything') + opt('view', 'type', 'By type') + opt('view', 'color', 'By color') +
        '<div class="filterhd">Sort</div>' + opt('sort', 'name', 'Name') + opt('sort', 'color', 'Color') +
        '</div>';
    },
    paint: function () {
      var g = document.getElementById('agentsGrid'); if (!g) return;
      ensureCss(); wireOpener();
      renderInto(g);   // instant (roster cache or catalog)
      if (WB.swr) WB.swr('agents-roster',
        function () { return fetch('/cloud/agents', { credentials: 'same-origin' }).then(function (r) { return r.json(); }); },
        function (d) { WB._agentRoster = (d && d.agents) || WB._agentRoster || []; var g2 = document.getElementById('agentsGrid'); if (g2) renderInto(g2); });
    }
  };

  // ── click registry ──
  WB._clicks = WB._clicks || [];
  WB._clicks.push({ sel: '[data-agentcard]', fn: function (el, e) {
    e.preventDefault();
    var name = el.getAttribute('data-agentcard'), type = el.getAttribute('data-agtype');
    if (type === 'workflow') WB.nav('/studio/workflow'); else startAgent(name);
    return true;
  } });
  function filterClick(kind) {
    return function (el, e) {
      e.preventDefault();
      set(kind, el.getAttribute('data-agent' + kind));
      if (WB.ui && WB.ui.closeFilter) WB.ui.closeFilter(); else WB.agentGrid.paint();
      return true;
    };
  }
  WB._clicks.push({ sel: '[data-agentfilter]', fn: filterClick('filter') });
  WB._clicks.push({ sel: '[data-agentview]',   fn: filterClick('view') });
  WB._clicks.push({ sel: '[data-agentsort]',   fn: filterClick('sort') });

  // ── CSS (lazy, once) ──
  var injected = false;
  function ensureCss() {
    if (injected) return; injected = true;
    var css = [
      '.agentsgrid.grouped { display:block; }',
      '.agcard { position:relative; display:flex; flex-direction:column; align-items:center; gap:8px; padding:14px 8px 11px; border:1px solid var(--line); border-radius:12px; background:var(--card); color:var(--ink); text-decoration:none; text-align:center; }',
      '.agcard:hover { border-color:var(--dim); background:color-mix(in srgb, var(--ink) 4%, var(--card)); }',
      '.agtype { position:absolute; top:6px; right:6px; display:grid; place-items:center; color:var(--dim); opacity:.65; }',
      '.agtype svg { width:13px; height:13px; }',
      '.agtype-workflow { color:var(--sky); opacity:.95; }',
      '.agtype-agent { color:var(--violet); opacity:.9; }',
      '.agname { font:500 11.5px var(--read, sans-serif); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:100%; }'
    ].join('\n');
    if (WB.styles) WB.styles(css);
    else { var s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); }
  }
})();
