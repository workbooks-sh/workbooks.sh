  // ═══════════════════════ WB runtime — ports api.js + the stores + helpers ═══════════════════════
  (function () {
    var WB = (window.WB = window.WB || {});
    WB._views = {};
    WB._params = {};
    WB.view = function (route, def) { WB._views[route] = def; };
    WB.styles = function (css) { var s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); };
    // Svelte scopes each component's <style>; our ports inject globally, so a view that redefines a
    // shared class (.card/.row/.bar/.tag/.sub/.body) would bleed into every view. scopeCss restores
    // that scoping: every selector is prefixed with the view's mount scope. @keyframes/@font-face stay
    // global (names are global anyway); @media/@supports recurse. Modals use the GLOBAL design-block
    // classes (.modal/.sheet) so they're unaffected.
    function scopeCss(css, sel) {
      css = css.replace(/\/\*[\s\S]*?\*\//g, '');
      var out = '', i = 0, n = css.length;
      while (i < n) {
        var b = css.indexOf('{', i);
        if (b === -1) { out += css.slice(i); break; }
        var header = css.slice(i, b).trim();
        var depth = 1, j = b + 1;
        while (j < n && depth > 0) { var ch = css[j]; if (ch === '{') depth++; else if (ch === '}') depth--; j++; }
        var body = css.slice(b + 1, j - 1);
        if (/^@(keyframes|font-face|import|page|charset)/.test(header)) {
          out += header + '{' + body + '}\n';
        } else if (/^@(media|supports|container|layer)/.test(header)) {
          out += header + '{' + scopeCss(body, sel) + '}\n';
        } else {
          out += header.split(',').map(function (s) { s = s.trim(); return s ? sel + ' ' + s : s; }).filter(Boolean).join(', ') + '{' + body + '}\n';
        }
        i = j;
      }
      return out;
    }
    WB.scopedStyles = function (scope, css) { WB.styles(scopeCss(css, '[data-view="' + scope + '"]')); };
    function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];}); }
    WB.esc = esc;

    // ── api.js port ───────────────────────────────────────────────────────────────────────────
    var RUNTIME = '';                       // collab calls (history/drafts/shared) are mock until wired
    function live(){ return RUNTIME !== ''; }
    async function plat(path, opts){ opts = opts || {};
      var res = await fetch('/api/platform' + path, {
        method: opts.method || 'GET',
        headers: opts.body ? { 'content-type': 'application/json' } : {},
        body: opts.body && JSON.stringify(opts.body),
        credentials: 'same-origin'
      });
      if (res.status === 401) { location.assign('/login/'); throw new Error('unauthorized'); }
      if (!res.ok) throw new Error((opts.method||'GET') + ' /api/platform' + path + ' → ' + res.status);
      return res.status === 204 ? null : res.json();
    }
    async function rt(path, opts){ opts = opts || {};
      var res = await fetch(path, { method: opts.method || 'GET',
        headers: { 'content-type': 'application/json' }, body: opts.body && JSON.stringify(opts.body), credentials: 'same-origin' });
      if (!res.ok) throw new Error((opts.method||'GET') + ' ' + path + ' → ' + res.status);
      return res.status === 204 ? null : res.json();
    }
    var STATE_LABEL = { run: 'Active', sleep: 'Idle', build: 'Starting', pause: 'Paused' };
    var SUB_FOR = { run: 'active', sleep: 'sleeping', build: 'building · weaving…', pause: 'paused' };
    var withSub = function (n) { return Object.assign({}, n, { sub: n.sub || SUB_FOR[n.state] || '' }); };

    var api = WB.api = {
      live: live, STATE_LABEL: STATE_LABEL,
      async listNexuses(){ try { return (await plat('/nexuses')).nexuses.map(withSub); } catch (e) { return []; } },
      async getNexus(id){ try {
        var nexus = withSub(await plat('/nexuses/' + id)); var row;
        try { row = (await plat('/usage')).rows.find(function(r){ return r.name === id; }); } catch (e) {}
        var config = { region: nexus.region, plan: nexus.plan,
          status: nexus.state === 'run' ? 'Active' : nexus.state === 'sleep' ? 'Idle' : 'Starting',
          storage: (row && row.storage) || '—', database: (row && row.database) || 'none', created: '—' };
        var month = { activeCompute: row ? (row.activeHrs + ' hrs') : '0.0 hrs', sleeping: '—',
          storage: (row && row.storage) || '—', egress: '$0.00', subtotal: (row && row.cost) || '$0.00' };
        var metrics = { cpu: 0, memMb: 0, memCapGb: 1, reqMin: 0, costMonth: ((row && row.cost) || '$0').replace(/[$,]/g, '') };
        return { nexus: nexus, config: config, month: month, metrics: metrics };
      } catch (e) { return null; } },
      async createNexus(opts){ return withSub(await plat('/nexuses', { method: 'POST', body: { name: opts.name, region: opts.region, plan: opts.plan, database: opts.database } })); },
      deleteNexus(id){ return plat('/nexuses/' + id, { method: 'DELETE' }); },
      renameNexus(id, name){ return plat('/nexuses/' + id, { method: 'PATCH', body: { name: name } }); },
      wakeNexus(id){ return plat('/nexuses/' + id + '/wake', { method: 'POST' }); },
      sleepNexus(id){ return plat('/nexuses/' + id + '/sleep', { method: 'POST' }); },
      mintToken(name){ return plat('/tokens/mint', { method: 'POST', body: { name: name || 'cli' } }); },
      async listTokens(){ try { return (await plat('/tokens')).tokens || []; } catch (e) { return []; } },
      revokeToken(id){ return plat('/tokens/' + id, { method: 'DELETE' }); },
      async listDomains(){ try { return (await plat('/domains')).domains || []; } catch (e) { return []; } },
      addDomain(host){ return plat('/domains', { method: 'POST', body: { host: host } }); },
      verifyDomain(id){ return plat('/domains/' + id + '/verify', { method: 'POST' }); },
      removeDomain(id){ return plat('/domains/' + id, { method: 'DELETE' }); },
      async listTiers(){ try { return (await plat('/tiers')).tiers || []; } catch (e) { return []; } },
      getUpsell(org, opts){ opts = opts || {}; var q = new URLSearchParams();
        if (org) q.set('org', org); if (opts.personalize === false) q.set('personalize', '0');
        return plat('/upsell' + (q.toString() ? '?' + q : '')); },
      async nexusUsage(){ try { var c = await plat('/usage');
        if (c && c.ram) { return { summary: { monthToDate: c.monthToDate, compute: c.compute, storage: c.storage.label,
          database: '—', nexusCount: 1, activeHrs: String(c.activeHrs), load: c.load },
          period: 'current cycle · billed on the 1st', rows: [], capacity: c }; }
        return c; } catch (e) { return { summary: { monthToDate: '$0.00', compute: '$0.00', storage: '0 GB',
          database: '—', nexusCount: 0, activeHrs: '0.0', load: 0 }, period: 'current cycle · billed on the 1st', rows: [] }; } },
      async listBuckets(){ try { return await plat('/storage'); } catch (e) { return { buckets: [], totalSize: '0 GB' }; } },
      async listWorkspaces(){ try { return (await plat('/workspaces')).workspaces; } catch (e) { return []; } },
      createWorkspace(name, opts){ opts = opts || {}; return plat('/workspaces', { method: 'POST', body: { name: name, icon: opts.icon, nexus_id: opts.nexus_id } }); },
      updateWorkspace(id, attrs){ return plat('/workspaces/' + id, { method: 'PATCH', body: attrs }); },
      renameWorkspace(id, name){ return api.updateWorkspace(id, { name: name }); },
      deleteWorkspace(id){ return plat('/workspaces/' + id, { method: 'DELETE' }); },
      async listEnv(workspace){ try { return (await plat('/env?workspace=' + encodeURIComponent(workspace))).env; } catch (e) { return []; } },
      createEnv(workspace, o){ return plat('/env', { method: 'POST', body: { name: o.name, value: o.value, scope: 'workspace', workspace_id: workspace } }); },
      async revealEnv(id){ return (await plat('/env/' + id + '/reveal')).value; },
      updateEnv(id, attrs){ return plat('/env/' + id, { method: 'PATCH', body: attrs }); },
      deleteEnv(id){ return plat('/env/' + id, { method: 'DELETE' }); },
      async nexusHistory(scope){ if (live()) return (await rt('/api/history/' + scope)).map(normChange); return []; },
      async changeDiff(scope, id){ if (live()) return rt('/api/history/' + scope + '/' + id + '/diff'); return { before: '', after: '' }; },
      async restoreVersion(scope, id, when){ if (live()) { var r = await rt('/api/history/' + scope + '/restore', { method: 'POST', body: { to: id } }); return r.unchanged ? null : normChange(r); } return { id: 'r' + id, when: when, authorType: 'human', authorName: 'You', title: 'Restored an earlier version' }; },
      async undoLast(scope, when){ if (live()) { var r = await rt('/api/history/' + scope + '/undo', { method: 'POST' }); return r.nothing ? null : normChange(r); } return null; },
      async sharedFolders(){ if (live()) return rt('/api/shared-folders'); return { shareable: [], shared_by: [], shared_with: [] }; },
      async shareFolder(o){ if (live()) return rt('/api/shared-folders/share', { method: 'POST', body: { folder: o.folder, recipient: o.recipient, mode: o.mode || 'read' } }); return { id: 'g', owner: 'you', folder: o.folder, recipient: o.recipient, mode: o.mode || 'read' }; },
      async addSharedFolder(id){ if (live()) return rt('/api/shared-folders/' + id + '/add', { method: 'POST' }); return { folder: 'folder', files: [] }; },
      async revokeShare(id){ if (live()) return rt('/api/shared-folders/' + id + '/revoke', { method: 'POST' }); return { ok: true, id: id }; },
      async listDrafts(nexus){ if (live()) return rt('/api/nexuses/' + nexus + '/drafts'); return []; },
      async createDraft(nexus, name){ if (live()) return rt('/api/nexuses/' + nexus + '/drafts', { method: 'POST', body: { name: name } }); return { name: name, files_changed: 0, preview_path: '.drafts/' + name, changes: [] }; },
      async draftDiff(nexus, name){ if (live()) return rt('/api/nexuses/' + nexus + '/drafts/' + name + '/diff'); return []; },
      async keepDraft(nexus, name){ if (live()) return rt('/api/nexuses/' + nexus + '/drafts/' + name + '/keep', { method: 'POST' }); return { merged: name }; },
      async discardDraft(nexus, name){ if (live()) return rt('/api/nexuses/' + nexus + '/drafts/' + name + '/discard', { method: 'POST' }); return { ok: true, name: name }; }
    };
    function normChange(c){ return { id: c.id, when: c.when, authorType: c.author_type || c.authorType, authorName: c.author_name || c.authorName, title: c.title }; }

    // ── nexusStore port ─────────────────────────────────────────────────────────────────────────
    var NX_LS = 'wb-active-nexus', _nx = [], _nxLoaded = false, _nxActive = null, _query = '';
    var SUB = { run: 'active', sleep: 'sleeping', build: 'building · weaving…', pause: 'paused' };
    WB.nexus = {
      get all(){ return _nx; }, list(){ return _nx; }, get loaded(){ return _nxLoaded; },
      async load(force){ if (_nxLoaded && !force) return _nx; _nx = await api.listNexuses(); _nxLoaded = true;
        var saved = null; try { saved = localStorage.getItem(NX_LS); } catch (e) {}
        _nxActive = (saved && _nx.some(function(n){ return n.id === saved; })) ? saved : ((_nx[0] && _nx[0].id) || null); return _nx; },
      get active(){ return _nx.find(function(n){ return n.id === _nxActive; }) || _nx[0] || null; },
      setActive(id){ _nxActive = id; try { localStorage.setItem(NX_LS, id); } catch (e) {} },
      get filtered(){ var q = _query.trim().toLowerCase(); if (!q) return _nx;
        return _nx.filter(function(n){ return n.name.toLowerCase().indexOf(q) >= 0 || n.url.toLowerCase().indexOf(q) >= 0 || (n.region || '').toLowerCase().indexOf(q) >= 0; }); },
      get(id){ return _nx.find(function(n){ return n.id === id; }) || null; },
      detail(id){ var nexus = this.get(id); if (!nexus) return null;
        var config = { region: nexus.region || '—', plan: nexus.plan || '—',
          status: nexus.state === 'run' ? 'Active' : nexus.state === 'sleep' ? 'Idle' : 'Starting', storage: '—', database: 'none', created: '—' };
        var month = { activeCompute: '0.0 hrs', sleeping: '—', storage: '—', egress: '$0.00', subtotal: '$0.00' };
        var metrics = { cpu: 0, memMb: 0, memCapGb: 1, reqMin: 0, costMonth: '0.00' };
        return { nexus: nexus, config: config, month: month, metrics: metrics }; },
      async provision(o){ o = o || {}; var nexus = await api.createNexus({ name: o.name, region: o.region, plan: o.plan, database: o.database }); _nx = [nexus].concat(_nx); this.setActive(nexus.id); return nexus; },
      async remove(id){ _nx = _nx.filter(function(n){ return n.id !== id; }); try { await api.deleteNexus(id); } catch (e) {} },
      async rename(id, name){ var n = name.trim(); if (!n) return; _nx = _nx.map(function(x){ return x.id === id ? Object.assign({}, x, { name: n }) : x; }); await api.renameNexus(id, n); },
      async setState(id, state){ _nx = _nx.map(function(n){ return n.id === id ? Object.assign({}, n, { state: state, sub: SUB[state] || n.sub }) : n; });
        try { if (state === 'run') await api.wakeNexus(id); else if (state === 'sleep') await api.sleepNexus(id); } catch (e) {} },
      get query(){ return _query; }, set query(v){ _query = v; }
    };

    // ── workspaceStore port ─────────────────────────────────────────────────────────────────────
    var WS_LS = 'wb-active-workspace', _ws = [], _wsActive = null, _wsLoaded = false;
    WB.ws = {
      get list(){ return _ws; }, get loaded(){ return _wsLoaded; },
      get active(){ return _ws.find(function(w){ return w.id === _wsActive; }) || _ws[0] || null; },
      async load(defaultName, force){ if (_wsLoaded && !force) return; var l = await api.listWorkspaces();
        if (l.length === 0 && defaultName) { try { l = [await api.createWorkspace(defaultName)]; } catch (e) { l = []; } }
        _ws = l; var saved = null; try { saved = localStorage.getItem(WS_LS); } catch (e) {}
        _wsActive = (saved && l.some(function(w){ return w.id === saved; })) ? saved : ((l[0] && l[0].id) || null); _wsLoaded = true; },
      setActive(id){ _wsActive = id; try { localStorage.setItem(WS_LS, id); } catch (e) {} },
      async create(name, icon){ var ws = await api.createWorkspace(name, { icon: icon || '' }); _ws = _ws.concat([ws]); this.setActive(ws.id); return ws; },
      async update(id, attrs){ var ws = await api.updateWorkspace(id, attrs); _ws = _ws.map(function(w){ return w.id === id ? ws : w; }); return ws; },
      async remove(id){ if (_ws.length <= 1) return false; _ws = _ws.filter(function(w){ return w.id !== id; });
        if (_wsActive === id) this.setActive(_ws[0] && _ws[0].id); try { await api.deleteWorkspace(id); } catch (e) {} return true; }
    };

    // ── toast ───────────────────────────────────────────────────────────────────────────────────
    var toastSeq = 0;
    WB.toast = function (msg, kind, ms) { kind = kind || 'ok'; ms = ms === undefined ? 3000 : ms;
      var id = ++toastSeq, host = document.getElementById('toasts');
      var el = document.createElement('div'); el.className = 'toast ' + kind; el.setAttribute('role', 'status');
      el.innerHTML = '<span class="dot ' + (kind === 'bad' ? 'pause' : 'run') + '"></span><span>' + esc(msg) + '</span>';
      el.onclick = function () { el.remove(); }; host.appendChild(el);
      if (ms) setTimeout(function () { el.remove(); }, ms); return id; };

    // ── DnaStrip port ─────────────────────────────────────────────────────────────────────────
    WB.dna = function (seed, height) { seed = seed == null ? 13 : seed; height = height == null ? 12 : height;
      var MIX = [['#f3c5a3', 0.30], ['#aee5c2', 0.24], ['#a8d4f0', 0.20], ['#9fc4e8', 0.14], ['#f2ddb0', 0.12]];
      var out = [], k = seed, i, j, r;
      for (var m = 0; m < MIX.length; m++) { var c = MIX[m][0], f = MIX[m][1]; var n = f > 0.3 ? 3 : f > 0.12 ? 2 : 1;
        for (j = 0; j < n; j++) out.push([c, f / n]); }
      for (i = out.length - 1; i > 0; i--) { k++; r = (((Math.sin(k * 127.1) * 43758.5453) % 1) + 1) % 1; j = Math.floor(r * (i + 1)); var t = out[i]; out[i] = out[j]; out[j] = t; }
      var loop = out.concat(out), bars = loop.map(function (b) { return '<i style="width:' + (b[1] * 50).toFixed(2) + '%;background:' + b[0] + '"></i>'; }).join('');
      return '<div class="dna" style="--h:' + height + 'px" aria-hidden="true"><div class="track">' + bars + '</div></div>'; };

    // ── Sparkline port ────────────────────────────────────────────────────────────────────────
    WB.spark = function (seed) { seed = seed || 1; var x = 0, pts = [];
      for (var i = 0; i < 14; i++) { var v = 8 + Math.abs(Math.sin(seed + i * 0.7)) * 18; pts.push([x, 28 - v]); x += 6; }
      var d = pts.map(function (q, i) { return (i ? 'L' : 'M') + q[0] + ' ' + q[1].toFixed(1); }).join(' ');
      return '<svg class="spark" viewBox="0 0 84 30" preserveAspectRatio="none"><path d="' + d + '" fill="none" stroke="var(--live)" stroke-width="1.5" opacity=".8" /></svg>'; };

    // ── EmojiPicker port ──────────────────────────────────────────────────────────────────────
    WB.emojiPicker = function (host, onpick) { host.innerHTML = '<p class="loading">Loading emoji picker…</p>';
      import('https://cdn.jsdelivr.net/npm/emoji-picker-element@1/index.js').then(function () { host.innerHTML = '';
        var picker = document.createElement('emoji-picker'); picker.classList.add('wb-emoji-picker');
        picker.addEventListener('emoji-click', function (e) { var u = e.detail && e.detail.unicode; if (u) onpick(u); }); host.appendChild(picker);
      }).catch(function () { host.innerHTML = '<p class="loading">Emoji picker unavailable</p>'; }); };

    // ── Confirm port ──────────────────────────────────────────────────────────────────────────
    WB.confirm = function (o) { o = o || {}; return new Promise(function (resolve) {
      var modal = document.createElement('div'); modal.className = 'modal';
      modal.innerHTML = '<div class="sheet" style="width:420px"><h2>' + esc(o.title || 'Are you sure?') + '</h2>' +
        '<p class="sub">' + esc(o.body || '') + '</p><div class="foot"><span></span><div style="display:flex;gap:8px">' +
        '<button class="btn" data-x="0">Cancel</button><button class="btn ' + (o.danger ? 'danger' : 'primary') + '" data-x="1">' + esc(o.confirm || 'Confirm') + '</button></div></div></div>';
      function done(v){ modal.remove(); resolve(v); }
      modal.addEventListener('click', function (e) { if (e.target === modal) done(false);
        var x = e.target.closest('[data-x]'); if (x) done(x.getAttribute('data-x') === '1'); });
      document.body.appendChild(modal); }); };

    // ── identity ──────────────────────────────────────────────────────────────────────────────
    WB.user = { name: 'Account', email: '', initial: 'A' };
    WB.profile = {};
    // Dev flag — gates in-development surfaces (Create / Apps) so they stay DARK for everyone by
    // default. Flip per-browser with ?dev=1 (and ?dev=0 to clear); persisted in localStorage. "Just
    // for us in development" — no deploy/runtime change, customers never see it until we promote it.
    WB.dev = (function () { try { var q = new URLSearchParams(location.search);
      if (q.get('dev') === '1') localStorage.setItem('wb-dev', '1');
      else if (q.get('dev') === '0') localStorage.removeItem('wb-dev');
      return localStorage.getItem('wb-dev') === '1'; } catch (e) { return false; } })();
    async function loadIdentity(){ try { var me = await plat('/me');
      var u = me.user || {}; var name = u.name || (u.email ? u.email.split('@')[0] : '') || 'Account';
      WB.user = { name: name, email: u.email || '', initial: (name[0] || 'A').toUpperCase() };
      WB.profile = me.profile || {}; if (!WB.profile.orgName && me.active_org) WB.profile.orgName = me.profile && me.profile.orgName;
    } catch (e) {} }

    // ── router + shell ──────────────────────────────────────────────────────────────────────────
    var ROUTE = { path: '/', params: {} };
    WB.route = ROUTE;
    WB.nav = function (path) {
      if (path.charAt(0) !== '/') path = '/' + path;
      var target = '#' + path;
      // Already on this route (e.g. switching workspaces while on /workspace): the hash doesn't change
      // so no `hashchange` fires — re-render manually so the view rebuilds for the new active state.
      if (location.hash === target) route();
      else location.hash = target;
    };

    // ── Command palette (⌘K) — search files + workspaces + jump to nav. Replaces the in-sidebar search. ──
    var NAV_CMDS = [
      { label: 'New chat', icon: '+', go: '/studio' },
      { label: 'Activity', icon: '∿', go: '/activity' },
      { label: 'Workspaces', icon: '▦', go: '/workspaces' },
      { label: 'Usage & billing', icon: '◷', go: '/usage' },
      { label: 'Storage', icon: '▤', go: '/storage' },
      { label: 'Team', icon: '👥', go: '/team' },
      { label: 'Secrets', icon: '🔑', go: '/secrets' },
      { label: 'Settings', icon: '⚙', go: '/settings' }
    ];
    WB.palette = function () {
      if (document.getElementById('wbPalette')) return;
      var ov = document.createElement('div'); ov.id = 'wbPalette'; ov.className = 'palette-ov';
      ov.innerHTML = '<div class="palette"><input class="palette-in" placeholder="Search files, workspaces, commands…" autocomplete="off" /><div class="palette-res"></div></div>';
      document.body.appendChild(ov);
      var input = ov.querySelector('.palette-in'), res = ov.querySelector('.palette-res');
      var items = [], sel = 0;
      function close(){ ov.remove(); }
      function go(it){ close(); if (it.go) WB.nav(it.go); else if (it.ws) { WB.ws.setActive(it.ws); WB.nav('/workspaces'); } else if (it.file) WB.nav('/workspaces'); }
      function render(){
        res.innerHTML = items.length ? items.map(function(it, i){
          return '<div class="palette-item' + (i === sel ? ' on' : '') + '" data-i="' + i + '"><span class="palette-ic">' + esc(it.icon || '›') + '</span><span class="palette-lb">' + esc(it.label) + '</span>' + (it.sub ? '<span class="palette-sub">' + esc(it.sub) + '</span>' : '') + '</div>';
        }).join('') : '<div class="palette-empty">No matches</div>';
        res.querySelectorAll('[data-i]').forEach(function(el){ el.onclick = function(){ go(items[+el.getAttribute('data-i')]); }; });
      }
      function refresh(){
        var q = input.value.trim().toLowerCase();
        var navm = NAV_CMDS.filter(function(c){ return !q || c.label.toLowerCase().indexOf(q) >= 0; });
        var wsm = (WB.ws.list || []).filter(function(w){ return !q || w.name.toLowerCase().indexOf(q) >= 0; })
          .map(function(w){ return { icon: w.icon || '▦', label: w.name, sub: 'workspace', ws: w.id }; });
        items = navm.concat(wsm); sel = 0; render();
        if (q) fetch('/cloud/search?q=' + encodeURIComponent(q), { credentials: 'same-origin' })
          .then(function(r){ return r.json(); }).then(function(d){
            if (input.value.trim().toLowerCase() !== q) return;
            var files = ((d && d.results) || []).slice(0, 12).map(function(f){ return { icon: '📄', label: f.name, sub: f.workspace, file: f.path }; });
            items = navm.concat(wsm, files); render();
          });
      }
      input.addEventListener('input', refresh);
      input.addEventListener('keydown', function(e){
        if (e.key === 'Escape') return close();
        if (e.key === 'ArrowDown') { sel = Math.min(sel + 1, items.length - 1); render(); e.preventDefault(); }
        if (e.key === 'ArrowUp') { sel = Math.max(sel - 1, 0); render(); e.preventDefault(); }
        if (e.key === 'Enter' && items[sel]) { go(items[sel]); e.preventDefault(); }
      });
      ov.addEventListener('click', function(e){ if (e.target === ov) close(); });
      refresh(); input.focus();
    };
    window.addEventListener('keydown', function(e){
      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); WB.palette(); }
    });

    var ACCENT = { '/storage': 'var(--sky)', '/team': 'var(--peach)', '/shared': 'var(--cream)', '/usage': 'var(--sage)',
      '/settings': 'var(--violet)', '/workspace': 'var(--peach)', '/database': 'var(--mint)', '/upgrade': 'var(--mint)' };
    function sectionAccent(p){ for (var k in ACCENT) { if (p.indexOf(k) === 0) return ACCENT[k]; } return 'var(--mint)'; }
    function crumbFor(p){ var v = WB._views[matchRoute(p).key]; var t = v && v.title;
      if (t) return t; if (p.indexOf('/nexuses') === 0) return 'Nexus'; return 'Nexus'; }

    function matchRoute(path){ // returns {key, params}
      if (WB._views[path]) return { key: path, params: {} };
      var m = path.match(/^\/nexuses\/(.+)$/); if (m && WB._views['/nexuses']) return { key: '/nexuses', params: { id: m[1] } };
      // longest registered prefix (e.g. /workspace/env)
      var best = null; for (var k in WB._views){ if (k !== '/' && path.indexOf(k) === 0 && (!best || k.length > best.length)) best = k; }
      if (best) return { key: best, params: {} };
      return { key: '/', params: {} };
    }

    // SVG icons (lucide, matching +layout.svelte: Gauge/Database/Users/KeyRound)
    var ICO = {
      gauge: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/></svg>',
      database: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/></svg>',
      users: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>',
      key: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/><circle cx="16.5" cy="7.5" r=".5" fill="currentColor"/></svg>',
      plus: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M12 5v14"/></svg>',
      apps: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/></svg>',
      spark: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/></svg>',
      activity: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>',
      admin: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/></svg>',
      chev: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>',
      search: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>',
      rail: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/></svg>'
    };
    var WMARK = WB.WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>';
    var SUN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
    var MOON = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>';

    // shell menu state
    var st = { nxMenu: false, wsMenu: false, editingId: null, editName: '', editIcon: '', pickerOpen: false, nxEditing: false, nxEditName: '', adminOpen: false,
      treeOpen: {}, treeData: {}, treeLoading: {}, bookmarks: [], search: '', wsMenuFor: null, rail: false };
    try { st.adminOpen = localStorage.getItem('wb-admin-drawer') === 'open'; } catch (e) {}
    try { st.rail = localStorage.getItem('wb-rail') === '1'; } catch (e) {}
    try { st.bookmarks = JSON.parse(localStorage.getItem('wb-bookmarks') || '[]'); } catch (e) { st.bookmarks = []; }
    function saveBookmarks(){ try { localStorage.setItem('wb-bookmarks', JSON.stringify(st.bookmarks)); } catch (e) {} }
    function toggleBookmark(path, label){
      var i = st.bookmarks.findIndex(function(b){ return b.path === path; });
      if (i >= 0) st.bookmarks.splice(i, 1); else st.bookmarks.push({ path: path, label: label || path.split('/').pop() });
      saveBookmarks(); renderShell();
    }
    // Lazy-load a directory's entries from the REAL data volume (/cloud/tree), then re-render.
    function loadTree(path){
      if (st.treeData[path] || st.treeLoading[path]) return;
      st.treeLoading[path] = true;
      fetch('/cloud/tree' + (path ? '?path=' + encodeURIComponent(path) : ''), { credentials: 'same-origin' })
        .then(function(r){ return r.json(); })
        .then(function(d){ st.treeData[path] = (d && d.entries) || []; })
        .catch(function(){ st.treeData[path] = []; })
        .then(function(){ delete st.treeLoading[path]; renderShell(); });
    }
    function isBookmarked(path){ return st.bookmarks.some(function(b){ return b.path === path; }); }
    // File search across workspaces — updates the results box IN PLACE (no shell re-render → keeps focus).
    function runSearch(){
      var q = (st.search || '').trim();
      var box = document.getElementById('wbSearchResults');
      if (!box) return;
      if (!q){ box.innerHTML = ''; return; }
      fetch('/cloud/search?q=' + encodeURIComponent(q), { credentials: 'same-origin' })
        .then(function(r){ return r.json(); })
        .then(function(d){
          if ((st.search || '').trim() !== q) return;  // stale response
          var rs = (d && d.results) || [];
          if (!rs.length){ box.innerHTML = '<div class="treemsg" style="padding-left:12px">No matches</div>'; return; }
          box.innerHTML = rs.map(function(r){
            return '<div class="sfrow" data-tree-file="' + esc(r.path) + '">' +
              '<span class="tname">' + esc(r.name) + '</span><span class="ssub">' + esc(r.workspace) + '</span>' +
              '<button class="tbm' + (isBookmarked(r.path) ? ' on' : '') + '" data-bm="' + esc(r.path) + '" data-bml="' + esc(r.name) + '" title="Bookmark">★</button>' +
            '</div>';
          }).join('');
        });
    }
    // Recursive file-tree HTML for an open folder at `path` (root mount name = workspace folder).
    function treeHtml(path, depth){
      if (st.treeLoading[path]) return '<div class="treemsg" style="padding-left:' + (depth * 14 + 12) + 'px">Loading…</div>';
      var entries = st.treeData[path];
      if (!entries) return '';
      if (entries.length === 0) return '<div class="treemsg" style="padding-left:' + (depth * 14 + 12) + 'px">Empty</div>';
      return entries.map(function(en){
        var pad = depth * 14 + 12;
        if (en.dir){
          var open = !!st.treeOpen[en.path];
          return '<div class="trow dir' + (open ? ' open' : '') + '" data-tree-toggle="' + esc(en.path) + '" style="padding-left:' + pad + 'px">' +
              '<span class="tchev">' + ICO.chev + '</span><span class="tname">' + esc(en.name) + '</span>' +
              '<button class="tbm' + (isBookmarked(en.path) ? ' on' : '') + '" data-bm="' + esc(en.path) + '" data-bml="' + esc(en.name) + '" title="Bookmark">★</button>' +
            '</div>' + (open ? treeHtml(en.path, depth + 1) : '');
        }
        return '<div class="trow file" data-tree-file="' + esc(en.path) + '" style="padding-left:' + (pad + 16) + 'px">' +
            '<span class="tname">' + esc(en.name) + '</span>' +
            '<button class="tbm' + (isBookmarked(en.path) ? ' on' : '') + '" data-bm="' + esc(en.path) + '" data-bml="' + esc(en.name) + '" title="Bookmark">★</button>' +
          '</div>';
      }).join('');
    }
    function inits(label){ return (label || '').split(/[\s-]+/).filter(Boolean).slice(0, 2).map(function (w) { return w[0].toUpperCase(); }).join('') || 'W'; }

    function renderShell(){
      var p = ROUTE.path, def = WB._views[matchRoute(p).key];
      var bare = def && def.bare;
      var fb = def && def.fullbleed;   // keep the shell sidebar, but mount the view edge-to-edge in .main
      var root = document.getElementById('root');
      if (bare) { root.innerHTML = '<div id="bareview"></div>'; return; }
      var nx = WB.nexus.active, ws = WB.ws.active, user = WB.user;
      var orgLabel = WB.profile.orgName || (user.email ? user.email.split('@')[0] : 'workspace');
      var nxLabel = (nx && nx.name) || orgLabel;
      var theme = document.documentElement.getAttribute('data-theme') || 'dark';
      var onWorkspace = p === '/workspace' || p.indexOf('/workspace/') === 0;
      // Breadcrumb on workspace settings — back to wherever the user opened Settings from.
      var crumbs = (onWorkspace && WB.settingsReturn) ? ('<div class="crumbs">' +
        '<button class="crumbback" data-crumb-back>' + ICO.chev + ' ' + esc(WB.settingsReturn.label) + '</button>' +
        '<span class="crumbsep">/</span><span class="crumbhere">' + esc((ws && ws.name) || 'Workspace') + ' settings</span>' +
      '</div>') : '';

      // Admin is a bottom-anchored OVERLAY drawer (above the avatar): toggled open, state persists, and it
      // floats over the workspaces list so a long sidebar still scrolls behind it.
      var adminDrawer = nx ? ('<div class="adminsec' + (st.adminOpen ? ' open' : '') + '">' +
        '<button class="adminbtn" data-admin-toggle>' + ICO.admin + '<span>Admin</span>' +
        '<span class="adminchev">' + ICO.chev + '</span></button>' +
        '<div class="admindrawer"><nav class="nxnav">' +
          navlink('/usage', ICO.gauge, 'Usage', p) + navlink('/storage', ICO.database, 'Storage', p) +
          navlink('/team', ICO.users, 'Users', p) + navlink('/secrets', ICO.key, 'Secrets', p) +
        '</nav></div></div>') : '';

      // Each workspace is a FOLDER: a disclosure caret expands its real file tree (desktop-app style).
      var wslist = WB.ws.list.map(function (w) {
        if (st.editingId === w.id) return wsEditor(false);
        var on = onWorkspace && ws && ws.id === w.id;
        var open = !!st.treeOpen[w.name];
        return '<div class="wsrow' + (on ? ' on' : '') + (open ? ' wsopen' : '') + '" data-ws="' + esc(w.id) + '">' +
          '<button class="wstoggle" data-tree-toggle="' + esc(w.name) + '" title="Show files" aria-label="Show files">' + ICO.chev + '</button>' +
          '<button class="wsmain" data-wsopen="' + esc(w.id) + '"><span class="av sm">' + esc(w.icon || (w.name[0] || 'W').toUpperCase()) + '</span><span class="omname">' + esc(w.name) + '</span></button>' +
          '<div class="wsmore">' +
            '<button class="wsmore-btn" data-wsmore="' + esc(w.id) + '" title="More" aria-label="More">⋯</button>' +
            (st.wsMenuFor === w.id ? ('<div class="wsmoremenu" role="menu">' +
              '<button data-wsedit="' + esc(w.id) + '">Edit</button>' +
              '<button data-wssettings="' + esc(w.id) + '">Settings</button>' +
            '</div>') : '') +
          '</div></div>' +
          (open ? '<div class="wstree">' + treeHtml(w.name, 1) + '</div>' : '');
      }).join('');
      if (st.editingId === 'new') wslist += wsEditor(true);
      if (WB.ws.list.length === 0) wslist += '<div class="omempty">No workspaces yet</div>';

      // Bookmarks — pinned files/folders (★), persisted per-browser. Sits ABOVE the workspaces explorer.
      var bmlist = st.bookmarks.map(function (b) {
        return '<div class="bmrow" data-tree-file="' + esc(b.path) + '"><span class="bmstar">★</span><span class="tname">' + esc(b.label) + '</span>' +
          '<button class="bmx" data-bm="' + esc(b.path) + '" data-bml="' + esc(b.label) + '" title="Remove bookmark">×</button></div>';
      }).join('');
      var bmsec = st.bookmarks.length ? ('<div class="swrap bmsec"><div class="swlabel">Bookmarks</div><div class="bmlist">' + bmlist + '</div></div>') : '';

      // File search across workspaces — sits below bookmarks. Results render in place (#wbSearchResults).
      var searchsec = '<div class="swrap srchsec">' +
        '<input id="wbFileSearch" class="srchinput" type="text" placeholder="Search files…" autocomplete="off" />' +
        '<div id="wbSearchResults" class="srchresults"></div>' +
      '</div>';

      var nxMenu = st.nxMenu ? nexusMenu(nx) : '';

      // Preserve the live view node across shell re-renders. A sidebar-only change (opening the nexus
      // menu / admin drawer / a ws menu) calls renderShell() WITHOUT renderView() — without this the
      // rebuilt #view would be empty and the page would blank. We move the existing (live, with its
      // listeners) #view back into the new shell. On a real nav, renderView() runs after and refills it.
      var prevView = document.getElementById('view');

      root.innerHTML =
      '<div id="app" class="' + (st.rail ? 'rail' : '') + '" style="--section:' + sectionAccent(p) + '">' +
        '<aside class="side">' +
          '<div class="topdna">' + WB.dna(7, 8) + '</div>' +
          '<div class="swrap nxtop">' +
            '<div class="sw" data-nxmenu role="button" tabindex="0">' +
              '<span class="av sm">' + esc((nx && nx.icon) || inits(nxLabel)) + '</span>' +
              '<span class="swname">' + esc(nxLabel) + '</span>' +
              '<svg class="ico ch" viewBox="0 0 24 24"><path fill="currentColor" d="M7 10l5 5 5-5z"/></svg>' +
            '</div>' + nxMenu +
          '</div>' +
          '<nav class="nxnav nxprimary">' +
            '<button class="nxlink nxsearch" data-palette aria-label="Search (Cmd-K)" title="Search">' + ICO.search + '<span class="lbl">Search</span><span class="kbd">⌘K</span></button>' +
            navlink('/studio', ICO.spark, 'New chat', p) +
            navlink('/activity', ICO.activity, 'Activity', p) +
            navlink('/workspaces', ICO.apps, 'Workspaces', p) +
          '</nav>' +
          '<div class="navspacer"></div>' +
          '<button class="railtoggle" data-rail-toggle aria-label="Collapse sidebar">' + ICO.rail + '</button>' +
          adminDrawer +
          '<div class="acct" style="display:flex;align-items:center;gap:4px">' +
            '<a data-nav="/settings" href="#/settings" title="' + esc(user.name) + '" style="display:flex;align-items:center;flex:1;text-decoration:none;color:inherit;min-width:0">' +
              '<div class="av">' + esc(user.initial) + '</div>' +
            '</a>' +
            '<a href="/auth/logout" title="Sign out" aria-label="Sign out" style="display:grid;place-items:center;width:30px;height:30px;flex:none;border-radius:8px;color:var(--dim)">' +
              '<svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M16 17v-2H9v-2h7V9l5 4-5 4ZM4 5h8V3H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h8v-2H4V5Z"/></svg>' +
            '</a>' +
          '</div>' +
        '</aside>' +
        '<div class="main">' + crumbs + (fb ? '<div id="view" class="fullbleed"></div>' : '<div class="wrap" id="view"></div>') + '</div>' +
      '</div>';

      if (prevView && prevView.childNodes.length) {
        var slot = root.querySelector('#view');
        if (slot) { prevView.className = slot.className; slot.parentNode.replaceChild(prevView, slot); }
      }

      if (st.pickerOpen) { var ph = root.querySelector('#wsPicker'); if (ph) WB.emojiPicker(ph, function (u) { st.editIcon = u; st.pickerOpen = false; renderShell(); renderView(); }); }
      var si = document.getElementById('wbFileSearch');
      if (si) { si.value = st.search; si.oninput = function(){ st.search = si.value; runSearch(); }; if (st.search) runSearch(); }
    }
    function navlink(href, ico, label, p){ return '<a class="nxlink' + (p === href ? ' on' : '') + '" data-nav="' + href + '" href="#' + href + '" title="' + esc(label) + '">' + ico + '<span class="lbl">' + esc(label) + '</span></a>'; }
    function wsEditor(isNew){ var tile = st.editIcon || ((st.editName.trim()[0] || 'W').toUpperCase());
      return '<div class="wsedit"><div class="wsiconrow">' +
        '<button class="wstile' + (st.pickerOpen ? ' on' : '') + '" data-wspick title="Change icon" aria-label="Change icon">' + esc(tile) + '</button>' +
        '<input class="wsinput" id="wsName" value="' + esc(st.editName) + '" placeholder="Workspace name" autofocus></div>' +
        (st.pickerOpen ? '<div class="wspicker"><div id="wsPicker"></div><button class="wsinitials" data-wsinitials>Use initials instead</button></div>' : '') +
        '<div class="wsactions">' + (!isNew ? '<button class="wsdel" data-wsdel>Delete</button>' : '') +
        '<span style="flex:1"></span><button class="wscancel" data-wscancel>Cancel</button><button class="wssave" data-wssave>' + (isNew ? 'Add' : 'Save') + '</button></div></div>'; }
    function nexusMenu(nx){ var others = WB.nexus.list().filter(function (n) { return n.id !== (nx && nx.id); });
      var h = '<div class="swmenu" role="menu">';
      if (nx) {
        h += others.map(function (n) { return '<button class="omitem" data-nxswitch="' + esc(n.id) + '"><span class="av sm">' + esc((n.icon || n.name[0] || 'N').toUpperCase()) + '</span><span class="omname">' + esc(n.name) + '</span></button>'; }).join('');
        if (others.length) h += '<div class="omdiv"></div>';
        if (st.nxEditing) h += '<div class="omitem" style="cursor:default"><span class="av sm plus">✎</span><input class="omedit" id="nxEditName" value="' + esc(st.nxEditName) + '" autofocus placeholder="Nexus name"><button class="omtick btn" data-nxsave title="Save">✓</button></div>';
        else h += '<button class="omitem" data-nxedit><span class="av sm plus">✎</span><span class="omname">Rename nexus</span></button>';
        h += '<a class="omitem" data-nav="/upgrade" href="#/upgrade"><span class="av sm plus">↑</span><span class="omname">Scale up</span></a>';
        h += '<a class="omitem" data-nav="/settings" href="#/settings"><span class="av sm plus">⚙</span><span class="omname">Nexus settings</span></a>';
        h += '<div class="omdiv"></div><button class="omitem" data-nxcreate><span class="av sm plus">+</span><span class="omname">Create new nexus</span></button>';
      } else {
        h += '<div class="omempty">No nexus yet</div><button class="omitem" data-nxcreate><span class="av sm plus">+</span><span class="omname">Create your nexus</span></button>';
      }
      return h + '</div>'; }

    // new-nexus modal (NewNexusModal port)
    function openNewNexus(){ var REGIONS = [{ id: 'sfo', label: '🌉 sfo' }, { id: 'ewr', label: '🗽 ewr' }, { id: 'fra', label: '🇩🇪 fra' }, { id: 'sin', label: '🇸🇬 sin' }];
      var SIZES = [{ id: '1 GB', nm: 'Small', ds: '1 GB · a project or a few agents' }, { id: '2 GB', nm: 'Medium', ds: '2 GB · a busy app · more headroom' }, { id: '4 GB', nm: 'Large', ds: '4 GB · heavy workloads · dedicated' }];
      var s = { name: 'nova', region: 'sfo', size: '1 GB', db: true };
      var modal = document.createElement('div'); modal.className = 'modal';
      function paint(){ modal.innerHTML = '<div class="sheet"><h2>Create your nexus</h2><p class="sub">Your organization\'s hosted runtime — you\'ll scale this one nexus as you grow.</p>' +
        '<div class="lab">Name</div><div class="field"><input id="nnName" value="' + esc(s.name) + '" placeholder="my-nexus"></div>' +
        '<div class="lab">Region</div><div class="regions">' + REGIONS.map(function (r) { return '<div class="reg' + (s.region === r.id ? ' sel' : '') + '" data-reg="' + r.id + '">' + r.label + '</div>'; }).join('') + '</div>' +
        '<div class="lab">Starting size</div><div class="plans">' + SIZES.map(function (z) { return '<div class="plan' + (s.size === z.id ? ' sel' : '') + '" data-size="' + esc(z.id) + '"><div class="nm">' + z.nm + '</div><div class="pr">' + z.id + '</div><div class="ds">' + z.ds + '</div></div>'; }).join('') + '</div>' +
        '<div class="lab">Database</div><div class="addon"><div class="info"><b>Postgres database</b><p>Comes with every nexus — turn it off if you don’t need one</p></div><div class="pr">included</div><div class="tog' + (s.db ? ' on' : '') + '" data-dbtog><i></i></div></div>' +
        '<div class="note">Egress-free object storage and Postgres are included. Unlimited workspaces and users — you\'re only ever scaled by memory and bandwidth. You can scale this nexus up anytime; you\'ll never need a second.</div>' +
        '<div class="foot"><div class="est">Scale up anytime</div><div style="display:flex;gap:8px"><button class="btn" data-cancel>Cancel</button><button class="btn primary" data-deploy>Create nexus</button></div></div></div>'; }
      paint();
      modal.addEventListener('input', function (e) { if (e.target.id === 'nnName') s.name = e.target.value; });
      modal.addEventListener('click', async function (e) {
        if (e.target === modal || e.target.closest('[data-cancel]')) { modal.remove(); return; }
        var reg = e.target.closest('[data-reg]'); if (reg) { s.region = reg.getAttribute('data-reg'); paint(); return; }
        var sz = e.target.closest('[data-size]'); if (sz) { s.size = sz.getAttribute('data-size'); paint(); return; }
        if (e.target.closest('[data-dbtog]')) { s.db = !s.db; paint(); return; }
        if (e.target.closest('[data-deploy]')) { var flyRegion = s.region === 'sfo' ? 'sjc' : s.region; modal.remove(); WB.toast('Provisioning your nexus…');
          try { var nxn = await WB.nexus.provision({ name: s.name.trim(), region: flyRegion, plan: s.size, database: s.db }); WB.toast(nxn.name + ' is provisioning'); renderShell(); WB.nav('/nexuses/' + nxn.id); }
          catch (er) { WB.toast('Couldn’t provision a nexus — check the runtime connection'); } } });
      document.body.appendChild(modal); }

    // shell event delegation
    document.addEventListener('click', function (e) {
      var t = e.target;
      var navEl = t.closest && t.closest('[data-nav]'); if (navEl) { e.preventDefault(); WB.nav(navEl.getAttribute('data-nav')); return; }
      if (t.closest && t.closest('[data-crumb-back]')) { var ret = WB.settingsReturn; WB.settingsReturn = null; WB.nav((ret && ret.path) || '/'); return; }
      if (t.closest && t.closest('[data-theme-toggle]')) { var cur = document.documentElement.getAttribute('data-theme') || 'dark'; var nt = cur === 'dark' ? 'light' : 'dark'; document.documentElement.setAttribute('data-theme', nt); try { localStorage.setItem('wb-theme', nt); } catch (er) {} renderShell(); renderView(); return; }
      if (t.closest && t.closest('[data-rail-toggle]')) { st.rail = !st.rail; try { localStorage.setItem('wb-rail', st.rail ? '1' : '0'); } catch (er) {} renderShell(); return; }
      if (t.closest && t.closest('[data-palette]')) { WB.palette(); return; }
      if (t.closest && t.closest('[data-admin-toggle]')) { st.adminOpen = !st.adminOpen; try { localStorage.setItem('wb-admin-drawer', st.adminOpen ? 'open' : 'closed'); } catch (er) {} renderShell(); return; }
      if (t.closest && t.closest('[data-nxmenu]')) { st.nxMenu = !st.nxMenu; st.wsMenu = false; renderShell(); return; }
      var nxsw = t.closest && t.closest('[data-nxswitch]'); if (nxsw) { WB.nexus.setActive(nxsw.getAttribute('data-nxswitch')); st.nxMenu = false; renderShell(); if (ROUTE.path !== '/') WB.nav('/'); else renderView(); return; }
      if (t.closest && t.closest('[data-nxedit]')) { e.stopPropagation(); st.nxEditing = true; st.nxEditName = (WB.nexus.active && WB.nexus.active.name) || ''; renderShell(); return; }
      if (t.closest && t.closest('[data-nxsave]')) { saveNxEdit(); return; }
      if (t.closest && t.closest('[data-nxcreate]')) { st.nxMenu = false; renderShell(); openNewNexus(); return; }
      if (t.closest && t.closest('[data-wsnew]')) { st.editingId = 'new'; st.editName = ''; st.editIcon = ''; st.pickerOpen = false; renderShell(); return; }
      var bmtog = t.closest && t.closest('[data-bm]'); if (bmtog) { e.stopPropagation(); toggleBookmark(bmtog.getAttribute('data-bm'), bmtog.getAttribute('data-bml')); return; }
      var ttog = t.closest && t.closest('[data-tree-toggle]'); if (ttog) { var tp = ttog.getAttribute('data-tree-toggle'); if (st.treeOpen[tp]) delete st.treeOpen[tp]; else { st.treeOpen[tp] = true; loadTree(tp); } renderShell(); return; }
      var tfile = t.closest && t.closest('[data-tree-file]'); if (tfile) { var fp = tfile.getAttribute('data-tree-file'); WB._pendingFile = fp; if (WB.openInExplorer && ROUTE.path === '/workspaces') WB.openInExplorer(fp); else WB.nav('/workspaces'); return; }
      var wsmore = t.closest && t.closest('[data-wsmore]'); if (wsmore) { e.stopPropagation(); var mid = wsmore.getAttribute('data-wsmore'); st.wsMenuFor = st.wsMenuFor === mid ? null : mid; renderShell(); return; }
      var wsset = t.closest && t.closest('[data-wssettings]'); if (wsset) { WB.ws.setActive(wsset.getAttribute('data-wssettings')); st.wsMenuFor = null; openWsSettings(); return; }
      var wsopen = t.closest && t.closest('[data-wsopen]'); if (wsopen) { WB.ws.setActive(wsopen.getAttribute('data-wsopen')); WB.nav('/workspaces'); return; }
      var wsedit = t.closest && t.closest('[data-wsedit]'); if (wsedit) { var w = WB.ws.list.find(function (x) { return x.id === wsedit.getAttribute('data-wsedit'); }); st.editingId = w.id; st.editName = w.name; st.editIcon = w.icon || ''; st.pickerOpen = false; st.wsMenuFor = null; renderShell(); return; }
      if (t.closest && t.closest('[data-wspick]')) { syncEditName(); st.pickerOpen = !st.pickerOpen; renderShell(); return; }
      if (t.closest && t.closest('[data-wsinitials]')) { st.editIcon = ''; st.pickerOpen = false; renderShell(); return; }
      if (t.closest && t.closest('[data-wscancel]')) { st.editingId = null; st.pickerOpen = false; renderShell(); return; }
      if (t.closest && t.closest('[data-wssave]')) { saveEdit(); return; }
      if (t.closest && t.closest('[data-wsdel]')) { deleteWs(); return; }
      if (st.wsMenuFor) { st.wsMenuFor = null; renderShell(); }   // outside click closes the ⋯ menu
    });
    document.addEventListener('input', function (e) { if (e.target.id === 'wsName') st.editName = e.target.value; if (e.target.id === 'nxEditName') st.nxEditName = e.target.value; });
    function syncEditName(){ var i = document.getElementById('wsName'); if (i) st.editName = i.value; }
    async function saveEdit(){ syncEditName(); var n = st.editName.trim(); if (!n) return;
      try { if (st.editingId === 'new') { var ws = await WB.ws.create(n, st.editIcon); WB.toast('Created “' + ws.name + '”'); }
        else { await WB.ws.update(st.editingId, { name: n, icon: st.editIcon }); WB.toast('Workspace updated'); }
        st.editingId = null; st.pickerOpen = false; st.wsMenu = false; renderShell(); } catch (e) { WB.toast('Couldn’t save the workspace', 'bad'); } }
    async function deleteWs(){ var w = WB.ws.list.find(function (x) { return x.id === st.editingId; }); if (!w) return;
      var ok = await WB.ws.remove(w.id); if (!ok) { WB.toast('Can’t delete your only workspace', 'bad'); return; } WB.toast('Deleted “' + w.name + '”'); st.editingId = null; renderShell(); }
    async function saveNxEdit(){ var i = document.getElementById('nxEditName'); if (i) st.nxEditName = i.value; var n = st.nxEditName.trim(); var nx = WB.nexus.active;
      if (!n || !nx) { st.nxEditing = false; renderShell(); return; }
      try { await WB.nexus.rename(nx.id, n); WB.toast('Nexus renamed'); } catch (e) { WB.toast('Couldn’t rename the nexus', 'bad'); } st.nxEditing = false; renderShell(); }
    // Open a workspace's settings — remember where we came from so the breadcrumb can return there.
    function openWsSettings(){
      WB.settingsReturn = { path: ROUTE.path, label: crumbFor(ROUTE.path) || 'Back' };
      WB.nav('/workspace/members');
    }

    // ── view render ───────────────────────────────────────────────────────────────────────────
    // A view may register teardown (e.g. destroy a graph instance) so its render loop + listeners
    // don't keep running on an orphaned DOM node after you navigate away (that froze the page).
    function runCleanup(){ if (WB._cleanup) { try { WB._cleanup(); } catch (e) {} WB._cleanup = null; } }

    async function renderView(){
      runCleanup();
      var p = ROUTE.path, m = matchRoute(p); WB._params = m.params; ROUTE.params = m.params;
      var def = WB._views[m.key] || WB._views['/'];
      var mount = def.bare ? document.getElementById('bareview') : document.getElementById('view');
      if (!mount) return;
      mount.setAttribute('data-view', m.key);   // scope key for per-view styles (scopeCss)
      mount.innerHTML = '';
      try { await def.render(mount, { params: m.params }); } catch (e) { mount.innerHTML = '<div class="card">Something went wrong loading this view.</div>'; console.error(e); }
    }

    async function route(){ runCleanup(); var h = location.hash.slice(1) || '/'; ROUTE.path = h; renderShell(); await renderView(); }
    window.addEventListener('hashchange', route);

    // ── home view ('/') — reproduced from routes/+page.svelte ────────────────────────────────────
    WB.scopedStyles('/', '.empty { text-align: center; color: var(--dim); }\n.metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin: 4px 0 18px; }\n.metric { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; }\n.mlabel { font: 700 10px var(--read); letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }\n.mbig { font: 700 32px var(--read); color: var(--ink); margin: 6px 0 12px; letter-spacing: -0.02em; }\n.mbar { height: 7px; border-radius: 4px; background: var(--line); overflow: hidden; }\n.mbar i { display: block; height: 100%; background: var(--sky); border-radius: 4px; }\n.msub { font: 500 12px var(--read); color: var(--dim); margin-top: 9px; }\n.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }\n.dcard { display: block; background: var(--card); border: 1px solid var(--line); border-radius: 13px; padding: 16px 18px; text-decoration: none; color: inherit; transition: border-color 0.12s, transform 0.08s; }\n.dcard:hover { border-color: var(--stroke); transform: translateY(-1px); }\n.ddot { display: inline-block; width: 10px; height: 10px; border-radius: 4px; margin-bottom: 10px; }\n.dt { font: 600 15px var(--read); color: var(--ink); }\n.ds { font: 500 12.5px var(--read); color: var(--dim); margin-top: 3px; }');
    WB.view('/', { title: 'Nexus', accent: 'var(--mint)', async render(el){
      var nx = WB.nexus.active;
      var storage, usage; try { storage = await WB.api.listBuckets(); } catch (e) {} try { usage = await WB.api.nexusUsage(); } catch (e) {}
      var status = nx && (nx.state === 'run' ? 'Active' : nx.state === 'sleep' ? 'Idle' : 'Starting');
      var storageUsed = (storage && storage.totalSize) || '0 GB';
      var loadPct = usage && usage.summary && usage.summary.load;
      var loadKnown = typeof loadPct === 'number';
      var loadDisplay = loadKnown ? (loadPct + '%') : '—';
      var loadNote = !loadKnown ? 'No live machine to meter' : loadPct === 0 ? 'Idle — scaled down' : 'Live · metered from Fly';
      var CARDS = [{ href: '/storage', title: 'Storage', sub: 'Files, images & data', accent: 'var(--sky)' },
        { href: '/database', title: 'Database', sub: 'Postgres, included', accent: 'var(--mint)' },
        { href: '/team', title: 'Team', sub: 'Org members & access', accent: 'var(--peach)' },
        { href: '/usage', title: 'Usage & billing', sub: 'Plan, invoices, history', accent: 'var(--sage)' }];
      if (!nx) { el.innerHTML = '<section><div class="sechead"><div><h2>Your nexus</h2><p>Your hosted runtime — one per organization, scaled to fit.</p></div></div>' +
        '<div class="card empty">No nexus yet — open the <b>Nexus</b> menu in the sidebar and <b>Create your nexus</b> to spin it up. You scale this one nexus as you grow; there\'s never a second.</div></section>'; return; }
      el.innerHTML = '<section><div class="sechead"><div>' +
        '<h2 style="display:flex;align-items:center;gap:11px"><span class="dot ' + esc(nx.state) + '"></span>' + esc(nx.name) + '</h2>' +
        '<p>' + esc(nx.plan) + ' · ' + esc(nx.region) + ' · ' + esc(status) + '</p></div>' +
        '<div style="display:flex;gap:8px"><a class="btn sm" data-nav="/upgrade" href="#/upgrade">Scale up</a><button class="btn sm" data-open>Open ↗</button></div></div>' +
        '<div class="metrics"><div class="metric"><div class="mlabel">Storage</div><div class="mbig">' + esc(storageUsed) + '</div><div class="mbar"><i style="width:8%"></i></div><div class="msub">used of your plan</div></div>' +
        '<div class="metric"><div class="mlabel">Load</div><div class="mbig">' + esc(loadDisplay) + '</div><div class="mbar"><i style="width:' + (loadKnown ? loadPct : 0) + '%; background:var(--peach)"></i></div><div class="msub">' + esc(loadNote) + '</div></div></div>' +
        '<div class="cards">' + CARDS.map(function (c) { return '<a class="dcard" data-nav="' + c.href + '" href="#' + c.href + '"><span class="ddot" style="background:' + c.accent + '"></span><div class="dt">' + c.title + '</div><div class="ds">' + c.sub + '</div></a>'; }).join('') + '</div></section>';
      var ob = el.querySelector('[data-open]'); if (ob) ob.onclick = function () { window.open(nx.url, '_blank'); };
    } });

    // ── boot ──────────────────────────────────────────────────────────────────────────────────
    WB.start = async function () {
      await loadIdentity();
      try { await WB.nexus.load(); } catch (e) {}
      var defaultWs = (WB.profile && WB.profile.orgName) || (WB.user.email ? WB.user.email.split('@')[0] : '') || 'Workspace';
      try { await WB.ws.load(defaultWs); } catch (e) {}
      await route();
    };
    // run after all view scripts have registered
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function(){ setTimeout(WB.start, 0); });
    else setTimeout(WB.start, 0);
  })();
