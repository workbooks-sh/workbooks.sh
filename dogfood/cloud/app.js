  // ═══════════════════════ WB runtime — ports api.js + the stores + helpers ═══════════════════════
  (function () {
    var WB = (window.WB = window.WB || {});
    // Cache-busting version — read from THIS script's own ?v= (set in index.work). Lazily-loaded
    // assets (view scripts, wbchat modules) carry the same token so a deploy = new URLs = guaranteed
    // cache miss. (Hard-refresh does NOT re-fetch lazy import()/injected <script> — only a new URL does.)
    WB.V = (function () {
      try { var m = ((document.currentScript && document.currentScript.src) || '').match(/[?&]v=([^&]+)/); return m ? m[1] : ''; }
      catch (e) { return ''; }
    })();
    WB.vurl = function (u) { return WB.V ? u + (u.indexOf('?') < 0 ? '?' : '&') + 'v=' + WB.V : u; };

    // ── stale-while-revalidate cache ────────────────────────────────────────────────────────────
    // Admin/data pages render the LAST-KNOWN result instantly (from localStorage), then refresh in the
    // background — so a suspended/cold nexus never blocks the UI and re-navigations are instant. Keyed
    // per-tenant so one org never sees another's cached data.
    WB.cache = {
      _k: function (key) { var t = (WB.nexus && WB.nexus.active && WB.nexus.active.id) || (WB.user && WB.user.email) || '_'; return 'wbc:' + t + ':' + key; },
      get: function (key) { try { return JSON.parse(localStorage.getItem(this._k(key))); } catch (e) { return null; } },
      set: function (key, data) { try { localStorage.setItem(this._k(key), JSON.stringify(data)); } catch (e) {} }
    };
    // render(data, isStale) is called up to twice: once with cached data (if any, isStale=true) for an
    // instant paint, then once with fresh data (isStale=false). Returns the fresh result.
    WB.swr = async function (key, fetcher, render) {
      var cached = WB.cache.get(key);
      if (cached != null) { try { render(cached, true); } catch (e) {} }
      try {
        var fresh = await fetcher();
        WB.cache.set(key, fresh);
        try { render(fresh, false); } catch (e) {}
        return fresh;
      } catch (e) {
        if (cached == null) { try { render(null, false); } catch (_) {} }
        return cached;
      }
    };
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

    // A single-field prompt modal (rename / new file name). Resolves the trimmed value, or null on cancel.
    WB.prompt = function (o) { o = o || {}; return new Promise(function (resolve) {
      var modal = document.createElement('div'); modal.className = 'modal';
      modal.innerHTML = '<div class="sheet" style="width:420px"><h2>' + esc(o.title || 'Enter a value') + '</h2>' +
        (o.body ? '<p class="sub">' + esc(o.body) + '</p>' : '') +
        '<input class="winput" id="wbPromptIn" autocomplete="off" spellcheck="false" placeholder="' + esc(o.placeholder || '') + '" />' +
        '<div class="foot"><span></span><div style="display:flex;gap:8px">' +
        '<button class="btn" data-x="0">Cancel</button><button class="btn primary" data-x="1">' + esc(o.confirm || 'OK') + '</button></div></div></div>';
      function done(v){ modal.remove(); resolve(v); }
      var inp = modal.querySelector('#wbPromptIn');
      modal.addEventListener('click', function (e) { if (e.target === modal) done(null);
        var x = e.target.closest('[data-x]'); if (x) done(x.getAttribute('data-x') === '1' ? (inp.value.trim() || null) : null); });
      modal.addEventListener('keydown', function (e) { if (e.key === 'Enter'){ e.preventDefault(); done(inp.value.trim() || null); } if (e.key === 'Escape') done(null); });
      document.body.appendChild(modal); inp.value = o.value || ''; inp.focus(); inp.select(); }); };

    // Copy text to the clipboard with a toast. Falls back to a hidden textarea where the async API is unavailable.
    WB.copy = function (text, label) { text = String(text == null ? '' : text);
      function ok(){ WB.toast((label || 'Copied') + ' to clipboard'); }
      try { if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text).then(ok, fb); return; } } catch (e) {}
      fb();
      function fb(){ try { var ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); ok(); } catch (e2) { WB.toast('Couldn’t copy', 'bad'); } } };

    // ── identity ──────────────────────────────────────────────────────────────────────────────
    WB.user = { name: 'Account', email: '', initial: 'A' };
    WB.profile = {};
    // The signed-in user's role in this nexus, mirrored from /me (server routes are the real authority).
    // Context-menu actions are gated on it via WB.can — items the role can't perform are HIDDEN. Default
    // 'owner' so a server that hasn't yet surfaced a role (or local dev) shows the full menu; cloud
    // sessions always carry the real role. Ranked viewer < member < admin < owner.
    WB.role = 'owner';
    var ROLE_RANK = { viewer: 1, member: 2, admin: 3, owner: 4 };
    // Capability → minimum role. A missing capability ⇒ allowed (read-only/universal actions).
    var CAP_MIN = {
      'app.create': 'member', 'app.edit': 'member',
      'file.write': 'member',
      'workspace.manage': 'admin',
      'member.manage': 'admin',
      'secret.manage': 'admin',
      'nexus.manage': 'admin',
      'billing.manage': 'owner'
    };
    WB.can = function (cap) {
      if (!cap) return true;
      var need = CAP_MIN[cap]; if (!need) return true;
      return (ROLE_RANK[WB.role] || 0) >= (ROLE_RANK[need] || 99);
    };
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
      if (me.role) WB.role = me.role;
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
      { label: 'Studio', icon: '+', go: '/studio' },
      { label: 'Tasks', icon: '☰', go: '/tasks' },
      { label: 'Runs', icon: '▸', go: '/runs' },
      { label: 'Issues', icon: '⚑', go: '/issues' },
      { label: 'Activity', icon: '∿', go: '/activity' },
      { label: 'Workspaces', icon: '▦', go: '/workspaces' },
      { label: 'Usage & billing', icon: '◷', go: '/usage' },
      { label: 'Storage', icon: '▤', go: '/storage' },
      { label: 'Team', icon: '👥', go: '/team' },
      { label: 'Secrets', icon: '🔑', go: '/secrets' },
      { label: 'Integrations', icon: '🔌', go: '/integrations' },
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

    // ── Context-menu engine ───────────────────────────────────────────────────────────────────────
    // ONE floating-menu primitive for the whole app. Objects opt into right-click by carrying
    // data-ctx="<kind>"; a registered builder returns an items[] for that kind. The same engine also
    // backs click-driven ⋯ menus (WB.ctx.openFrom), so the legacy popovers converge here.
    //   item = { label, icon, on, need:<capability>, danger, disabled, sep, header, submenu:[items] }
    // Items whose `need` the current role can't satisfy are HIDDEN (WB.can). on() runs after the menu
    // closes. A `submenu` opens a child menu to the side on hover.
    WB.ctx = (function(){
      var reg = {}, openMenus = [];
      function register(kind, fn){ reg[kind] = fn; }
      function closeAll(){ openMenus.forEach(function(m){ if (m.parentNode) m.parentNode.removeChild(m); }); openMenus = []; unbind(); }
      function closeFrom(depth){ while (openMenus.length > depth){ var m = openMenus.pop(); if (m.parentNode) m.parentNode.removeChild(m); } if (!openMenus.length) unbind(); }
      function onKey(e){ if (e.key === 'Escape'){ e.preventDefault(); closeAll(); } }
      function onDown(e){ if (!e.target.closest || !e.target.closest('.ctxmenu')) closeAll(); }
      function onScroll(e){ if (!e.target.closest || !e.target.closest('.ctxmenu')) closeAll(); }
      var bound = false;
      function bind(){ if (bound) return; bound = true;
        document.addEventListener('keydown', onKey, true);
        document.addEventListener('mousedown', onDown, true);
        document.addEventListener('scroll', onScroll, true);
        window.addEventListener('blur', closeAll); window.addEventListener('resize', closeAll); }
      function unbind(){ if (!bound) return; bound = false;
        document.removeEventListener('keydown', onKey, true);
        document.removeEventListener('mousedown', onDown, true);
        document.removeEventListener('scroll', onScroll, true);
        window.removeEventListener('blur', closeAll); window.removeEventListener('resize', closeAll); }

      // Drop items the role can't use, then collapse separators (no leading/trailing/double dividers).
      function visible(items){
        var out = (items || []).filter(function(it){ return it && (it.sep || it.header || !it.need || WB.can(it.need)); });
        var res = [], prevSep = true;
        out.forEach(function(it){ if (it.sep){ if (!prevSep) { res.push(it); prevSep = true; } } else { res.push(it); prevSep = false; } });
        while (res.length && (res[res.length - 1].sep || res[res.length - 1].header)) res.pop();
        return res;
      }
      function build(items, depth){
        var menu = document.createElement('div'); menu.className = 'ctxmenu';
        items.forEach(function(it){
          if (it.sep){ var d = document.createElement('div'); d.className = 'ctxsep'; menu.appendChild(d); return; }
          if (it.header){ var h = document.createElement('div'); h.className = 'ctxhdr'; h.textContent = it.header; menu.appendChild(h); return; }
          var b = document.createElement('button');
          b.className = 'ctxitem' + (it.danger ? ' danger' : '') + (it.submenu ? ' has-sub' : '');
          b.disabled = !!it.disabled;
          b.innerHTML = '<span class="ctxico">' + (it.icon || '') + '</span><span class="ctxlbl">' + esc(it.label) + '</span>' +
            (it.submenu ? '<span class="ctxarrow">' + ICO.chev + '</span>' : '');
          if (it.submenu){
            b.addEventListener('mouseenter', function(){ closeFrom(depth + 1); var sub = visible(typeof it.submenu === 'function' ? it.submenu() : it.submenu);
              if (sub.length){ var r = b.getBoundingClientRect(); spawn(sub, r.right - 4, r.top - 4, depth + 1); } });
          } else {
            b.addEventListener('mouseenter', function(){ closeFrom(depth + 1); });
            b.addEventListener('click', function(e){ e.preventDefault(); if (it.disabled) return; closeAll(); if (it.on) it.on(); });
          }
          menu.appendChild(b);
        });
        return menu;
      }
      function place(menu, x, y){
        menu.style.visibility = 'hidden'; document.body.appendChild(menu);
        var r = menu.getBoundingClientRect(), vw = window.innerWidth, vh = window.innerHeight;
        var px = (x + r.width > vw - 8) ? Math.max(8, x - r.width) : x;
        var py = (y + r.height > vh - 8) ? Math.max(8, vh - r.height - 8) : y;
        menu.style.left = Math.max(8, px) + 'px'; menu.style.top = Math.max(8, py) + 'px'; menu.style.visibility = '';
      }
      function spawn(items, x, y, depth){ var menu = build(items, depth); place(menu, x, y); openMenus[depth] = menu; openMenus.length = depth + 1; bind(); return menu; }
      function show(items, x, y){ closeAll(); var vis = visible(items); if (!vis.length) return; spawn(vis, x, y, 0); }
      // Open a menu anchored under an element (for click-driven ⋯ buttons).
      function openFrom(el, items){ var r = el.getBoundingClientRect(); show(items, r.left, r.bottom + 4); }

      document.addEventListener('contextmenu', function(e){
        var host = e.target.closest && e.target.closest('[data-ctx]');
        if (!host) { closeAll(); return; }
        var fn = reg[host.getAttribute('data-ctx')]; if (!fn) return;
        var items = fn(host, e) || []; var vis = visible(items); if (!vis.length) return;
        e.preventDefault(); closeAll(); spawn(vis, e.clientX, e.clientY, 0);
      });
      return { register: register, show: show, openFrom: openFrom, close: closeAll };
    })();

    var ACCENT = { '/storage': 'var(--sky)', '/team': 'var(--peach)', '/shared': 'var(--cream)', '/usage': 'var(--sage)',
      '/settings': 'var(--violet)', '/workspace': 'var(--peach)', '/database': 'var(--mint)', '/upgrade': 'var(--mint)' };
    function sectionAccent(p){ for (var k in ACCENT) { if (p.indexOf(k) === 0) return ACCENT[k]; } return 'var(--mint)'; }
    // Which RAIL section a route belongs to — drives the active rail tab + which per-surface sidebar shows.
    var ADMIN_ROUTES = ['/usage', '/storage', '/team', '/secrets', '/database', '/upgrade'];
    function sectionFor(p){
      if (p.indexOf('/integrations') === 0) return 'integrations';   // own rail section — not admin-gated
      if (p.indexOf('/studio') === 0 || p.indexOf('/create') === 0) return 'studio';
      if (p.indexOf('/activity') === 0 || p.indexOf('/runs') === 0 || p.indexOf('/tasks') === 0 || p.indexOf('/issues') === 0) return 'activity';
      if (p.indexOf('/workspace') === 0) return 'files';
      if (p.indexOf('/settings') === 0) return 'account';   // personal settings = the "You" surface
      for (var i = 0; i < ADMIN_ROUTES.length; i++) if (p.indexOf(ADMIN_ROUTES[i]) === 0) return 'admin';
      return 'apps'; // home '/' and anything else default to the Apps surface
    }
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

    // ── Lazy view loading ──────────────────────────────────────────────────────────────────────
    // Each route lives in its own ./views/<file>.js that self-registers via WB.view(). Instead of
    // <script>-tagging all 20 upfront (~260KB, 20 requests on every cold load), we inject only the
    // ACTIVE view's script on demand. The home '/' view ships inline in app.js (no entry here).
    var VIEW_FILES = {
      '/app': 'app',
      '/activity': 'activity', '/runs': 'runs', '/tasks': 'tasks', '/issues': 'issues', '/database': 'database', '/denied': 'denied',
      '/integrations': 'integrations', '/nexuses': 'nexuses', '/secrets': 'secrets', '/settings': 'settings',
      '/shared': 'shared', '/storage': 'storage', '/studio': 'studio', '/create': 'studio', '/usage': 'studio',
      '/team': 'team', '/upgrade': 'upgrade', '/welcome': 'welcome', '/workspace/env': 'workspace-env',
      '/workspace/history': 'workspace-history', '/workspace/members': 'workspace-members',
      '/workspace/sharing': 'workspace-sharing', '/workspace': 'workspace', '/workspaces': 'workspaces'
    };
    function fileForPath(path){
      if (VIEW_FILES[path]) return VIEW_FILES[path];
      var best = null; for (var k in VIEW_FILES){ if (path.indexOf(k) === 0 && (!best || k.length > best.length)) best = k; }
      return best ? VIEW_FILES[best] : null;
    }
    var _viewLoaded = {};
    function ensureView(path){
      return new Promise(function(resolve){
        var file = fileForPath(path);
        if (!file || _viewLoaded[file]) return resolve();
        _viewLoaded[file] = true;
        var s = document.createElement('script'); s.src = WB.vurl('./views/' + file + '.js');
        s.onload = function(){ resolve(); }; s.onerror = function(){ resolve(); };
        document.head.appendChild(s);
      });
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
      plug: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/></svg>',
      files: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13c0 1.1.9 2 2 2Z"/></svg>',
      grid: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/></svg>',
      filter: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h18M6 12h12M10 20h4"/></svg>',
      globe: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20M2 12h20"/></svg>',
      lock: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>',
      draft: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
      search: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>',
      rail: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/></svg>',
      pin: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 17v5M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/></svg>',
      logout: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>',
      gear: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
      edit: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>',
      trash: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M10 11v6M14 11v6"/></svg>',
      copy: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>',
      link: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>',
      download: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5M12 15V3"/></svg>',
      external: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/></svg>',
      newfile: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v5h5M12 11v6M9 14h6"/></svg>',
      newfolder: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13c0 1.1.9 2 2 2Z"/><path d="M12 11v6M9 14h6"/></svg>',
      file: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v5h5"/></svg>'
    };
    var WMARK = WB.WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>';

    // ── File/folder icons — the VS Code Material Icon Theme, served from CDN (no-build). Mirrors the
    // desktop's materialIcon.ts resolution (fileNames > fileExtensions > default; folders likewise).
    // `.work` gets OUR branded logo tile. Manifest is loaded once at boot (WB.loadIcons) so WB.fileIcon
    // is synchronous afterward. ──
    var MIT = 'https://cdn.jsdelivr.net/npm/material-icon-theme';
    WB._micon = null;
    WB.loadIcons = async function(){
      if (WB._micon) return WB._micon;
      try { WB._micon = await fetch(MIT + '/dist/material-icons.json').then(function(r){ return r.json(); }); }
      catch (e) { WB._micon = {}; }
      return WB._micon;
    };
    WB.iconUrl = function(def){ return MIT + '/icons/' + def + '.svg'; };
    WB.fileIcon = function(name, opts){
      opts = opts || {};
      var lower = String(name || '').toLowerCase();
      if (/\.work$/.test(lower)) return '<span class="micon work">' + WMARK + '</span>';
      var m = WB._micon || {}, def;
      if (opts.dir) {
        var fm = opts.open ? (m.folderNamesExpanded || {}) : (m.folderNames || {});
        def = fm[lower] || (opts.open ? (m.folderExpanded || 'folder-open') : (m.folder || 'folder'));
      } else {
        def = (m.fileNames || {})[lower];
        if (!def) { var p = lower.split('.'); for (var i = 1; i < p.length && !def; i++) def = (m.fileExtensions || {})[p.slice(i).join('.')]; }
        def = def || (m.file || 'file');
      }
      return '<img class="micon" src="' + WB.iconUrl(def) + '" alt="" loading="lazy">';
    };
    var SUN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
    var MOON = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>';

    // shell menu state
    var st = { nxMenu: false, wsMenu: false, editingId: null, editName: '', editIcon: '', pickerOpen: false, nxEditing: false, nxEditName: '',
      treeOpen: {}, treeData: {}, treeLoading: {}, bookmarks: [], search: '', rail: false, sideMode: 'apps' };
    try { st.rail = localStorage.getItem('wb-rail') === '1'; } catch (e) {}
    // Apps-vs-Files sidebar preference — Apps is primary (most users just launch apps). Persisted so it
    // sticks per user/device. ('wb-sidemode' = 'apps' | 'files')
    try { st.sideMode = localStorage.getItem('wb-sidemode') || 'apps'; } catch (e) {}
    // Context-dependent filters (the funnel by the tabs). Apps: visibility; Files: file type. Persisted.
    st.filterOpen = false;
    try { st.appFilter = localStorage.getItem('wb-appfilter') || 'all'; } catch (e) { st.appFilter = 'all'; }   // all | public | private
    try { st.fileFilter = localStorage.getItem('wb-filefilter') || 'all'; } catch (e) { st.fileFilter = 'all'; } // all | work | assets
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
        .then(function(){ delete st.treeLoading[path]; paintTree(); });
    }
    // Refresh ONLY the sidebar file tree in place — never rebuild the shell here (that would race the
    // async view mount and detach the page content).
    function paintTree(){
      // Repaint each OPEN workspace group's nested file tree in place (handles async folder loads and
      // nested dir toggles) — never rebuild the shell here (that would race the async view mount).
      (WB.ws.list || []).forEach(function (w) {
        if (!st.treeOpen[w.id]) return;
        var sel = (window.CSS && CSS.escape) ? CSS.escape(w.id) : w.id;
        var wt = document.querySelector('[data-ws-tree="' + sel + '"]');
        if (wt) wt.innerHTML = treeHtml(w.id, 1);
      });
    }
    // ── File operations (right-click menu → /cloud/file/* verbs) ────────────────────────────────
    function treeParent(path){ var p = (path || '').split('/'); p.pop(); return p.join('/'); }
    function refreshAfter(path){ delete st.treeData[path]; st.treeLoading[path] = false; loadTree(path); paintTree();
      if (WB.refreshExplorer) try { WB.refreshExplorer(); } catch (e) {} }
    async function fileMutate(url, body, refreshPath, okMsg){
      try {
        var r = await fetch(url, { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
        var d = await r.json();
        if (d && d.ok){ WB.toast(okMsg + (d.sha ? ' · ' + d.sha : '')); refreshAfter(refreshPath); return true; }
        WB.toast((d && d.error) || 'Failed', 'bad'); return false;
      } catch (e){ WB.toast('Failed', 'bad'); return false; }
    }
    WB.fileOps = {
      open: function(path){ WB._pendingFile = path; if (WB.openInExplorer && ROUTE.path === '/workspaces') WB.openInExplorer(path); else WB.nav('/workspaces'); },
      download: function(path){ window.open('/cloud/raw?path=' + encodeURIComponent(path), '_blank'); },
      newFile: async function(dir){ var nm = await WB.prompt({ title: 'New file', placeholder: 'name.work', confirm: 'Create' }); if (!nm) return;
        st.treeOpen[dir] = true; await fileMutate('/cloud/file/new', { path: dir + '/' + nm }, dir, 'Created ' + nm); },
      newFolder: async function(dir){ var nm = await WB.prompt({ title: 'New folder', placeholder: 'folder', confirm: 'Create' }); if (!nm) return;
        st.treeOpen[dir] = true; await fileMutate('/cloud/file/mkdir', { path: dir + '/' + nm }, dir, 'Created folder ' + nm); },
      rename: async function(path){ var base = path.split('/').pop();
        var nm = await WB.prompt({ title: 'Rename', value: base, confirm: 'Rename' }); if (!nm || nm === base) return;
        await fileMutate('/cloud/file/rename', { from: path, to: treeParent(path) + '/' + nm }, treeParent(path), 'Renamed to ' + nm); },
      del: async function(path, isDir){ var base = path.split('/').pop();
        var ok = await WB.confirm({ title: 'Delete ' + (isDir ? 'folder' : 'file') + '?', body: '“' + base + '” will be removed and the change committed.', confirm: 'Delete', danger: true }); if (!ok) return;
        await fileMutate('/cloud/file/delete', { path: path }, treeParent(path), 'Deleted ' + base); }
    };
    function setVisibility(id, state){
      fetch('/cloud/visibility', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: id, state: state }) })
        .then(function(r){ return r.json(); })
        .then(function(d){ if (d && d.ok){ WB.toast('Set to ' + state); WB.cache.set('apps', null); paintApps(); } else WB.toast((d && d.error) || 'Failed', 'bad'); })
        .catch(function(){ WB.toast('Failed', 'bad'); });
    }
    // Going private/draft TAKES A LIVE SITE DOWN from public — a real, server-enforced access change, so
    // confirm it. Publishing (→ public) is non-destructive and applies immediately without a prompt.
    async function changeVisibility(id, state, label){
      var who = '“' + (label || id) + '”';
      if (state === 'private') {
        if (!await WB.confirm({ title: 'Make private?', danger: true, confirm: 'Make private',
          body: who + ' will be taken down from public. Visitors get a “not available” page — only signed-in members can reach it.' })) return;
      } else if (state === 'draft') {
        if (!await WB.confirm({ title: 'Move to draft?', danger: true, confirm: 'Move to draft',
          body: who + ' will go offline as a draft — not publicly accessible until you publish it again.' })) return;
      }
      setVisibility(id, state);
    }

    // ── Context-menu registrations — one place wiring every surface's right-click actions ──────────
    WB.ctx.register('file', function(el){
      var path = el.getAttribute('data-tree-file') || el.getAttribute('data-path');
      var pinned = isBookmarked(path);
      return [
        { label: 'Open', icon: ICO.file, on: function(){ WB.fileOps.open(path); } },
        { label: 'Rename…', icon: ICO.edit, need: 'file.write', on: function(){ WB.fileOps.rename(path); } },
        { label: pinned ? 'Unpin' : 'Pin', icon: ICO.pin, on: function(){ toggleBookmark(path); } },
        { sep: true },
        { label: 'Copy path', icon: ICO.copy, on: function(){ WB.copy(path, 'Path'); } },
        { label: 'Download', icon: ICO.download, on: function(){ WB.fileOps.download(path); } },
        { sep: true },
        { label: 'Delete', icon: ICO.trash, danger: true, need: 'file.write', on: function(){ WB.fileOps.del(path, false); } }
      ];
    });
    WB.ctx.register('folder', function(el){
      var path = el.getAttribute('data-tree-toggle') || el.getAttribute('data-path');
      return [
        { label: 'New file…', icon: ICO.newfile, need: 'file.write', on: function(){ WB.fileOps.newFile(path); } },
        { label: 'New folder…', icon: ICO.newfolder, need: 'file.write', on: function(){ WB.fileOps.newFolder(path); } },
        { sep: true },
        { label: 'Rename…', icon: ICO.edit, need: 'file.write', on: function(){ WB.fileOps.rename(path); } },
        { label: 'Copy path', icon: ICO.copy, on: function(){ WB.copy(path, 'Path'); } },
        { sep: true },
        { label: 'Delete', icon: ICO.trash, danger: true, need: 'file.write', on: function(){ WB.fileOps.del(path, true); } }
      ];
    });
    function wsCtxItems(id){
      var w = (WB.ws.list || []).filter(function(x){ return x.id === id; })[0] || { id: id, name: id };
      return [
        { label: 'New file…', icon: ICO.newfile, need: 'file.write', on: function(){ st.treeOpen[id] = true; loadTree(id); WB.fileOps.newFile(id); } },
        { label: 'New folder…', icon: ICO.newfolder, need: 'file.write', on: function(){ st.treeOpen[id] = true; loadTree(id); WB.fileOps.newFolder(id); } },
        { sep: true },
        { label: 'Open explorer', icon: ICO.files, on: function(){ WB.ws.setActive(id); WB.nav('/workspaces'); } },
        { label: 'Rename…', icon: ICO.edit, need: 'workspace.manage', on: function(){ st.editingId = id; st.editName = w.name; st.editIcon = w.icon || ''; renderShell(); } },
        { label: 'Settings', icon: ICO.gear, need: 'workspace.manage', on: function(){ WB.ws.setActive(id); openWsSettings(); } },
        { label: 'Sharing', icon: ICO.globe, need: 'workspace.manage', on: function(){ WB.ws.setActive(id); WB.nav('/workspace/sharing'); } },
        { sep: true },
        { label: 'Delete workspace', icon: ICO.trash, danger: true, need: 'workspace.manage', on: async function(){
            var ok = await WB.confirm({ title: 'Delete workspace?', body: '“' + w.name + '” and its files will be removed.', confirm: 'Delete', danger: true }); if (!ok) return;
            var done = await WB.ws.remove(id); if (done === false) { WB.toast('Can’t delete your only workspace', 'bad'); return; }
            WB.toast('Workspace deleted'); renderShell(); } }
      ];
    }
    WB.ctx.register('workspace', function(el){ return wsCtxItems(el.getAttribute('data-tree-toggle') || el.getAttribute('data-ws-id')); });
    WB.ctx.register('app', function(el){
      var name = el.getAttribute('data-open-app'); var a = (WB._appReg && WB._appReg[name]) || { name: name };
      var vis = a.visibility || (a.gated ? 'private' : 'public');
      var items = [
        { label: 'Open', icon: ICO.grid, on: function(){ WB._app = a; WB.nav('/app/' + encodeURIComponent(name)); } },
        { label: 'Open in new tab', icon: ICO.external, on: function(){ if (a.url) window.open(a.url, '_blank'); } },
        { label: 'Copy link', icon: ICO.link, on: function(){ WB.copy(a.url || (location.origin + '/' + name), 'Link'); } },
        { sep: true },
        { header: 'Visibility' }
      ];
      ['public', 'private', 'draft'].forEach(function(s){ if (s !== vis) items.push({ label: (s === 'public' ? 'Publish (make public)' : 'Make ' + s), icon: (s === 'public' ? ICO.globe : s === 'private' ? ICO.lock : ICO.draft), danger: s !== 'public', need: 'app.edit', on: function(){ changeVisibility(name, s, a.label); } }); });
      return items;
    });
    WB.ctx.register('nexus', function(){
      var nx = WB.nexus.active || {};
      return [
        { label: 'Overview', icon: ICO.grid, on: function(){ WB.nav('/overview'); } },
        { label: 'Rename nexus…', icon: ICO.edit, need: 'nexus.manage', on: function(){ st.nxMenu = true; st.nxEditing = true; st.nxEditName = nx.name || ''; renderShell(); } },
        { label: 'Scale up', icon: ICO.activity, need: 'nexus.manage', on: function(){ WB.nav('/upgrade'); } },
        { label: 'Nexus settings', icon: ICO.gear, need: 'nexus.manage', on: function(){ WB.nav('/settings'); } },
        { sep: true },
        { label: 'Switch / create…', icon: ICO.chev, on: function(){ st.nxMenu = true; renderShell(); } }
      ];
    });
    WB.ctx.register('event', function(el){
      var i = +el.getAttribute('data-act-focus'); var e = (WB._activityEvents || [])[i] || {};
      var items = [{ label: 'Open in Activity', icon: ICO.activity, on: function(){ WB._activityFocus = i; WB.nav('/activity'); } }];
      if (e.target) items.push({ label: 'Copy reference', icon: ICO.copy, on: function(){ WB.copy(e.target, 'Reference'); } });
      return items;
    });
    WB.ctx.register('session', function(el){
      var id = el.getAttribute('data-session');
      return [
        { label: 'Open session', icon: ICO.spark, on: function(){ WB._pendingSession = id; WB.nav('/studio'); } },
        { label: 'Copy session id', icon: ICO.copy, on: function(){ WB.copy(id, 'Session id'); } }
      ];
    });
    // Rows owned by lazily-loaded views (Secrets, Team, Storage): the right-click menu surfaces the SAME
    // actions already wired as inline buttons — we synthesize items that click those controls, so the
    // view stays the single owner of the behavior. A `clicker` helper finds a control inside the row.
    function rowClick(el, sel){ var b = el.querySelector(sel); if (b) b.click(); }
    WB.ctx.register('secret', function(el){
      var revealed = !!el.querySelector('[data-act="hide"]');
      return [
        { label: revealed ? 'Hide' : 'Reveal', icon: ICO.key, need: 'secret.manage', on: function(){ rowClick(el, revealed ? '[data-act="hide"]' : '[data-act="reveal"]'); } },
        { label: 'Copy value', icon: ICO.copy, need: 'secret.manage', on: function(){ rowClick(el, '[data-act="copy"]'); } },
        { sep: true },
        { label: 'Edit…', icon: ICO.edit, need: 'secret.manage', on: function(){ rowClick(el, '[data-act="edit"]'); } },
        { label: 'Delete', icon: ICO.trash, danger: true, need: 'secret.manage', on: function(){ rowClick(el, '[data-act="del"]'); } }
      ];
    });
    WB.ctx.register('member', function(el){
      var email = el.getAttribute('data-email') || '';
      var pending = el.getAttribute('data-pending') === '1';
      var items = [];
      if (email) items.push({ label: 'Copy email', icon: ICO.copy, on: function(){ WB.copy(email, 'Email'); } });
      if (pending) items.push({ label: 'Revoke invite', icon: ICO.trash, danger: true, need: 'member.manage', on: function(){ rowClick(el, '[data-form="revoke"]'); } });
      else items.push({ label: 'Remove from nexus', icon: ICO.trash, danger: true, need: 'member.manage', on: function(){ rowClick(el, '[data-form="remove"]'); } });
      return items;
    });
    WB.ctx.register('bucket', function(el){
      var name = el.getAttribute('data-bucket') || '';
      return [{ label: 'Copy bucket name', icon: ICO.copy, on: function(){ WB.copy(name, 'Bucket'); } }];
    });

    // Apps grid (the sidebar's Apps tab) — the hosted workbook surfaces on this nexus. Stale-while-
    // revalidate so it paints last-known instantly; each tile launches the app at its URL.
    function paintApps(){
      if (!document.getElementById('appsGrid')) return;
      WB.swr('apps', function(){ return fetch('/cloud/apps', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var g = document.getElementById('appsGrid'); if (!g) return;
        function visOf(a){ return a.visibility || (a.gated ? 'private' : 'public'); }
        var apps = ((d && d.apps) || []).filter(function(a){ return st.appFilter === 'all' || visOf(a) === st.appFilter; });
        // globe = public/open · lock = gated by our auth guardian · pencil = draft (WIP)
        var BADGE = { draft: { ic: ICO.draft, cls: ' draft', t: 'Draft — work in progress' }, private: { ic: ICO.lock, cls: ' priv', t: 'Private — gated by auth' }, public: { ic: ICO.globe, cls: '', t: 'Public — open' } };
        // Registry the in-app browser (/app view) reads to resolve name → {url,label,...} without a refetch.
        WB._appReg = {}; apps.forEach(function(a){ WB._appReg[a.name] = a; });
        var cards = apps.map(function(a){
          var vis = visOf(a), b = BADGE[vis] || BADGE.public;
          var ic = a.icon ? '<span class="appemoji">' + esc(a.icon) + '</span>'
                          : '<span class="appinit">' + esc((a.label[0] || 'A').toUpperCase()) + '</span>';
          var badge = '<span class="appbadge' + b.cls + '" title="' + b.t + '">' + b.ic + '</span>';
          // Everything opens IN-APP, in the content area's browser chrome (/app/<name>) — never a new tab.
          return '<a class="appcard' + (vis === 'draft' ? ' draft' : '') + '" data-ctx="app" data-open-app="' + esc(a.name) + '" href="#/app/' + esc(encodeURIComponent(a.name)) + '" title="' + esc(a.label) + '">' +
            badge + ic + '<span class="appname">' + esc(a.label) + '</span></a>';
        }).join('');
        // "New app" tile — creates a draft (Phase 4 will replace the prompt with the context modal).
        cards += '<button class="appcard newapp" data-newapp title="New app"><span class="newappplus">+</span><span class="appname">New app</span></button>';
        g.innerHTML = cards || '<div class="treemsg" style="padding:8px 4px">No ' + (st.appFilter !== 'all' ? st.appFilter + ' ' : '') + 'apps</div>';
      });
    }
    // Studio sidebar — recent sessions (GET /cloud/agent/sessions) + draft projects (drafts from /cloud/apps).
    // Lazy + stale-while-revalidate, painted in place so opening Studio doesn't block on the fetch.
    function paintStudio(){
      var box = document.getElementById('studioSide'); if (!box) return;
      WB.swr('agent-sessions', function(){ return fetch('/cloud/agent/sessions', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var el = document.getElementById('studioSide'); if (!el) return;
        var sessions = (d && d.sessions) || [];
        var recent = sessions.length
          ? sessions.map(function(s){ return '<a class="srow" data-ctx="session" data-nav="/studio" href="#/studio" data-session="' + esc(s.id) + '" title="' + esc(s.title || 'Session') + '"><span class="semoji">💬</span><span class="sname">' + esc(s.title || 'Untitled session') + '</span></a>'; }).join('')
          : '<div class="treemsg" style="padding:6px 10px">No sessions yet</div>';
        el.innerHTML = '<div class="sgrp">Recent</div>' + recent + '<div id="studioDrafts"></div>';
      });
      // Draft projects — the apps feed's draft entries are your unpromoted Studio work.
      WB.swr('apps', function(){ return fetch('/cloud/apps', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var dd = document.getElementById('studioDrafts'); if (!dd) return;
        var draftApps = ((d && d.apps) || []).filter(function(a){ return (a.visibility || (a.gated ? 'private' : 'public')) === 'draft'; });
        dd.innerHTML = draftApps.length
          ? '<div class="sgrp">Drafts</div>' + draftApps.map(function(a){ return '<a class="srow" href="' + esc(a.url) + '" target="_blank" rel="noopener"><span class="semoji">📄</span><span class="sname">' + esc(a.label) + '</span><span class="draftpill">DRAFT</span></a>'; }).join('')
          : '';
      });
    }
    // Activity inbox — the event feed, in the sidebar. Click an item → the /activity page shows its
    // context (WB._activityFocus drives the view's selected event). Reuses GET /cloud/activity.
    function paintActivity(){
      var box = document.getElementById('activityInbox'); if (!box) return;
      WB.swr('activity', function(){ return fetch('/cloud/activity', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var el = document.getElementById('activityInbox'); if (!el) return;
        var events = (d && d.events) || [];
        WB._activityEvents = events;   // shared with the /activity view's context pane
        if (!events.length) { el.innerHTML = '<div class="treemsg" style="padding:8px 10px">No activity yet</div>'; return; }
        var now = Math.floor(Date.now() / 1000);
        function ago(sec){ if (!sec) return ''; var x = now - sec; return x < 60 ? x + 's' : x < 3600 ? Math.floor(x/60) + 'm' : x < 86400 ? Math.floor(x/3600) + 'h' : Math.floor(x/86400) + 'd'; }
        var foc = WB._activityFocus;   // null until a row is clicked → the page shows its empty state
        el.innerHTML = events.map(function(e, i){
          var title = e.title || e.kind || 'Event';
          var sub = e.target || e.actor || '';
          return '<button class="ibrow' + (i === foc ? ' on' : '') + '" data-ctx="event" data-act-focus="' + i + '">' +
            '<span class="ibic">' + esc((e.actor || '?').trim()[0].toUpperCase()) + '</span>' +
            '<span class="ibmeta"><span class="ibt">' + esc(title) + '</span>' + (sub ? '<span class="ibs">' + esc(sub) + '</span>' : '') + '</span>' +
            '<span class="ibw">' + esc(ago(e.at)) + '</span></button>';
        }).join('');
      });
    }
    function isBookmarked(path){ return st.bookmarks.some(function(b){ return b.path === path; }); }
    // File search across workspaces — updates the results box IN PLACE (no shell re-render → keeps focus).
    // Recursive file-tree HTML for an open folder at `path` (root mount name = workspace folder).
    function treeHtml(path, depth){
      if (st.treeLoading[path]) return '<div class="treemsg" style="padding-left:' + (depth * 14 + 12) + 'px">Loading…</div>';
      var entries = st.treeData[path];
      if (!entries) return '';
      // File-type filter (the funnel in Files mode). Folders always show so nested matches stay reachable.
      if (st.fileFilter && st.fileFilter !== 'all') {
        entries = entries.filter(function(en){
          if (en.dir) return true;
          var isWork = /\.work$/i.test(en.name);
          return st.fileFilter === 'work' ? isWork : !isWork;
        });
      }
      if (entries.length === 0) return '<div class="treemsg" style="padding-left:' + (depth * 14 + 12) + 'px">Empty</div>';
      return entries.map(function(en){
        var pad = depth * 14 + 12;
        var ficon = WB.fileIcon ? WB.fileIcon(en.name, { dir: en.dir, open: !!st.treeOpen[en.path] }) : '';
        if (en.dir){
          var open = !!st.treeOpen[en.path];
          return '<div class="trow dir' + (open ? ' open' : '') + '" data-ctx="folder" data-tree-toggle="' + esc(en.path) + '" style="padding-left:' + pad + 'px">' +
              '<span class="tchev">' + ICO.chev + '</span>' + ficon + '<span class="tname">' + esc(en.name) + '</span>' +
              '<button class="tbm' + (isBookmarked(en.path) ? ' on' : '') + '" data-bm="' + esc(en.path) + '" data-bml="' + esc(en.name) + '" title="Bookmark">★</button>' +
            '</div>' + (open ? treeHtml(en.path, depth + 1) : '');
        }
        return '<div class="trow file" data-ctx="file" data-tree-file="' + esc(en.path) + '" style="padding-left:' + (pad + 4) + 'px">' +
            ficon + '<span class="tname">' + esc(en.name) + '</span>' +
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

      // (Admin is now a first-class RAIL section with its own sidebar — the old bottom drawer is gone.)

      // Workspaces are Slack-style collapsible GROUPS (rungs): an emoji-squircle + name header with a
      // disclosure caret on the RIGHT; expanding reveals that workspace's real file tree nested under it.
      var wslist = WB.ws.list.map(function (w) {
        if (st.editingId === w.id) return wsEditor(false);
        // The folder on the nexus volume is named by the workspace ID (work_dir(id)), NOT its display
        // name — so the tree is keyed by w.id. (Declared workspaces have a clean slug id, e.g. "marketing".)
        var open = !!st.treeOpen[w.id];
        return '<div class="wsgroup' + (open ? ' open' : '') + '">' +
          '<div class="wshdr" data-ctx="workspace" data-tree-toggle="' + esc(w.id) + '" role="button" tabindex="0" title="' + esc(w.name) + '">' +
            '<span class="wsemoji">' + esc(w.icon || '📁') + '</span>' +
            '<span class="wsname">' + esc(w.name) + '</span>' +
            '<button class="wsmore-btn" data-wsmore="' + esc(w.id) + '" title="More" aria-label="More">⋯</button>' +
            '<span class="wschev">' + ICO.chev + '</span>' +
          '</div>' +
          (open ? '<div class="wstree" data-ws-tree="' + esc(w.id) + '">' + treeHtml(w.id, 1) + '</div>' : '') +
        '</div>';
      }).join('');
      if (st.editingId === 'new') wslist += wsEditor(true);
      if (WB.ws.list.length === 0) wslist += '<div class="omempty">No workspaces yet</div>';

      // Pinned — quick-launch shortcuts below Workspaces (after a divider). Pin from the workspace
      // explorer (★); clicking opens the item in the Workspaces page. Re-read each render so explorer
      // pins reflect live; rail mode shows just the icon.
      var nxMenu = st.nxMenu ? nexusMenu(nx) : '';

      // Preserve the live view node across shell re-renders. A sidebar-only change (opening the nexus
      // menu / admin drawer / a ws menu) calls renderShell() WITHOUT renderView() — without this the
      // rebuilt #view would be empty and the page would blank. We move the existing (live, with its
      // listeners) #view back into the new shell. On a real nav, renderView() runs after and refills it.
      var prevView = document.getElementById('view');

      // ── Slack-style RAIL: nexus selector (top) → Studio/Apps/Activity/Files (icon-above-text) →
      // Admin + You grouped at the bottom. The nexus tile opens the switch menu (switch/rename/create).
      var section = sectionFor(p);
      var nexTile = '<button class="nextile' + (st.nxMenu ? ' on' : '') + '" data-ctx="nexus" data-nxmenu title="' + esc(nxLabel) + '">' +
          '<span class="nexinit' + ((nx && nx.icon) ? ' emoji' : '') + '">' + ((nx && nx.icon) ? esc(nx.icon) : esc(inits(nxLabel))) + '</span><span class="nexcar">' + ICO.chev + '</span></button>' +
        (st.nxMenu ? nexusMenu(nx) : '');
      var RAIL_SECS = [
        { id: 'studio', ico: ICO.spark, label: 'Studio', go: '/studio' },
        { id: 'apps', ico: ICO.grid, label: 'Apps', go: '/' },
        { id: 'activity', ico: ICO.activity, label: 'Activity', go: '/activity' },
        { id: 'files', ico: ICO.files, label: 'Files', go: '/workspaces' }
      ];
      var railsecs = RAIL_SECS.map(function (s) {
        return '<a class="railsec' + (section === s.id ? ' on' : '') + '" data-nav="' + s.go + '" href="#' + s.go +
          '" title="' + s.label + '"><span class="rsico">' + s.ico + '</span><span class="rslbl">' + s.label + '</span></a>';
      }).join('');

      // ── per-surface SIDEBAR body — swaps with the active rail section ──
      var SECTITLE = { studio: 'Studio', apps: 'Apps', activity: 'Activity', files: 'Files', integrations: 'Integrations', admin: 'Admin', account: 'You' };
      var isBrowse = section === 'apps' || section === 'files';   // apps/files get the filter funnel + search + pins
      if (isBrowse) st.sideMode = section;   // keep the filter funnel (filterMenu/filterActive) keyed to the active surface
      var sideBody;
      if (section === 'files') sideBody = '<div class="wsgroups">' + wslist + '</div>';
      else if (section === 'apps') sideBody = '<div class="appsgrid" id="appsGrid"><div class="treemsg" style="padding:8px 4px">Loading apps…</div></div>';
      // Studio — ChatGPT-style: New session + recent sessions + draft projects (lazy-painted into #studioSide).
      else if (section === 'studio') sideBody =
          '<button class="newsess" data-nav="/studio"><span class="nsico">' + ICO.plus + '</span>New session</button>' +
          '<div id="studioSide"><div class="treemsg" style="padding:8px 4px">Loading sessions…</div></div>';
      // Activity — the inbox lives in the sidebar; the page shows the selected event's context (lazy → #activityInbox).
      else if (section === 'activity') sideBody = '<div id="activityInbox"><div class="treemsg" style="padding:8px 4px">Loading…</div></div>';
      else if (section === 'admin') sideBody = '<nav class="nxnav">' +
          navlink('/usage', ICO.gauge, 'Usage & billing', p) + navlink('/storage', ICO.database, 'Storage', p) +
          navlink('/team', ICO.users, 'Users', p) + navlink('/secrets', ICO.key, 'Secrets', p) + '</nav>';
      // You — personal account surface (folds the old avatar popover into a full sidebar).
      else if (section === 'account') sideBody = '<nav class="nxnav">' +
          navlink('/settings', ICO.gear, 'Profile', p) +
          '<button class="nxlink" data-theme-toggle>' + ICO.spark + '<span class="lbl">Appearance</span></button>' +
          navlink('/settings', ICO.activity, 'Notifications', p) + navlink('/secrets', ICO.key, 'API tokens', p) +
          '<a class="nxlink" href="/auth/logout">' + ICO.logout + '<span class="lbl">Sign out</span></a></nav>';
      else sideBody = '';

      root.innerHTML =
      '<div id="app" class="' + (st.rail ? 'rail' : '') + '" style="--section:' + sectionAccent(p) + '">' +
        '<div class="topdna">' + WB.dna(11, 8) + '</div>' +
        '<div class="nexrail">' +
          '<div class="nextilewrap">' + nexTile + '</div>' +
          '<div class="raildiv"></div>' +
          '<nav class="railsecs">' + railsecs + '</nav>' +
          '<div class="nexrail-grow"></div>' +
          '<div class="railbottom">' +
            '<a class="railsec' + (section === 'integrations' ? ' on' : '') + '" data-nav="/integrations" href="#/integrations" title="Integrations"><span class="rsico">' + ICO.plug + '</span><span class="rslbl">Integrations</span></a>' +
            '<a class="railsec' + (section === 'admin' ? ' on' : '') + '" data-nav="/usage" href="#/usage" title="Admin"><span class="rsico">' + ICO.admin + '</span><span class="rslbl">Admin</span></a>' +
            '<a class="railsec railavbtn' + (section === 'account' ? ' on' : '') + '" data-nav="/settings" href="#/settings" title="' + esc(user.name) + '"><span class="railav">' + esc(user.initial) + '</span><span class="rslbl">You</span></a>' +
          '</div>' +
        '</div>' +
        '<aside class="side">' +
          '<div class="sidehd">' +
            '<span class="sidehd-t">' + (SECTITLE[section] || '') + '</span>' +
            '<button class="sidehd-ic" data-palette title="Search (⌘K)" aria-label="Search">' + ICO.search + '</button>' +
            (isBrowse ? '<div class="filterwrap"><button class="sidehd-ic' + (filterActive() ? ' on' : '') + '" data-filter-toggle title="Filter" aria-label="Filter">' + ICO.filter + '</button>' + (st.filterOpen ? filterMenu() : '') + '</div>' : '') +
            '<button class="sidehd-ic" data-rail-toggle title="Collapse sidebar" aria-label="Collapse sidebar">' + ICO.rail + '</button>' +
          '</div>' +
          sideBody +
        '</aside>' +
        '<div class="main">' + crumbs + (fb ? '<div id="view" class="fullbleed"></div>' : '<div class="wrap" id="view"></div>') + '</div>' +
      '</div>';

      if (prevView && prevView.childNodes.length) {
        var slot = root.querySelector('#view');
        if (slot) { prevView.className = slot.className; slot.parentNode.replaceChild(prevView, slot); }
      }

      if (st.pickerOpen) { var ph = root.querySelector('#wsPicker'); if (ph) WB.emojiPicker(ph, function (u) { st.editIcon = u; st.pickerOpen = false; renderShell(); renderView(); }); }
      if (section === 'apps') paintApps();        // Apps surface → load the apps grid
      else if (section === 'studio') paintStudio();
      else if (section === 'activity') paintActivity();
    }
    // Let other views (the workspace explorer) refresh the sidebar after a pin/unpin so Pinned updates live.
    WB.refreshSidebar = function(){ try { renderShell(); } catch (e) {} };
    function navlink(href, ico, label, p){ return '<a class="nxlink' + (p === href ? ' on' : '') + '" data-nav="' + href + '" href="#' + href + '" title="' + esc(label) + '">' + ico + '<span class="lbl">' + esc(label) + '</span></a>'; }
    // The funnel shows a dot when a non-default filter is active for the CURRENT tab.
    function filterActive(){ return st.sideMode === 'files' ? st.fileFilter !== 'all' : st.appFilter !== 'all'; }
    // Context-dependent filter popover — Apps → visibility (public/private), Files → file type.
    function fopt(kind, val, label, ico){
      var cur = kind === 'app' ? st.appFilter : st.fileFilter;
      return '<button class="filteropt' + (cur === val ? ' on' : '') + '" data-' + kind + 'filter="' + val + '">' +
        (ico ? '<span class="fopti">' + ico + '</span>' : '<span class="fopti"></span>') +
        '<span>' + esc(label) + '</span>' + (cur === val ? '<span class="fcheck">✓</span>' : '') + '</button>';
    }
    function filterMenu(){
      if (st.sideMode === 'files') {
        return '<div class="filtermenu" role="menu"><div class="filterhd">Files</div>' +
          fopt('file', 'all', 'All files') + fopt('file', 'work', 'Workbooks (.work)') + fopt('file', 'assets', 'Assets') +
        '</div>';
      }
      return '<div class="filtermenu" role="menu"><div class="filterhd">Apps</div>' +
        fopt('app', 'all', 'All') + fopt('app', 'public', 'Public', ICO.globe) + fopt('app', 'private', 'Private', ICO.lock) + fopt('app', 'draft', 'Drafts', ICO.draft) +
      '</div>';
    }
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
        h += '<a class="omitem" data-nav="/overview" href="#/overview"><span class="av sm plus">▦</span><span class="omname">Nexus overview</span></a>';
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
      var openApp = t.closest && t.closest('[data-open-app]');
      if (openApp) { e.preventDefault(); var an = openApp.getAttribute('data-open-app');
        WB._app = (WB._appReg && WB._appReg[an]) || null; WB.nav('/app/' + encodeURIComponent(an)); return; }
      var navEl = t.closest && t.closest('[data-nav]'); if (navEl) { e.preventDefault(); WB.nav(navEl.getAttribute('data-nav')); return; }
      if (t.closest && t.closest('[data-crumb-back]')) { var ret = WB.settingsReturn; WB.settingsReturn = null; WB.nav((ret && ret.path) || '/'); return; }
      if (t.closest && t.closest('[data-theme-toggle]')) { var cur = document.documentElement.getAttribute('data-theme') || 'dark'; var nt = cur === 'dark' ? 'light' : 'dark'; document.documentElement.setAttribute('data-theme', nt); try { localStorage.setItem('wb-theme', nt); } catch (er) {} renderShell(); renderView(); return; }
      if (t.closest && t.closest('[data-rail-toggle]')) { st.rail = !st.rail; try { localStorage.setItem('wb-rail', st.rail ? '1' : '0'); } catch (er) {} renderShell(); return; }
      if (t.closest && t.closest('[data-filter-toggle]')) { st.filterOpen = !st.filterOpen; renderShell(); return; }
      var afl = t.closest && t.closest('[data-appfilter]'); if (afl) { st.appFilter = afl.getAttribute('data-appfilter'); try { localStorage.setItem('wb-appfilter', st.appFilter); } catch (er) {} st.filterOpen = false; renderShell(); return; }
      var ffl = t.closest && t.closest('[data-filefilter]'); if (ffl) { st.fileFilter = ffl.getAttribute('data-filefilter'); try { localStorage.setItem('wb-filefilter', st.fileFilter); } catch (er) {} st.filterOpen = false; renderShell(); return; }
      if (t.closest && t.closest('[data-newapp]')) {
        var nm = (window.prompt && window.prompt('Name your new app (a draft):', '')) || '';
        nm = nm.trim(); if (!nm) return;
        fetch('/cloud/draft', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: nm }) })
          .then(function(r){ return r.json(); })
          .then(function(d){ if (d && d.ok) { WB.toast('Draft “' + nm + '” created'); setTimeout(function(){ WB.cache.set('apps', null); paintApps(); }, 900); } else { WB.toast((d && d.error) || 'Couldn’t create draft', 'bad'); } })
          .catch(function(){ WB.toast('Couldn’t create draft', 'bad'); });
        return;
      }
      if (t.closest && t.closest('[data-palette]')) { WB.palette(); return; }
      // Activity inbox row → focus that event; the /activity view renders its context in the page.
      var actf = t.closest && t.closest('[data-act-focus]');
      if (actf) { WB._activityFocus = +actf.getAttribute('data-act-focus');
        document.querySelectorAll('.ibrow').forEach(function(r){ r.classList.toggle('on', r === actf); });
        if (WB._activityRender) WB._activityRender(WB._activityFocus); else WB.nav('/activity');
        return; }
      // Studio session row → remember which session to open, then let data-nav route to /studio.
      var sess = t.closest && t.closest('[data-session]');
      if (sess) { WB._pendingSession = sess.getAttribute('data-session'); }   // fall through to data-nav
      var pinx = t.closest && t.closest('[data-pin-x]'); if (pinx) { e.stopPropagation(); toggleBookmark(pinx.getAttribute('data-pin-x')); return; }
      var pino = t.closest && t.closest('[data-pin-open]'); if (pino) { WB._pendingFile = pino.getAttribute('data-pin-open'); WB.nav('/workspaces'); return; }
      if (t.closest && t.closest('[data-nxmenu]')) { st.nxMenu = !st.nxMenu; st.wsMenu = false; renderShell(); return; }
      var nxsw = t.closest && t.closest('[data-nxswitch]'); if (nxsw) { WB.nexus.setActive(nxsw.getAttribute('data-nxswitch')); st.nxMenu = false; renderShell(); if (ROUTE.path !== '/') WB.nav('/'); else renderView(); return; }
      if (t.closest && t.closest('[data-nxedit]')) { e.stopPropagation(); st.nxEditing = true; st.nxEditName = (WB.nexus.active && WB.nexus.active.name) || ''; renderShell(); return; }
      if (t.closest && t.closest('[data-nxsave]')) { saveNxEdit(); return; }
      if (t.closest && t.closest('[data-nxcreate]')) { st.nxMenu = false; renderShell(); openNewNexus(); return; }
      if (t.closest && t.closest('[data-wsnew]')) { st.editingId = 'new'; st.editName = ''; st.editIcon = ''; st.pickerOpen = false; renderShell(); return; }
      var bmtog = t.closest && t.closest('[data-bm]'); if (bmtog) { e.stopPropagation(); toggleBookmark(bmtog.getAttribute('data-bm'), bmtog.getAttribute('data-bml')); return; }
      var ttog = t.closest && t.closest('[data-tree-toggle]');
      if (ttog && !(t.closest && t.closest('[data-wsmore]'))) {   // ⋯ inside a group header opens the menu, not the group
        var tp = ttog.getAttribute('data-tree-toggle');
        var isWs = (WB.ws.list || []).some(function (w) { return w.id === tp; });
        if (st.treeOpen[tp]) delete st.treeOpen[tp]; else { st.treeOpen[tp] = true; loadTree(tp); }
        // A workspace GROUP toggle adds/removes its .wstree → needs a shell re-render (view is preserved);
        // a dir toggle INSIDE an open tree only repaints that tree in place.
        if (isWs) renderShell(); else paintTree();
        return;
      }
      var tfile = t.closest && t.closest('[data-tree-file]'); if (tfile) { var fp = tfile.getAttribute('data-tree-file'); WB._pendingFile = fp; if (WB.openInExplorer && ROUTE.path === '/workspaces') WB.openInExplorer(fp); else WB.nav('/workspaces'); return; }
      // The ⋯ button opens the SAME menu as right-clicking the workspace — converged onto the WB.ctx engine.
      var wsmore = t.closest && t.closest('[data-wsmore]'); if (wsmore) { e.stopPropagation(); WB.ctx.openFrom(wsmore, wsCtxItems(wsmore.getAttribute('data-wsmore'))); return; }
      if (t.closest && t.closest('[data-wspick]')) { syncEditName(); st.pickerOpen = !st.pickerOpen; renderShell(); return; }
      if (t.closest && t.closest('[data-wsinitials]')) { st.editIcon = ''; st.pickerOpen = false; renderShell(); return; }
      if (t.closest && t.closest('[data-wscancel]')) { st.editingId = null; st.pickerOpen = false; renderShell(); return; }
      if (t.closest && t.closest('[data-wssave]')) { saveEdit(); return; }
      if (t.closest && t.closest('[data-wsdel]')) { deleteWs(); return; }
      if (st.filterOpen) { st.filterOpen = false; renderShell(); return; } // outside click closes the filter popover
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

    async function route(){ runCleanup(); var h = location.hash.slice(1) || '/'; ROUTE.path = h; await ensureView(h); renderShell(); await renderView(); }
    window.addEventListener('hashchange', route);

    // ── home view ('/') — reproduced from routes/+page.svelte ────────────────────────────────────
    WB.scopedStyles('/overview', '.empty { text-align: center; color: var(--dim); }\n.metrics { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin: 4px 0 18px; }\n.metric { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; }\n.mlabel { font: 700 10px var(--read); letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }\n.mbig { font: 700 32px var(--read); color: var(--ink); margin: 6px 0 12px; letter-spacing: -0.02em; }\n.mbar { height: 7px; border-radius: 4px; background: var(--line); overflow: hidden; }\n.mbar i { display: block; height: 100%; background: var(--sky); border-radius: 4px; }\n.msub { font: 500 12px var(--read); color: var(--dim); margin-top: 9px; }\n.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }\n.dcard { display: block; background: var(--card); border: 1px solid var(--line); border-radius: 13px; padding: 16px 18px; text-decoration: none; color: inherit; transition: border-color 0.12s, transform 0.08s; }\n.dcard:hover { border-color: var(--stroke); transform: translateY(-1px); }\n.ddot { display: inline-block; width: 10px; height: 10px; border-radius: 4px; margin-bottom: 10px; }\n.dt { font: 600 15px var(--read); color: var(--ink); }\n.ds { font: 500 12.5px var(--read); color: var(--dim); margin-top: 3px; }');
    // Apps landing ('/') — a clean empty state. The sidebar lists your apps; pick one and it opens
    // in the content-area browser (/app). The nexus overview (storage/load) moved to '/overview'.
    WB.view('/', { title: 'Apps', accent: 'var(--mint)', async render(el){
      el.innerHTML = '<div class="appsempty"><div class="appsempty-ic">' + ICO.grid + '</div>' +
        '<div class="appsempty-t">Open an app</div>' +
        '<div class="appsempty-s">Pick an app from the sidebar to open it here. New here? Use <b>New app</b> in the sidebar to start one.</div></div>';
    } });
    WB.scopedStyles('/', '.appsempty { height: 100%; min-height: 56vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; text-align: center; color: var(--dim); }\n.appsempty-ic { color: var(--stroke); transform: scale(2.2); margin-bottom: 8px; }\n.appsempty-t { font: 600 20px var(--read); color: var(--ink); }\n.appsempty-s { font: 500 13.5px var(--read); color: var(--dim); max-width: 360px; line-height: 1.5; }');

    WB.view('/overview', { title: 'Nexus', accent: 'var(--mint)', async render(el){
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
      // Material icons load in the BACKGROUND (don't block first paint); generic file/folder glyphs
      // show immediately, refined when the manifest arrives → refresh the tree.
      WB.loadIcons().then(function(){ try { paintTree(); } catch (e) {} });
      try { await WB.nexus.load(); } catch (e) {}
      var defaultWs = (WB.profile && WB.profile.orgName) || (WB.user.email ? WB.user.email.split('@')[0] : '') || 'Workspace';
      try { await WB.ws.load(defaultWs); } catch (e) {}
      await route();
    };
    // run after all view scripts have registered
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function(){ setTimeout(WB.start, 0); });
    else setTimeout(WB.start, 0);
  })();
