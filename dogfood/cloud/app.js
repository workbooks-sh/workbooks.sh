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
      // Nexus-wide secrets — the editable store Nexus.Secrets reads (store-first, env fallback).
      async listNexusEnv(){ try { return (await plat('/env?scope=nexus')).env; } catch (e) { return []; } },
      createNexusEnv(o){ return plat('/env', { method: 'POST', body: { name: o.name, value: o.value, scope: 'nexus' } }); },
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
      modal.innerHTML = '<div class="sheet ask"><h2>' + esc(o.title || 'Are you sure?') + '</h2>' +
        (o.body ? '<p class="sub">' + esc(o.body) + '</p>' : '') + '<div class="foot"><span></span><div style="display:flex;gap:10px">' +
        '<button class="btn" data-x="0">Cancel</button><button class="btn ' + (o.danger ? 'danger' : 'primary') + '" data-x="1">' + esc(o.confirm || 'Confirm') + '</button></div></div></div>';
      function done(v){ modal.remove(); resolve(v); }
      modal.addEventListener('click', function (e) { if (e.target === modal) done(false);
        var x = e.target.closest('[data-x]'); if (x) done(x.getAttribute('data-x') === '1'); });
      document.body.appendChild(modal); }); };

    // A single-field prompt modal (rename / new file name). Resolves the trimmed value, or null on cancel.
    WB.prompt = function (o) { o = o || {}; return new Promise(function (resolve) {
      var modal = document.createElement('div'); modal.className = 'modal';
      modal.innerHTML = '<div class="sheet ask"><h2>' + esc(o.title || 'Enter a value') + '</h2>' +
        (o.body ? '<p class="sub">' + esc(o.body) + '</p>' : '') +
        '<input class="winput" id="wbPromptIn" autocomplete="off" spellcheck="false" placeholder="' + esc(o.placeholder || '') + '" />' +
        '<div class="foot"><span></span><div style="display:flex;gap:10px">' +
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
      'autopoet.manage': 'admin',
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
      // Avatar lives in resource Profile (not /me); hydrate the rail tile from the local cache the
      // profile view writes, so the photo shows on every page without re-fetching the profile.
      try { var av = localStorage.getItem('wb-avatar:' + (WB.user.email || 'me').toLowerCase()); if (av) WB.profile.avatar = av; } catch (e) {}
      if (me.role) WB.role = me.role;
    } catch (e) {} }

    // ── router + shell ──────────────────────────────────────────────────────────────────────────
    var ROUTE = { path: '/', params: {} };
    WB.route = ROUTE;
    // Sign out — POST to /auth/logout (the handler is POST-only and clears the session cookie), then
    // hard-redirect to the login page. A GET <a href> never hit the handler, so the cookie survived and
    // a refresh "logged you back in" — this does the real POST and only leaves once the cookie is cleared.
    WB.logout = function () {
      fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' })
        .catch(function () {})
        .then(function () { location.assign('/login/'); });
      return false;
    };
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
      { label: 'Inbox', icon: '✉', go: '/activity' },
      { label: 'Workspaces', icon: '▦', go: '/workspaces' },
      { label: 'Usage & billing', icon: '◷', go: '/usage' },
      { label: 'Storage', icon: '▤', go: '/storage' },
      { label: 'Team', icon: '👥', go: '/team' },
      { label: 'Secrets', icon: '🔑', go: '/secrets' },
      { label: 'Toolkits', icon: '🧰', go: '/toolkits' },
      { label: 'You — profile', icon: '◐', go: '/profile' }
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

    // Context picker — a MULTI-SELECT cousin of the palette, used by the composer's "Add context" button.
    // Searchable over workspaces, spaces, and files (/cloud/search); also a drop target for files. Resolves
    // to an array of chosen items ({ type, name, ref, icon, sub }) that become composer context chips.
    WB.contextPicker = function(){
      return new Promise(function(resolve){
        if (document.getElementById('wbCtxPick')) return resolve([]);
        var ov = document.createElement('div'); ov.id = 'wbCtxPick'; ov.className = 'palette-ov';
        ov.innerHTML = '<div class="palette ctxpick">' +
          '<input class="palette-in" placeholder="Search files, workspaces, spaces — or drop files here…" autocomplete="off" />' +
          '<div class="palette-res"></div>' +
          '<div class="ctxfoot"><span class="ctxcount">Nothing selected</span>' +
            '<div class="ctxbtns"><button class="btn sm" data-cancel>Cancel</button><button class="btn sm primary" data-add>Add</button></div></div>' +
          '</div>';
        document.body.appendChild(ov);
        var box = ov.querySelector('.palette'), input = ov.querySelector('.palette-in'), res = ov.querySelector('.palette-res');
        var count = ov.querySelector('.ctxcount');
        var items = [], sel = 0, picked = {};
        function key(it){ return it.type + ':' + (it.ref || it.name); }
        function done(arr){ ov.remove(); resolve(arr || []); }
        function updFoot(){ var n = Object.keys(picked).length; count.textContent = n ? (n + ' selected') : 'Nothing selected'; }
        function toggle(it){ var k = key(it); if (picked[k]) delete picked[k]; else picked[k] = it; updFoot(); render(); }
        function render(){
          res.innerHTML = items.length ? items.map(function(it, i){
            var on = !!picked[key(it)];
            return '<div class="palette-item ctxitem' + (i === sel ? ' on' : '') + (on ? ' sel' : '') + '" data-i="' + i + '">' +
              '<span class="palette-ic">' + esc(it.icon || '›') + '</span><span class="palette-lb">' + esc(it.name) + '</span>' +
              (it.sub ? '<span class="palette-sub">' + esc(it.sub) + '</span>' : '') +
              '<span class="ctxcheck">' + (on ? '✓' : '') + '</span></div>';
          }).join('') : '<div class="palette-empty">No matches</div>';
          res.querySelectorAll('[data-i]').forEach(function(el){ el.onclick = function(){ toggle(items[+el.getAttribute('data-i')]); }; });
        }
        function base(q){
          return (WB.ws.list || []).filter(function(w){ return !q || w.name.toLowerCase().indexOf(q) >= 0; })
            .map(function(w){ return { type: 'workspace', name: w.name, ref: w.id, icon: '▦', sub: 'workspace' }; });
        }
        function refresh(){
          var q = input.value.trim().toLowerCase();
          items = base(q); sel = 0; render();
          if (q) fetch('/cloud/search?q=' + encodeURIComponent(q), { credentials: 'same-origin' })
            .then(function(r){ return r.json(); }).then(function(d){
              if (input.value.trim().toLowerCase() !== q) return;
              var files = ((d && d.results) || []).slice(0, 12).map(function(f){ return { type: 'file', name: f.name, ref: f.path, icon: '📄', sub: f.workspace }; });
              items = base(q).concat(files); render();
            }).catch(function(){});
        }
        input.addEventListener('input', refresh);
        input.addEventListener('keydown', function(e){
          if (e.key === 'Escape') return done([]);
          if (e.key === 'ArrowDown') { sel = Math.min(sel + 1, items.length - 1); render(); e.preventDefault(); }
          if (e.key === 'ArrowUp') { sel = Math.max(sel - 1, 0); render(); e.preventDefault(); }
          if (e.key === 'Enter') { e.preventDefault();
            if ((e.metaKey || e.ctrlKey)) return done(Object.keys(picked).map(function(k){ return picked[k]; }));
            if (items[sel]) toggle(items[sel]); }
        });
        // Drag-and-drop files straight onto the picker → added as file context.
        box.addEventListener('dragover', function(e){ e.preventDefault(); box.classList.add('drop'); });
        box.addEventListener('dragleave', function(e){ if (e.target === box) box.classList.remove('drop'); });
        box.addEventListener('drop', function(e){ e.preventDefault(); box.classList.remove('drop');
          Array.from((e.dataTransfer && e.dataTransfer.files) || []).forEach(function(f){
            picked['file:' + f.name] = { type: 'file', name: f.name, ref: f.name, icon: '📄', sub: 'upload', file: f }; });
          updFoot(); render(); });
        ov.addEventListener('click', function(e){
          if (e.target === ov) return done([]);
          if (e.target.closest('[data-cancel]')) return done([]);
          if (e.target.closest('[data-add]')) return done(Object.keys(picked).map(function(k){ return picked[k]; }));
        });
        refresh(); input.focus();
      });
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
      '/profile': 'var(--peach)', '/settings': 'var(--peach)', '/autopoet': 'var(--violet)', '/workspace': 'var(--peach)', '/database': 'var(--mint)', '/upgrade': 'var(--mint)',
      '/inference': 'var(--violet)', '/agent': 'var(--mint)', '/data': 'var(--sky)' };
    function sectionAccent(p){ for (var k in ACCENT) { if (p.indexOf(k) === 0) return ACCENT[k]; } return 'var(--mint)'; }
    // Which RAIL section a route belongs to — drives the active rail tab + which per-surface sidebar shows.
    var ADMIN_ROUTES = ['/autopoet', '/usage', '/storage', '/team', '/secrets', '/database', '/upgrade', '/inference'];
    function sectionFor(p){
      if (p.indexOf('/toolkits') === 0) return 'toolkits';   // own rail section — providers + standalone toolkits
      // Data explorer — its own rail section. Precise match so it never swallows /database (the PG addon).
      if (p === '/data' || p.indexOf('/data/') === 0 || p.indexOf('/data?') === 0) return 'data';
      // /agent/<name> is the agent editor, launched from the Studio composer — keep the Studio surface.
      if (p.indexOf('/studio') === 0 || p.indexOf('/create') === 0 || p.indexOf('/agent') === 0) return 'studio';
      if (p.indexOf('/activity') === 0 || p.indexOf('/runs') === 0 || p.indexOf('/tasks') === 0 || p.indexOf('/issues') === 0) return 'activity';
      if (p.indexOf('/workspace') === 0) return 'files';
      if (p.indexOf('/profile') === 0 || p.indexOf('/settings') === 0) return 'account';   // the "You" surface
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
      '/activity': 'activity', '/runs': 'runs', '/tasks': 'tasks', '/issues': 'issues', '/data': 'data', '/database': 'database', '/denied': 'denied', '/autopoet': 'autopoet',
      '/toolkits': 'toolkits', '/nexuses': 'nexuses', '/secrets': 'secrets', '/profile': 'profile', '/settings': 'profile',
      '/shared': 'shared', '/storage': 'storage', '/studio': 'studio', '/create': 'studio', '/usage': 'studio',
      '/team': 'team', '/upgrade': 'upgrade', '/welcome': 'welcome', '/workspace/env': 'workspace-env',
      '/workspace/history': 'workspace-history', '/workspace/members': 'workspace-members',
      '/workspace/sharing': 'workspace-sharing', '/workspace': 'workspace', '/workspaces': 'workspaces',
      '/inference': 'inference', '/agent': 'agent'
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
      gauge: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4L12 8" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 8L6.5 10.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M17.5 10.5L20 8" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M3 17H6" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 17L13 11" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M18 17H21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M8.5 20.001H4C2.74418 18.3295 2 16.2516 2 14C2 8.47715 6.47715 4 12 4C17.5228 4 22 8.47715 22 14C22 16.2516 21.2558 18.3295 20 20.001L15.5 20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 23C13.6569 23 15 21.6569 15 20C15 18.3431 13.6569 17 12 17C10.3431 17 9 18.3431 9 20C9 21.6569 10.3431 23 12 23Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      database: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12V18C5 18 5 21 12 21C19 21 19 18 19 18V12" stroke="currentColor" stroke-width="1.5"/><path d="M5 6V12C5 12 5 15 12 15C19 15 19 12 19 12V6" stroke="currentColor" stroke-width="1.5"/><path d="M12 3C19 3 19 6 19 6C19 6 19 9 12 9C5 9 5 6 5 6C5 6 5 3 12 3Z" stroke="currentColor" stroke-width="1.5"/></svg>',
      // Spreadsheet/table — the Data surface (distinct from the admin "database" cylinder).
      sheet: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9H21"/><path d="M3 15H21"/><path d="M9 3V21"/><path d="M15 3V21"/></svg>',
      users: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M1 20V19C1 15.134 4.13401 12 8 12V12C11.866 12 15 15.134 15 19V20" stroke="currentColor" stroke-linecap="round"/><path d="M13 14V14C13 11.2386 15.2386 9 18 9V9C20.7614 9 23 11.2386 23 14V14.5" stroke="currentColor" stroke-linecap="round"/><path d="M8 12C10.2091 12 12 10.2091 12 8C12 5.79086 10.2091 4 8 4C5.79086 4 4 5.79086 4 8C4 10.2091 5.79086 12 8 12Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M18 9C19.6569 9 21 7.65685 21 6C21 4.34315 19.6569 3 18 3C16.3431 3 15 4.34315 15 6C15 7.65685 16.3431 9 18 9Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      key: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 12C10 14.2091 8.20914 16 6 16C3.79086 16 2 14.2091 2 12C2 9.79086 3.79086 8 6 8C8.20914 8 10 9.79086 10 12ZM10 12H22V15" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M18 12V15" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      plus: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6 12H12M18 12H12M12 12V6M12 12V18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      apps: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14 20.4V14.6C14 14.2686 14.2686 14 14.6 14H20.4C20.7314 14 21 14.2686 21 14.6V20.4C21 20.7314 20.7314 21 20.4 21H14.6C14.2686 21 14 20.7314 14 20.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M3 20.4V14.6C3 14.2686 3.26863 14 3.6 14H9.4C9.73137 14 10 14.2686 10 14.6V20.4C10 20.7314 9.73137 21 9.4 21H3.6C3.26863 21 3 20.7314 3 20.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M14 9.4V3.6C14 3.26863 14.2686 3 14.6 3H20.4C20.7314 3 21 3.26863 21 3.6V9.4C21 9.73137 20.7314 10 20.4 10H14.6C14.2686 10 14 9.73137 14 9.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M3 9.4V3.6C3 3.26863 3.26863 3 3.6 3H9.4C9.73137 3 10 3.26863 10 3.6V9.4C10 9.73137 9.73137 10 9.4 10H3.6C3.26863 10 3 9.73137 3 9.4Z" stroke="currentColor" stroke-width="1.5"/></svg>',
      spark: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M8 15C12.8747 15 15 12.949 15 8C15 12.949 17.1104 15 22 15C17.1104 15 15 17.1104 15 22C15 17.1104 12.8747 15 8 15Z" stroke="currentColor" stroke-linejoin="round"/><path d="M2 6.5C5.13376 6.5 6.5 5.18153 6.5 2C6.5 5.18153 7.85669 6.5 11 6.5C7.85669 6.5 6.5 7.85669 6.5 11C6.5 7.85669 5.13376 6.5 2 6.5Z" stroke="currentColor" stroke-linejoin="round"/></svg>',
      activity: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M3.2 7L12 13L20.8 7"/></svg>',
      admin: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3.57143 8C3.39038 6.73263 3.23403 5.63823 3.13088 4.91614C3.05698 4.39885 3.39389 3.91247 3.90398 3.79912L11.5661 2.09641C11.8519 2.03291 12.1481 2.03291 12.4339 2.09641L20.096 3.79912C20.6061 3.91247 20.943 4.39885 20.8691 4.91614C20.766 5.63823 20.6096 6.73263 20.4286 8M3.57143 8H20.4286M3.57143 8C3.87997 10.1598 4.26028 12.822 4.57143 15M20.4286 8C20.12 10.1598 19.7397 12.822 19.4286 15M19.4286 15C19.2567 16.2032 19.1059 17.2586 19 18C18.9293 18.495 18.5 21.5 12 21.5C5.5 21.5 5.07071 18.495 5 18C4.89409 17.2586 4.74331 16.2032 4.57143 15M19.4286 15H4.57143" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      chev: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6L15 12L9 18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      hash: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3L6 21" stroke="currentColor" stroke-linecap="round"/><path d="M20.5 16H2.5" stroke="currentColor" stroke-linecap="round"/><path d="M22 7H4" stroke="currentColor" stroke-linecap="round"/><path d="M18 3L14 21" stroke="currentColor" stroke-linecap="round"/></svg>',
      plug: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14V18.4C4 18.7314 4.26863 19 4.6 19H10" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 14V18.4C19 18.7314 18.7314 19 18.4 19H14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M14 5H18.4C18.7314 5 19 5.26863 19 5.6V10" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 10V5.6C4 5.26863 4.26863 5 4.6 5H10" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M14 19V20C14 21.1046 13.1046 22 12 22C10.8954 22 10 21.1046 10 20V19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 10H5C6.10457 10 7 10.8954 7 12C7 13.1046 6.10457 14 5 14H4" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 10H20C21.1046 10 22 10.8954 22 12C22 13.1046 21.1046 14 20 14H19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M14 5V4C14 2.89543 13.1046 2 12 2C10.8954 2 10 2.89543 10 4V5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      toolbox: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M10.0503 10.6066L2.97923 17.6777C2.19818 18.4587 2.19818 19.7251 2.97923 20.5061V20.5061C3.76027 21.2872 5.0266 21.2872 5.80765 20.5061L12.8787 13.4351" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M17.1927 13.7994L21.071 17.6777C21.8521 18.4587 21.8521 19.7251 21.071 20.5061V20.5061C20.29 21.2872 19.0236 21.2872 18.2426 20.5061L12.0341 14.2977" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M6.73267 5.90381L4.61135 6.61092L2.49003 3.07539L3.90424 1.66117L7.43978 3.78249L6.73267 5.90381ZM6.73267 5.90381L9.5629 8.73404" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M10.0503 10.6066C9.2065 8.45359 9.37147 5.62861 11.111 3.8891C12.8505 2.14958 16.0607 1.76778 17.8285 2.82844L14.7878 5.86911L14.5052 8.98015L17.6162 8.69754L20.6569 5.65686C21.7176 7.42463 21.3358 10.6349 19.5963 12.3744C17.8567 14.1139 15.0318 14.2789 12.8788 13.435" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      files: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 11V4.6C2 4.26863 2.26863 4 2.6 4H8.77805C8.92127 4 9.05977 4.05124 9.16852 4.14445L12.3315 6.85555C12.4402 6.94876 12.5787 7 12.722 7H21.4C21.7314 7 22 7.26863 22 7.6V11M2 11V19.4C2 19.7314 2.26863 20 2.6 20H21.4C21.7314 20 22 19.7314 22 19.4V11M2 11H22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      grid: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14 20.4V14.6C14 14.2686 14.2686 14 14.6 14H20.4C20.7314 14 21 14.2686 21 14.6V20.4C21 20.7314 20.7314 21 20.4 21H14.6C14.2686 21 14 20.7314 14 20.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M3 20.4V14.6C3 14.2686 3.26863 14 3.6 14H9.4C9.73137 14 10 14.2686 10 14.6V20.4C10 20.7314 9.73137 21 9.4 21H3.6C3.26863 21 3 20.7314 3 20.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M14 9.4V3.6C14 3.26863 14.2686 3 14.6 3H20.4C20.7314 3 21 3.26863 21 3.6V9.4C21 9.73137 20.7314 10 20.4 10H14.6C14.2686 10 14 9.73137 14 9.4Z" stroke="currentColor" stroke-width="1.5"/><path d="M3 9.4V3.6C3 3.26863 3.26863 3 3.6 3H9.4C9.73137 3 10 3.26863 10 3.6V9.4C10 9.73137 9.73137 10 9.4 10H3.6C3.26863 10 3 9.73137 3 9.4Z" stroke="currentColor" stroke-width="1.5"/></svg>',
      filter: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6H21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M7 12L17 12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M11 18L13 18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      globe: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M2.5 12.5L8 14.5L7 18L8 21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M17 20.5L16.5 18L14 17V13.5L17 12.5L21.5 13" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 5.5L18.5 7L15 7.5V10.5L17.5 9.5H19.5L21.5 10.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M2.5 10.5L5 8.5L7.5 8L9.5 5L8.5 3" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      lock: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M16 12H17.4C17.7314 12 18 12.2686 18 12.6V19.4C18 19.7314 17.7314 20 17.4 20H6.6C6.26863 20 6 19.7314 6 19.4V12.6C6 12.2686 6.26863 12 6.6 12H8M16 12V8C16 6.66667 15.2 4 12 4C8.8 4 8 6.66667 8 8V12M16 12H8" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      draft: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14.3632 5.65156L15.8431 4.17157C16.6242 3.39052 17.8905 3.39052 18.6716 4.17157L20.0858 5.58579C20.8668 6.36683 20.8668 7.63316 20.0858 8.41421L18.6058 9.8942M14.3632 5.65156L4.74749 15.2672C4.41542 15.5993 4.21079 16.0376 4.16947 16.5054L3.92738 19.2459C3.87261 19.8659 4.39148 20.3848 5.0115 20.33L7.75191 20.0879C8.21972 20.0466 8.65806 19.8419 8.99013 19.5099L18.6058 9.8942M14.3632 5.65156L18.6058 9.8942" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      search: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M17 17L21 21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M3 11C3 15.4183 6.58172 19 11 19C13.213 19 15.2161 18.1015 16.6644 16.6493C18.1077 15.2022 19 13.2053 19 11C19 6.58172 15.4183 3 11 3C6.58172 3 3 6.58172 3 11Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      rail: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21L5 21C3.89543 21 3 20.1046 3 19L3 5C3 3.89543 3.89543 3 5 3L19 3C20.1046 3 21 3.89543 21 5L21 19C21 20.1046 20.1046 21 19 21Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M7.25 10L5.5 12L7.25 14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M9.5 21V3" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      pin: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 14.5L3 21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M5.00007 9.48528L14.1925 18.6777L15.8895 16.9806L15.4974 13.1944L21.0065 8.5211L15.1568 2.67141L10.4834 8.18034L6.69713 7.78823L5.00007 9.48528Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      logout: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 12H19M19 12L16 15M19 12L16 9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 6V5C19 3.89543 18.1046 3 17 3H7C5.89543 3 5 3.89543 5 5V19C5 20.1046 5.89543 21 7 21H17C18.1046 21 19 20.1046 19 19V18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      gear: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15C13.6569 15 15 13.6569 15 12C15 10.3431 13.6569 9 12 9C10.3431 9 9 10.3431 9 12C9 13.6569 10.3431 15 12 15Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M19.6224 10.3954L18.5247 7.7448L20 6L18 4L16.2647 5.48295L13.5578 4.36974L12.9353 2H10.981L10.3491 4.40113L7.70441 5.51596L6 4L4 6L5.45337 7.78885L4.3725 10.4463L2 11V13L4.40111 13.6555L5.51575 16.2997L4 18L6 20L7.79116 18.5403L10.397 19.6123L11 22H13L13.6045 19.6132L16.2551 18.5155C16.6969 18.8313 18 20 18 20L20 18L18.5159 16.2494L19.6139 13.598L21.9999 12.9772L22 11L19.6224 10.3954Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      quill: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M20 3c-5 0-9 2.5-12 6.5C5.5 13 5 17 5 19c2 0 6-.5 9.5-3C18.5 13 20 8 20 3z"/><path d="M5 19 11 13"/><path d="M3 21c1-2 2.5-3.5 4.5-4.5"/></svg>',
      chip: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M8 15.4V8.6C8 8.26863 8.26863 8 8.6 8H15.4C15.7314 8 16 8.26863 16 8.6V15.4C16 15.7314 15.7314 16 15.4 16H8.6C8.26863 16 8 15.7314 8 15.4Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M20 4.6V19.4C20 19.7314 19.7314 20 19.4 20H4.6C4.26863 20 4 19.7314 4 19.4V4.6C4 4.26863 4.26863 4 4.6 4H19.4C19.7314 4 20 4.26863 20 4.6Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M17 4V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 4V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M7 4V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M7 20V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 20V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M17 20V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M20 17H22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M20 12H22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M20 7H22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 17H2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 12H2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 7H2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      dots: '<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/></svg>',
      edit: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14.3632 5.65156L15.8431 4.17157C16.6242 3.39052 17.8905 3.39052 18.6716 4.17157L20.0858 5.58579C20.8668 6.36683 20.8668 7.63316 20.0858 8.41421L18.6058 9.8942M14.3632 5.65156L4.74749 15.2672C4.41542 15.5993 4.21079 16.0376 4.16947 16.5054L3.92738 19.2459C3.87261 19.8659 4.39148 20.3848 5.0115 20.33L7.75191 20.0879C8.21972 20.0466 8.65806 19.8419 8.99013 19.5099L18.6058 9.8942M14.3632 5.65156L18.6058 9.8942" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      trash: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M20 9L18.005 20.3463C17.8369 21.3026 17.0062 22 16.0353 22H7.96474C6.99379 22 6.1631 21.3026 5.99496 20.3463L4 9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M21 6L15.375 6M3 6L8.625 6M8.625 6V4C8.625 2.89543 9.52043 2 10.625 2H13.375C14.4796 2 15.375 2.89543 15.375 4V6M8.625 6L15.375 6" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      copy: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M19.4 20H9.6C9.26863 20 9 19.7314 9 19.4V9.6C9 9.26863 9.26863 9 9.6 9H19.4C19.7314 9 20 9.26863 20 9.6V19.4C20 19.7314 19.7314 20 19.4 20Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M15 9V4.6C15 4.26863 14.7314 4 14.4 4H4.6C4.26863 4 4 4.26863 4 4.6V14.4C4 14.7314 4.26863 15 4.6 15H9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      link: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14 11.9976C14 9.5059 11.683 7 8.85714 7C8.52241 7 7.41904 7.00001 7.14286 7.00001C4.30254 7.00001 2 9.23752 2 11.9976C2 14.376 3.70973 16.3664 6 16.8714C6.36756 16.9525 6.75006 16.9952 7.14286 16.9952" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M10 11.9976C10 14.4893 12.317 16.9952 15.1429 16.9952C15.4776 16.9952 16.581 16.9952 16.8571 16.9952C19.6975 16.9952 22 14.7577 22 11.9976C22 9.6192 20.2903 7.62884 18 7.12383C17.6324 7.04278 17.2499 6.99999 16.8571 6.99999" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      download: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6 20L18 20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 4V16M12 16L15.5 12.5M12 16L8.5 12.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      external: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M21 3L15 3M21 3L12 12M21 3V9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M21 13V19C21 20.1046 20.1046 21 19 21H5C3.89543 21 3 20.1046 3 19V5C3 3.89543 3.89543 3 5 3H11" stroke="currentColor" stroke-linecap="round"/></svg>',
      newfile: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12V2.6C4 2.26863 4.26863 2 4.6 2H16.2515C16.4106 2 16.5632 2.06321 16.6757 2.17574L19.8243 5.32426C19.9368 5.43679 20 5.5894 20 5.74853V21.4C20 21.7314 19.7314 22 19.4 22H11" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M16 2V5.4C16 5.73137 16.2686 6 16.6 6H20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M1.99219 19H4.99219M7.99219 19H4.99219M4.99219 19V16M4.99219 19V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      newfolder: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6H20M22 6H20M20 6V4M20 6V8" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M21.4 20H2.6C2.26863 20 2 19.7314 2 19.4V11H21.4C21.7314 11 22 11.2686 22 11.6V19.4C22 19.7314 21.7314 20 21.4 20Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M2 11V4.6C2 4.26863 2.26863 4 2.6 4H8.77805C8.92127 4 9.05977 4.05124 9.16852 4.14445L12.3315 6.85555C12.4402 6.94876 12.5787 7 12.722 7H14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      file: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 21.4V2.6C4 2.26863 4.26863 2 4.6 2H16.2515C16.4106 2 16.5632 2.06321 16.6757 2.17574L19.8243 5.32426C19.9368 5.43679 20 5.5894 20 5.74853V21.4C20 21.7314 19.7314 22 19.4 22H4.6C4.26863 22 4 21.7314 4 21.4Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 10L16 10" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 18L16 18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 14L12 14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M16 2V5.4C16 5.73137 16.2686 6 16.6 6H20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      folder: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2 11V4.6C2 4.26863 2.26863 4 2.6 4H8.77805C8.92127 4 9.05977 4.05124 9.16852 4.14445L12.3315 6.85555C12.4402 6.94876 12.5787 7 12.722 7H21.4C21.7314 7 22 7.26863 22 7.6V11M2 11V19.4C2 19.7314 2.26863 20 2.6 20H21.4C21.7314 20 22 19.7314 22 19.4V11M2 11H22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>',
      newfolderplus: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6H20M22 6H20M20 6V4M20 6V8" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M21.4 20H2.6C2.26863 20 2 19.7314 2 19.4V11H21.4C21.7314 11 22 11.2686 22 11.6V19.4C22 19.7314 21.7314 20 21.4 20Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/><path d="M2 11V4.6C2 4.26863 2.26863 4 2.6 4H8.77805C8.92127 4 9.05977 4.05124 9.16852 4.14445L12.3315 6.85555C12.4402 6.94876 12.5787 7 12.722 7H14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/></svg>'
    };
    var WMARK = WB.WMARK = '<svg viewBox="0 0 113.444 65.6002" fill="none"><path fill="currentColor" d="M48.271 0.137C54.035-0.042 59.486-0.1 65.239 0.308 65.53 10.08 65.175 19.962 65.462 29.738 65.487 30.568 65.871 31.142 66.391 31.743 72.108 33.464 84.752 13.845 90.921 11.74 93.907 12.344 100.087 19.999 102.273 22.457 98.731 28.417 83.273 40.691 81.382 45.003 81.4 46.287 81.45 46.326 82.157 47.442 83.708 48.637 108.252 47.988 113.133 48.464 113.57 53.985 113.431 59.865 113.391 65.428 101.67 65.449 86.679 66.781 76.472 61.69 68.049 57.527 61.65 50.16 58.704 41.238 57.939 38.586 57.387 36.15 56.78 33.468 55.6 38.7 54.677 42.988 51.921 47.705 39.805 68.442 20.228 65.456 0.065 65.389-0.058 59.646-0.006 53.901 0.222 48.161 5.512 48.136 28.425 48.742 31.699 47.27 31.862 46.897 31.905 46.848 31.987 46.404 32.672 42.681 14.558 27.349 11.618 22.838L11.373 22.456C13.177 19.907 19.347 13.073 22.063 11.774 25.791 11.211 40.002 29.83 44.456 31.689 45.845 32.268 46.068 32.231 47.291 31.751 48.666 29.798 48.206 22.821 48.217 20.153L48.271 0.137Z"/></svg>';

    // Toolkit + agent pastel themes live in glyphs.js (WB.TOOLKIT_GLYPHS / WB.AGENT_THEME), loaded before
    // app.js — one home, shared by the Toolkits page, the sidebar session dots, and the composer selector.

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
    try { st.appView = localStorage.getItem('wb-appview') || 'all'; } catch (e) { st.appView = 'all'; }          // all (flat) | workspace (grouped)
    try { st.appSort = localStorage.getItem('wb-appsort') || 'name'; } catch (e) { st.appSort = 'name'; }        // name | updated
    try { st.appGroupsCollapsed = JSON.parse(localStorage.getItem('wb-appgroups') || '{}'); } catch (e) { st.appGroupsCollapsed = {}; }
    try { st.studioWsCollapsed = JSON.parse(localStorage.getItem('wb-studiows') || '{}'); } catch (e) { st.studioWsCollapsed = {}; }
    try { st.dataGroupsCollapsed = JSON.parse(localStorage.getItem('wb-datagroups') || '{}'); } catch (e) { st.dataGroupsCollapsed = {}; }
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
        { label: 'Nexus settings', icon: ICO.gear, need: 'nexus.manage', on: function(){ WB.nav('/usage'); } },
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
        // Sort: name (label A→Z) or recently updated (newest first).
        apps.sort(st.appSort === 'updated'
          ? function(a, b){ return (b.updated || 0) - (a.updated || 0); }
          : function(a, b){ return (a.label || '').localeCompare(b.label || ''); });
        // globe = public/open · lock = gated by our auth guardian · pencil = draft (WIP)
        var BADGE = { draft: { ic: ICO.draft, cls: ' draft', t: 'Draft — work in progress' }, private: { ic: ICO.lock, cls: ' priv', t: 'Private — gated by auth' }, public: { ic: ICO.globe, cls: '', t: 'Public — open' } };
        // Registry the in-app browser (/app view) reads to resolve name → {url,label,...} without a refetch.
        WB._appReg = {}; apps.forEach(function(a){ WB._appReg[a.name] = a; });
        function appCard(a){
          var vis = visOf(a), b = BADGE[vis] || BADGE.public;
          var ic = a.icon ? '<span class="appemoji">' + esc(a.icon) + '</span>'
                          : '<span class="appinit">' + esc((a.label[0] || 'A').toUpperCase()) + '</span>';
          var badge = '<span class="appbadge' + b.cls + '" title="' + b.t + '">' + b.ic + '</span>';
          // Everything opens IN-APP, in the content area's browser chrome (/app/<name>) — never a new tab.
          return '<a class="appcard' + (vis === 'draft' ? ' draft' : '') + '" data-ctx="app" data-open-app="' + esc(a.name) + '" href="#/app/' + esc(encodeURIComponent(a.name)) + '" title="' + esc(a.label) + '">' +
            badge + ic + '<span class="appname">' + esc(a.label) + '</span></a>';
        }
        // No "New app" tile — apps are created through the Studio, not a blank scaffold here.
        g.classList.toggle('grouped', st.appView === 'workspace');   // grouped → container stacks groups (block)

        if (st.appView === 'workspace') {
          // Grouped by workspace via the SHARED component (same header as Files/Studio/Data); body is the
          // app-card grid. Ungrouped apps fall under "General", every declared workspace shows as a group.
          g.innerHTML = WB.wsGroups({
            items: apps, ws: function(a){ return a.workspace || ''; },
            key: 'wb-appgroups', store: st.appGroupsCollapsed, repaint: paintApps, empty: 'No apps',
            body: function(id, list){ return '<div class="appsgrid">' + list.map(appCard).join('') + '</div>'; }
          });
        } else {
          var cards = apps.map(appCard).join('');
          g.innerHTML = cards || '<div class="treemsg" style="padding:8px 4px">No ' + (st.appFilter !== 'all' ? st.appFilter + ' ' : '') + 'apps</div>';
        }
      });
    }
    // Studio sidebar — sessions GROUPED BY WORKSPACE (the declared subtrees in WB.ws.list), plus a
    // "General" group for workspace-less (system-level) sessions. EVERY workspace shows as a collapsible
    // group even with no sessions (empty state inside). The + on a group starts a session IN that
    // workspace. Each session row carries its agent's pastel dot.
    // ── Standard collapsible workspace-grouped list ─────────────────────────────────────────────
    // ONE component for every sidebar that groups rows by workspace (Studio sessions, Data resources,
    // …): a "General" group (system-level / workspace-less) first, then each declared workspace, then
    // any orphan workspace still referenced by an item. Collapse state persists per consumer.
    //   opts.items   — array of items
    //   opts.ws(it)  — the item's workspace id ('' → General)
    //   opts.row(it) — row HTML for an item
    //   opts.key     — unique id for this list's collapse store (also the localStorage key)
    //   opts.store   — the st.* object holding collapse booleans (keyed by ws id / '_general')
    //   opts.repaint — fn() to re-render this list after a toggle
    //   opts.add     — optional { attrs(id,name) → string, title(name) → string } for a per-group + button
    //   opts.empty   — text for an empty group (default "Empty")
    WB._wsGroupStores = WB._wsGroupStores || {};
    WB.wsGroups = function (opts) {
      var defaultOpen = opts.defaultOpen !== false;
      WB._wsGroupStores[opts.key] = { store: opts.store, lsKey: opts.key, repaint: opts.repaint, defaultOpen: defaultOpen };
      var workspaces = (WB.ws && WB.ws.list) || [];
      var byWs = {}; (opts.items || []).forEach(function (it) { var k = opts.ws(it) || ''; (byWs[k] = byWs[k] || []).push(it); });
      function group(id, name, list) {
        if (opts.hideEmpty && !list.length) return '';   // under a filter, don't show empty groups
        var gkey = id || '_general';
        var open = (gkey in opts.store) ? !!opts.store[gkey] : defaultOpen;
        var extra = opts.add ? '<button class="wsmore-btn" ' + opts.add.attrs(id, name) + ' title="' + esc(opts.add.title(name)) + '">' + (opts.add.glyph || '+') + '</button>' : '';
        // Canonical workspace-group header — the Files design (hash · name · count · action · caret-right).
        var ct = opts.count === false ? '' : '<span class="swsct">' + (list.length || '') + '</span>';
        var head = '<div class="wshdr" data-wsgroup="' + esc(opts.key) + '" data-wskey="' + esc(gkey) + '" role="button" tabindex="0" title="' + esc(name) + '">' +
          '<span class="wshash">' + ICO.hash + '</span>' +
          '<span class="wsname">' + esc(name) + '</span>' +
          ct + extra +
          '<span class="wschev">' + ICO.chev + '</span></div>';
        var body = '';
        if (open) body = opts.body ? opts.body(id, list) : (list.length ? list.map(opts.row).join('') : '<div class="treemsg" style="padding:2px 10px 8px 30px">' + (opts.empty || 'Empty') + '</div>');
        return '<div class="wsgroup' + (open ? ' open' : '') + '">' + head + body + '</div>';
      }
      var html = (opts.general === false) ? '' : group('', 'General', byWs[''] || []);
      workspaces.forEach(function (w) { html += group(w.id, w.name || w.id, byWs[w.id] || []); });
      Object.keys(byWs).forEach(function (k) { if (k && !workspaces.some(function (w) { return w.id === k; })) html += group(k, k, byWs[k]); });
      return html;
    };
    function studioSessRow(s){
      var th = (WB.AGENT_THEME && s.agent) ? WB.AGENT_THEME[s.agent] : null;
      var dot = th ? '<span class="sdot" style="background:' + th.color + '" title="' + esc(s.agent) + '"></span>' : '<span class="semoji">💬</span>';
      return '<a class="srow" data-ctx="session" data-nav="/studio" href="#/studio" data-session="' + esc(s.id) + '" data-workspace="' + esc(s.workspace || '') + '" title="' + esc(s.title || 'Session') + '">' +
        dot + '<span class="sname">' + esc(s.title || 'Untitled session') + '</span></a>';
    }
    function paintStudioSide(){
      var el = document.getElementById('studioSide'); if (!el) return;
      el.innerHTML = WB.wsGroups({
        items: WB._studioSessions || [],
        ws: function(s){ return s.workspace || ''; },
        row: studioSessRow,
        key: 'wb-studiows', store: st.studioWsCollapsed, repaint: paintStudioSide,
        empty: 'No sessions yet',
        add: { attrs: function(id){ return 'data-newsession data-workspace="' + esc(id) + '"'; }, title: function(name){ return 'New session in ' + name; } }
      });
    }
    function paintStudio(){
      if (!document.getElementById('studioSide')) return;
      WB.swr('agent-sessions', function(){ return fetch('/cloud/agent/sessions', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        WB._studioSessions = (d && d.sessions) || []; paintStudioSide();
      });
    }
    WB._paintStudio = paintStudio;
    // Inbox funnel — the LEFT sidebar: saved filter views (email-style). Clicking one sets the active
    // filter the page reads (WB._inboxFilter) and re-renders. Search box narrows by text. Views come
    // from GET /cloud/inbox/views (defaults + the user's own). The page (views/activity.js) owns the list.
    function paintInboxFunnel(){
      var box = document.getElementById('inboxFunnel'); if (!box) return;
      WB._inboxFilter = WB._inboxFilter || { view: 'Inbox', filters: '', q: '' };
      WB.swr('inbox-views', function(){ return fetch('/cloud/inbox/views', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var el = document.getElementById('inboxFunnel'); if (!el) return;
        var views = (d && d.views) || [];
        WB._inboxViews = views;
        // "Inbox" (all, unfiltered) sits above the presets; needs-you is the first preset.
        var rows = [{ name: 'Inbox', emoji: '✉', filters: '', builtin: true }].concat(views);
        el.innerHTML = rows.map(function(v){
          var on = (WB._inboxFilter.view === v.name);
          return '<button class="ibxview' + (on ? ' on' : '') + '" data-ibxview="' + esc(v.name) + '" data-ibxf="' + esc(v.filters || '') + '">' +
            '<span class="ibxvemoji">' + esc(v.emoji || '▦') + '</span>' +
            '<span class="ibxvname">' + esc(v.name) + '</span>' +
            '<span class="ibxvn" data-ibxcount="' + esc(v.name) + '"></span></button>';
        }).join('');
        el.querySelectorAll('.ibxview').forEach(function(b){ b.onclick = function(){
          WB._inboxFilter = { view: b.getAttribute('data-ibxview'), filters: b.getAttribute('data-ibxf') || '', q: WB._inboxFilter.q || '' };
          paintInboxFunnel();
          if (WB._inboxRender) WB._inboxRender();
        }; });
        var s = document.getElementById('inboxSearch');
        if (s && !s._wired){ s._wired = true; s.value = WB._inboxFilter.q || '';
          s.oninput = function(){ WB._inboxFilter.q = s.value; if (WB._inboxRender) WB._inboxRender(); }; }
        if (WB._inboxCounts) WB._inboxCounts();   // page fills the per-view counts when its data lands
      });
    }
    WB._paintInboxFunnel = paintInboxFunnel;
    // Toolkits sidebar — what's ACTIVE: connected accounts (per integration) + enabled built-in toolkits,
    // each with an inline disable. Reuses GET /cloud/toolkits; SWR so it paints instantly then refreshes.
    function paintToolkits(){
      var box = document.getElementById('toolkitsSide'); if (!box) return;
      WB.swr('toolkits', function(){ return fetch('/cloud/toolkits', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var el = document.getElementById('toolkitsSide'); if (!el) return;
        var tk = (d && d.toolkits) || [];
        // Icon for a row: the brand SVG for a connection (theme-aware), the pastel glyph for a toolkit.
        function connIcon(pid){ var g = WB.brandGlyph && WB.brandGlyph(pid); return '<span class="semoji tkglyph">' + (g || '🔌') + '</span>'; }
        function tkIcon(id){ var th = (WB.TOOLKIT_GLYPHS && WB.TOOLKIT_GLYPHS[id]); return th ? '<span class="semoji tkglyph" style="color:' + th.color + '">' + th.icon + '</span>' : '<span class="semoji">🧰</span>'; }
        var conns = [];
        tk.filter(function(t){ return t.kind === 'provider'; }).forEach(function(p){
          (p.accounts || []).forEach(function(a){ conns.push({ id: a.id, pid: p.id, label: a.label || a.id, prov: p.name }); });
        });
        var active = tk.filter(function(t){ return t.kind === 'standalone' && t.enabled !== false && t.status === 'ready'; });
        el.innerHTML =
          '<div class="sgrp">Connections</div>' +
          (conns.length ? conns.map(function(c){
            return '<div class="srow tkside">' + connIcon(c.pid) + '<span class="sname" title="' + esc(c.prov) + '">' + esc(c.label) + '</span>' +
              '<button class="tksidex" data-tkdisc="' + esc(c.id) + '" title="Disconnect">✕</button></div>';
          }).join('') : '<div class="treemsg" style="padding:6px 10px">No connections yet</div>') +
          '<div class="sgrp">Toolkits</div>' +
          (active.length ? active.map(function(t){
            return '<div class="srow tkside">' + tkIcon(t.id) + '<span class="sname">' + esc(t.name) + '</span>' +
              '<button class="tksidex" data-tkoff="' + esc(t.id) + '" title="Disable">✕</button></div>';
          }).join('') : '<div class="treemsg" style="padding:6px 10px">None enabled</div>');
        el.querySelectorAll('[data-tkdisc]').forEach(function(b){ b.onclick = function(){ tkSideDisconnect(b.getAttribute('data-tkdisc')); }; });
        el.querySelectorAll('[data-tkoff]').forEach(function(b){ b.onclick = function(){ tkSideToggle(b.getAttribute('data-tkoff')); }; });
      });
    }
    // Data sidebar — Overview + Assets links, then every resource ("table") grouped by workspace.
    // Reuses GET /cloud/data (tenant-scoped). SWR for an instant paint, then refresh. Resource rows
    // navigate to #/data?r=<name>; the active row is derived from the current hash.
    function paintDataSide(){
      var box = document.getElementById('dataSide'); if (!box) return;
      WB.swr('data:list', function(){ return fetch('/cloud/data', { credentials: 'same-origin' }).then(function(r){ return r.json(); }); }, function(d){
        var el = document.getElementById('dataSide'); if (!el) return;
        var resources = (d && d.resources) || [];
        var hash = location.hash.slice(1) || '/data';
        var curR = (hash.match(/[?&]r=([^&]+)/) || [])[1]; if (curR) curR = decodeURIComponent(curR);
        var onAssets = /[?&]assets=/.test(hash);
        var onOverview = (hash === '/data' || hash.indexOf('/data?') === 0) && !curR && !onAssets;

        function navrow(active, href, ico, label){
          return '<a class="srow' + (active ? ' on' : '') + '" data-nav="' + href + '" href="#' + href + '">' +
            '<span class="semoji">' + ico + '</span><span class="sname">' + esc(label) + '</span></a>';
        }
        function resourceRow(r){
          var live = r.count > 0;
          // Self-styled (the sidebar renders outside the view's scoped styles): inline the live/empty dot.
          // Indented under the workspace header; no record count (just whether the table exists/live).
          var dot = '<span title="' + (live ? 'live' : 'empty') + '" style="display:inline-block;width:8px;height:8px;border-radius:3px;flex:0 0 auto;background:' + (live ? 'var(--live, #3fb950)' : 'var(--stroke)') + '"></span>';
          return '<a class="srow' + (curR === r.name ? ' on' : '') + '" style="padding-left:28px" data-nav="/data?r=' + encodeURIComponent(r.name) + '" href="#/data?r=' + encodeURIComponent(r.name) + '" title="' + esc(r.name) + '">' +
            dot + '<span class="sname">' + esc(r.name) + '</span></a>';
        }

        // Tag filter lives in the header funnel (filterMenu, st.dataTagFilter) — same as Apps/Files.
        var tagFilter = st.dataTagFilter || '';
        var hasTag = resources.some(function(r){ return (r.tags || []).indexOf(tagFilter) >= 0; });
        if (tagFilter && !hasTag) tagFilter = '';   // stale filter (tag gone) → reset
        var shown = tagFilter ? resources.filter(function(r){ return (r.tags || []).indexOf(tagFilter) >= 0; }) : resources;

        el.innerHTML =
          navrow(onOverview, '/data', ICO.gauge, 'Overview') +
          navrow(onAssets, '/data?assets=1', ICO.files, 'Assets') +
          (resources.length
            ? WB.wsGroups({ items: shown, ws: function(r){ return r.workspace || ''; }, row: resourceRow,
                key: 'wb-datagroups', store: st.dataGroupsCollapsed, repaint: paintDataSide,
                hideEmpty: !!tagFilter, count: false, empty: 'No tables' })
            : '<div class="treemsg" style="padding:8px 10px">No resources yet. A <code>resource</code> block in any workbook shows up here.</div>');
      });
    }
    async function tkSideDisconnect(id){
      var ok = await WB.confirm({ title: 'Disconnect this account?', body: 'Its sealed credentials will be deleted.', confirm: 'Disconnect', danger: true });
      if (!ok) return;
      try { await fetch('/cloud/integrations/' + encodeURIComponent(id), { method: 'DELETE', credentials: 'same-origin' }); WB.cache.set('toolkits', null); WB.toast('Disconnected'); paintToolkits(); }
      catch (e) { WB.toast('Failed', 'bad'); }
    }
    async function tkSideToggle(id){
      try { await fetch('/cloud/toolkits/' + encodeURIComponent(id) + '/toggle', { method: 'POST', credentials: 'same-origin' }); WB.cache.set('toolkits', null); WB.toast('Disabled'); paintToolkits(); }
      catch (e) { WB.toast('Failed', 'bad'); }
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
            '<span class="wshash">' + ICO.hash + '</span>' +
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
        { id: 'activity', ico: ICO.activity, label: 'Inbox', go: '/activity' },
        { id: 'files', ico: ICO.files, label: 'Files', go: '/workspaces' },
        { id: 'data', ico: ICO.sheet, label: 'Data', go: '/data' }
      ];
      var railsecs = RAIL_SECS.map(function (s) {
        return '<a class="railsec' + (section === s.id ? ' on' : '') + '" data-nav="' + s.go + '" href="#' + s.go +
          '" title="' + s.label + '"><span class="rsico">' + s.ico + '</span><span class="rslbl">' + s.label + '</span></a>';
      }).join('');

      // ── per-surface SIDEBAR body — swaps with the active rail section ──
      var SECTITLE = { studio: 'Studio', apps: 'Apps', activity: 'Inbox', files: 'Files', data: 'Data', toolkits: 'Toolkits', admin: 'Admin', account: 'You' };
      var isBrowse = section === 'apps' || section === 'files' || section === 'data';   // these get the header filter funnel
      if (isBrowse) st.sideMode = section;   // keep the filter funnel (filterMenu/filterActive) keyed to the active surface
      var sideBody;
      if (section === 'files') sideBody = '<div class="wsgroups">' + wslist + '</div>';
      else if (section === 'apps') sideBody = '<div class="appsgrid" id="appsGrid"><div class="treemsg" style="padding:8px 4px">Loading apps…</div></div>';
      // Studio — New session, then a "Workspaces" header (with a + to add one) over the workspace groups.
      else if (section === 'studio') sideBody =
          '<div class="studioacts">' +
            '<button class="newsess" data-newsession><span class="nsico">' + ICO.plus + '</span>New session</button>' +
          '</div>' +
          '<div class="swshead"><span class="swsheadtt">Workspaces</span>' +
            '<button class="swsheadadd" data-newworkspace title="New workspace">' + ICO.plus + '</button></div>' +
          '<div id="studioSide"><div class="treemsg" style="padding:8px 4px">Loading sessions…</div></div>';
      // Inbox — the LEFT sidebar is the filter funnel (saved views + search). The page is the list+pane
      // mailbox. Clicking a view sets WB._inboxFilter and re-renders the page (lazy → #inboxFunnel).
      else if (section === 'activity') sideBody =
          '<div class="ibxfunnel">' +
            '<div class="ibxsearch"><span class="ibxsico">' + ICO.filter + '</span>' +
              '<input id="inboxSearch" placeholder="Filter inbox…" autocomplete="off"></div>' +
            '<div id="inboxFunnel"><div class="treemsg" style="padding:8px 4px">Loading…</div></div>' +
          '</div>';
      // Data — Overview + Assets links, then resources grouped by workspace (lazy → #dataSide).
      else if (section === 'data') sideBody = '<div id="dataSide"><div class="treemsg" style="padding:8px 4px">Loading…</div></div>';
      // Toolkits — the sidebar lists what's ACTIVE: connected accounts + enabled built-in toolkits, each
      // with an inline disable. The page is the marketplace; this is the "what's on" view (lazy → #toolkitsSide).
      else if (section === 'toolkits') sideBody = '<div id="toolkitsSide"><div class="treemsg" style="padding:8px 4px">Loading…</div></div>';
      else if (section === 'admin') sideBody = '<nav class="nxnav">' +
          navlink('/usage', ICO.gauge, 'Usage & billing', p) + navlink('/inference', ICO.chip, 'AI', p) +
          navlink('/storage', ICO.database, 'Storage', p) +
          navlink('/team', ICO.users, 'Users', p) + navlink('/secrets', ICO.key, 'Secrets', p) +
          (WB.can('autopoet.manage') ? navlink('/autopoet', ICO.quill, 'Autopoet', p) : '') + '</nav>';
      // You — the personal surface as ONE cohesive unit: the profile page with in-page section anchors.
      // Each link scrolls /profile to its section (no scattering across admin/secrets pages). Sign out
      // stays at the foot. Auth method, 2FA, custom domains, backup-repo are NOT "you" — they moved out.
      else if (section === 'account') {
        var pfsec = function(id, ico, label){ return '<a class="nxlink" data-pfsec="' + id + '" href="#/profile" title="' + esc(label) + '">' + ico + '<span class="lbl">' + esc(label) + '</span></a>'; };
        sideBody = '<nav class="nxnav">' +
          pfsec('', ICO.grid, 'Profile') +
          pfsec('contributions', ICO.activity, 'Contributions') +
          pfsec('usage', ICO.gauge, 'Usage') +
          pfsec('cli', ICO.key, 'CLI access') +
          pfsec('devices', ICO.lock, 'Devices & keys') +
          pfsec('prefs', ICO.gear, 'Preferences') +
          '<div class="raildiv" style="margin:8px 0"></div>' +
          '<a class="nxlink" href="/login/" onclick="return WB.logout()">' + ICO.logout + '<span class="lbl">Sign out</span></a></nav>';
      }
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
            '<a class="railsec' + (section === 'toolkits' ? ' on' : '') + '" data-nav="/toolkits" href="#/toolkits" title="Toolkits"><span class="rsico">' + ICO.toolbox + '</span><span class="rslbl">Toolkits</span></a>' +
            '<a class="railsec' + (section === 'admin' ? ' on' : '') + '" data-nav="/usage" href="#/usage" title="Admin"><span class="rsico">' + ICO.admin + '</span><span class="rslbl">Admin</span></a>' +
            '<a class="railsec railavbtn' + (section === 'account' ? ' on' : '') + '" data-nav="/profile" href="#/profile" title="' + esc(user.name) + '">' + railAvatar(user) + '<span class="rslbl">You</span></a>' +
          '</div>' +
        '</div>' +
        // Collapsed → a slim blank second rail with just the expand button at the top (never fully gone,
        // so it's always re-openable). Expanded → the full per-surface sidebar.
        '<aside class="side' + (st.rail ? ' railed' : '') + '">' +
          (st.rail
            ? '<button class="sidehd-ic railexpand" data-rail-toggle title="Open sidebar" aria-label="Open sidebar">' + ICO.rail + '</button>'
            : ('<div class="sidehd">' +
                '<span class="sidehd-t">' + (SECTITLE[section] || '') + '</span>' +
                '<button class="sidehd-ic" data-palette title="Search (⌘K)" aria-label="Search">' + ICO.search + '</button>' +
                (isBrowse ? '<div class="filterwrap"><button class="sidehd-ic' + (filterActive() ? ' on' : '') + '" data-filter-toggle title="Filter" aria-label="Filter">' + ICO.filter + '</button>' + (st.filterOpen ? filterMenu() : '') + '</div>' : '') +
                '<button class="sidehd-ic" data-rail-toggle title="Collapse sidebar" aria-label="Collapse sidebar">' + ICO.rail + '</button>' +
              '</div>' +
              sideBody)
          ) +
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
      else if (section === 'activity') paintInboxFunnel();
      else if (section === 'toolkits') paintToolkits();
      else if (section === 'data') paintDataSide();
    }
    // Let other views (the workspace explorer) refresh the sidebar after a pin/unpin so Pinned updates live.
    WB.refreshSidebar = function(){ try { renderShell(); } catch (e) {} };
    function navlink(href, ico, label, p){ return '<a class="nxlink' + (p === href ? ' on' : '') + '" data-nav="' + href + '" href="#' + href + '" title="' + esc(label) + '">' + ico + '<span class="lbl">' + esc(label) + '</span></a>'; }
    // The rail "You" tile shows the profile photo when one is set (mirrored to WB.profile.avatar by the
    // profile view), otherwise the initial glyph — same surface, richer when personalized.
    function railAvatar(user){ var av = WB.profile && WB.profile.avatar;
      // Single-quote the url() — the style attr is double-quoted, so a data: URL must not introduce a
      // double quote (that would close the attribute early and drop the background).
      return av ? '<span class="railav" style="background-image:url(\'' + av + '\');background-size:cover;background-position:center"></span>'
                : '<span class="railav">' + esc(user.initial) + '</span>'; }
    // The funnel shows a dot when a non-default filter is active for the CURRENT tab.
    function filterActive(){
      if (st.sideMode === 'files') return st.fileFilter !== 'all';
      if (st.sideMode === 'data') return !!st.dataTagFilter;
      return st.appFilter !== 'all' || st.appView !== 'all' || st.appSort !== 'name';
    }
    // Context-dependent filter popover — Apps → visibility (public/private), Files → file type.
    function fopt(kind, val, label, ico){
      var cur = kind === 'app' ? st.appFilter : st.fileFilter;
      return '<button class="filteropt' + (cur === val ? ' on' : '') + '" data-' + kind + 'filter="' + val + '">' +
        (ico ? '<span class="fopti">' + ico + '</span>' : '<span class="fopti"></span>') +
        '<span>' + esc(label) + '</span>' + (cur === val ? '<span class="fcheck">✓</span>' : '') + '</button>';
    }
    function filterMenu(){
      if (st.sideMode === 'data') {
        // Tags come from the cached resource list (paintDataSide's SWR key); the menu is built sync.
        var cached = WB.cache.get('data:list');
        var tags = [];
        ((cached && cached.resources) || []).forEach(function(r){ (r.tags || []).forEach(function(t){ if (tags.indexOf(t) < 0) tags.push(t); }); });
        tags.sort();
        var cur = st.dataTagFilter || '';
        function dtopt(val, label){
          return '<button class="filteropt' + (cur === val ? ' on' : '') + '" data-datatagfilter="' + esc(val) + '">' +
            '<span class="fopti"></span><span>' + esc(label) + '</span>' + (cur === val ? '<span class="fcheck">✓</span>' : '') + '</button>';
        }
        return '<div class="filtermenu" role="menu"><div class="filterhd">Tags</div>' +
          dtopt('', 'All tables') +
          (tags.length ? tags.map(function(t){ return dtopt(t, '#' + t); }).join('') : '<div class="filterhd" style="opacity:.55;font-weight:500">No tags yet</div>') +
        '</div>';
      }
      if (st.sideMode === 'files') {
        return '<div class="filtermenu" role="menu"><div class="filterhd">Files</div>' +
          fopt('file', 'all', 'All files') + fopt('file', 'work', 'Workbooks (.work)') + fopt('file', 'assets', 'Assets') +
        '</div>';
      }
      return '<div class="filtermenu" role="menu">' +
        '<div class="filterhd">Show</div>' +
        fopt('app', 'all', 'All') + fopt('app', 'public', 'Public', ICO.globe) + fopt('app', 'private', 'Private', ICO.lock) + fopt('app', 'draft', 'Drafts', ICO.draft) +
        '<div class="filterhd">Group</div>' + vopt('view', 'all', 'Everything') + vopt('view', 'workspace', 'By workspace') +
        '<div class="filterhd">Sort</div>' + vopt('sort', 'name', 'Name') + vopt('sort', 'updated', 'Recently updated') +
      '</div>';
    }
    // View/sort options in the Apps filter popover (data-appview / data-appsort).
    function vopt(kind, val, label){
      var cur = kind === 'view' ? st.appView : st.appSort;
      return '<button class="filteropt' + (cur === val ? ' on' : '') + '" data-app' + kind + '="' + val + '">' +
        '<span class="fopti"></span><span>' + esc(label) + '</span>' + (cur === val ? '<span class="fcheck">✓</span>' : '') + '</button>';
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
        h += '<a class="omitem" data-nav="/usage" href="#/usage"><span class="av sm plus">⚙</span><span class="omname">Nexus settings</span></a>';
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
      // ── Studio sidebar: set pending session/workspace, then route. When already on /studio the view's
      // hooks (WB._studioOpen / WB._studioNew) apply it in place (a data-nav re-nav wouldn't re-render).
      var onStudio = (location.hash || '').indexOf('/studio') >= 0;   // hooks are only live while mounted
      // Collapse/expand a workspace group — the ONE handler for every WB.wsGroups list (Studio, Data, …).
      // Header click only, not the + button or a clickable row inside it.
      var wsTog = t.closest && t.closest('[data-wsgroup]');
      if (wsTog && !(t.closest && (t.closest('[data-newsession]') || t.closest('[data-session]') || t.closest('[data-wsmore]')))) {
        var sk = wsTog.getAttribute('data-wsgroup'), reg = WB._wsGroupStores[sk];
        if (reg) { var wk = wsTog.getAttribute('data-wskey');
          var wasOpen = (wk in reg.store) ? !!reg.store[wk] : reg.defaultOpen;
          reg.store[wk] = !wasOpen;
          try { localStorage.setItem(reg.lsKey, JSON.stringify(reg.store)); } catch (er) {}
          if (reg.repaint) reg.repaint(); }
        return;
      }
      var ssRow = t.closest && t.closest('[data-session]');
      if (ssRow) { e.preventDefault(); WB._pendingSession = ssRow.getAttribute('data-session'); WB._pendingWorkspace = ssRow.getAttribute('data-workspace') || null;
        if (onStudio && WB._studioOpen) WB._studioOpen(WB._pendingSession); else WB.nav('/studio'); return; }
      var nsBtn = t.closest && t.closest('[data-newsession]');
      if (nsBtn) { e.preventDefault(); WB._pendingSession = null; WB._pendingWorkspace = nsBtn.getAttribute('data-workspace') || null;
        if (onStudio && WB._studioNew) WB._studioNew(WB._pendingWorkspace); else WB.nav('/studio'); return; }
      var npBtn = t.closest && t.closest('[data-newworkspace]');
      if (npBtn) { e.preventDefault();
        Promise.resolve(WB.prompt({ title: 'New workspace', placeholder: 'Workspace name', confirm: 'Create' })).then(function(nm){
          nm = (nm || '').trim(); if (!nm || !WB.ws || !WB.ws.create) return;
          Promise.resolve(WB.ws.create(nm)).then(function(ws){ WB.toast('Created “' + ((ws && ws.name) || nm) + '”'); renderShell(); if (WB._paintStudio) WB._paintStudio(); })
            .catch(function(){ WB.toast('Couldn’t create workspace', 'bad'); });
        });
        return;
      }
      // "You" sidebar → scroll the profile page to a section anchor (navigating to /profile first if needed).
      var pfEl = t.closest && t.closest('[data-pfsec]');
      if (pfEl) { e.preventDefault(); WB._profileSection = pfEl.getAttribute('data-pfsec') || '';
        if (ROUTE.path !== '/profile') WB.nav('/profile');
        else { var n = WB._profileSection ? document.getElementById(WB._profileSection) : document.querySelector('#view section');
          if (n) n.scrollIntoView({ behavior: 'smooth', block: 'start' }); WB._profileSection = null; }
        renderShell(); return; }
      var navEl = t.closest && t.closest('[data-nav]'); if (navEl) { e.preventDefault(); WB.nav(navEl.getAttribute('data-nav')); return; }
      if (t.closest && t.closest('[data-crumb-back]')) { var ret = WB.settingsReturn; WB.settingsReturn = null; WB.nav((ret && ret.path) || '/'); return; }
      if (t.closest && t.closest('[data-theme-toggle]')) { var cur = document.documentElement.getAttribute('data-theme') || 'dark'; var nt = cur === 'dark' ? 'light' : 'dark'; document.documentElement.setAttribute('data-theme', nt); try { localStorage.setItem('wb-theme', nt); } catch (er) {} renderShell(); renderView(); return; }
      if (t.closest && t.closest('[data-rail-toggle]')) { st.rail = !st.rail; try { localStorage.setItem('wb-rail', st.rail ? '1' : '0'); } catch (er) {} renderShell(); return; }
      if (t.closest && t.closest('[data-filter-toggle]')) { st.filterOpen = !st.filterOpen; renderShell(); return; }
      var afl = t.closest && t.closest('[data-appfilter]'); if (afl) { st.appFilter = afl.getAttribute('data-appfilter'); try { localStorage.setItem('wb-appfilter', st.appFilter); } catch (er) {} st.filterOpen = false; renderShell(); return; }
      var ffl = t.closest && t.closest('[data-filefilter]'); if (ffl) { st.fileFilter = ffl.getAttribute('data-filefilter'); try { localStorage.setItem('wb-filefilter', st.fileFilter); } catch (er) {} st.filterOpen = false; renderShell(); return; }
      var dtf = t.closest && t.closest('[data-datatagfilter]'); if (dtf) { st.dataTagFilter = dtf.getAttribute('data-datatagfilter'); st.filterOpen = false; renderShell(); paintDataSide(); return; }
      var avw = t.closest && t.closest('[data-appview]'); if (avw) { st.appView = avw.getAttribute('data-appview'); try { localStorage.setItem('wb-appview', st.appView); } catch (er) {} st.filterOpen = false; renderShell(); paintApps(); return; }
      var aso = t.closest && t.closest('[data-appsort]'); if (aso) { st.appSort = aso.getAttribute('data-appsort'); try { localStorage.setItem('wb-appsort', st.appSort); } catch (er) {} st.filterOpen = false; renderShell(); paintApps(); return; }
      if (t.closest && t.closest('[data-palette]')) { WB.palette(); return; }
      // Activity inbox row → focus that event; the /activity view renders its context in the page.
      var actf = t.closest && t.closest('[data-act-focus]');
      if (actf) { WB._activityFocus = +actf.getAttribute('data-act-focus');
        document.querySelectorAll('.ibrow').forEach(function(r){ r.classList.toggle('on', r === actf); });
        if (WB._activityRender) WB._activityRender(WB._activityFocus); else WB.nav('/activity');
        return; }
      // (Studio session-row handling moved above, before the data-nav catch, so pending state is set.)
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
