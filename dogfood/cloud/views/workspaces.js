// Workspace explorer (ship 3) — a read-only, IDE-like page for the active workspace.
//
// Layout: workspace dropdown (top-left) + a file navigator (Pinned section on top, then the IDE
// tree) on the left, and a browser-like TAB bar + read-only viewer on the right. Files open as
// tabs (closeable, reorderable, persisted per-workspace in localStorage). Viewers: CodeMirror 6
// (code/.work/text, read-only), <img> (images), pdf.js (PDFs), marked (markdown) — all loaded
// no-build from esm.sh. The data path is the cloud `server :cloud` routes /cloud/tree,
// /cloud/file (text + binary flag) and /cloud/raw (raw bytes w/ Content-Type). THE LINE: those
// routes + this page are OUR product (dogfood/cloud), not the open-standard runtime.

WB.view('/workspaces', { title: 'Workspaces', accent: 'var(--peach)', fullbleed: true, async render(el){
  var esc = WB.esc;

  // ── per-workspace persistence ───────────────────────────────────────────────────────────────
  function wsId(){ var w = WB.ws.active; return (w && w.id) || '_'; }
  function tabsKey(){ return 'wb-tabs-' + wsId(); }
  function loadTabs(){ try { return JSON.parse(localStorage.getItem(tabsKey()) || '{}'); } catch (e) { return {}; } }
  function saveTabs(){ try { localStorage.setItem(tabsKey(), JSON.stringify({ open: state.tabs, active: state.active })); } catch (e) {} }

  // bookmarks live in the shared localStorage key (same as the sidebar) — array of {path,label}.
  function loadBm(){ try { return JSON.parse(localStorage.getItem('wb-bookmarks') || '[]'); } catch (e) { return []; } }
  function saveBm(){ try { localStorage.setItem('wb-bookmarks', JSON.stringify(state.bm)); } catch (e) {} }
  function isBm(p){ return state.bm.some(function(b){ return b.path === p; }); }
  function toggleBm(p, label){
    var i = state.bm.findIndex(function(b){ return b.path === p; });
    if (i >= 0) state.bm.splice(i, 1); else state.bm.push({ path: p, label: label || p.split('/').pop() });
    saveBm(); paintNav();
  }

  // ── file-type icons (Material-style, curated inline SVG per common extension) ────────────────
  // .work gets the CUSTOM Workbooks logo mark on a rounded tile (currentColor → flips with theme:
  // black mark on white in light, white mark on black in dark, via the .wkico tile colors).
  var DOC = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>';
  function svgWrap(inner, color){ return '<span class="ficon" style="color:' + color + '">' + inner + '</span>'; }
  function codeGlyph(t){ return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>' + (t ? '' : ''); }
  var EXT = {
    js: ['#f0db4f', codeGlyph()], ts: ['#3178c6', codeGlyph()], jsx: ['#61dafb', codeGlyph()], tsx: ['#61dafb', codeGlyph()],
    json: ['#cb7b3a', codeGlyph()], css: ['#519aba', codeGlyph()], html: ['#e44d26', codeGlyph()], htm: ['#e44d26', codeGlyph()],
    ex: ['#a074c4', codeGlyph()], exs: ['#a074c4', codeGlyph()], heex: ['#a074c4', codeGlyph()], eex: ['#a074c4', codeGlyph()],
    py: ['#3572A5', codeGlyph()], rb: ['#cc342d', codeGlyph()], go: ['#00add8', codeGlyph()], rs: ['#dea584', codeGlyph()],
    zig: ['#f7a41d', codeGlyph()], sh: ['#89e051', codeGlyph()], sql: ['#dad8d8', codeGlyph()], yaml: ['#cb171e', codeGlyph()],
    yml: ['#cb171e', codeGlyph()], toml: ['#9c4221', codeGlyph()], org: ['#77aa99', DOC], txt: ['var(--dim)', DOC],
    csv: ['#1d6f42', DOC], lock: ['var(--dim)', DOC],
    md: ['#519aba', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="5" width="20" height="14" rx="2"/><path d="M6 15V9l3 3 3-3v6"/><path d="M17 9v6"/><path d="M14.5 12.5 17 15l2.5-2.5"/></svg>'],
    png: ['#a62de8', null], jpg: ['#a62de8', null], jpeg: ['#a62de8', null], gif: ['#a62de8', null], svg: ['#ffb13b', null], webp: ['#a62de8', null],
    pdf: ['#e2574c', '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M9 13h6M9 17h4"/></svg>']
  };
  var IMG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg>';
  function ext(p){ var m = (p || '').toLowerCase().match(/\.([a-z0-9]+)$/); return m ? m[1] : ''; }
  function kindOf(p){
    var e = ext(p);
    if (e === 'work') return 'work';
    if (['png','jpg','jpeg','gif','svg','webp'].indexOf(e) >= 0) return 'image';
    if (e === 'pdf') return 'pdf';
    if (e === 'md') return 'markdown';
    return 'text';
  }
  function fileIcon(p){
    var e = ext(p);
    if (e === 'work') return '<span class="wkico">' + (WB.WMARK || '') + '</span>';
    var def = EXT[e];
    if (def) return svgWrap(def[1] || IMG, def[0]);
    return svgWrap(DOC, 'var(--dim)');
  }

  // ── state ───────────────────────────────────────────────────────────────────────────────────
  var saved = loadTabs();
  var state = {
    tabs: Array.isArray(saved.open) ? saved.open : [],     // [{path,label}]
    active: saved.active || null,                          // path
    bm: loadBm(),
    treeOpen: {},                                          // path -> bool
    treeData: {},                                          // path -> entries
    treeLoading: {},
    cache: {},                                             // path -> {kind, content?, src?}
    dragFrom: null,
    editor: null,                                          // current CodeMirror EditorView (editable)
    dirty: false                                           // unsaved edits in the active editor
  };

  function root(){ var w = WB.ws.active; return (w && (w.folder || w.slug || w.name)) || (w && w.id) || ''; }
  // The cloud tree mounts are top-level data-volume folders. We list the whole volume at the root
  // and key the tree by the workspace folder name when we can identify it; otherwise we show all
  // mounts (the dropdown still switches the *active workspace* concept used elsewhere in the app).

  // ── data fetch ──────────────────────────────────────────────────────────────────────────────
  function loadTree(path){
    if (state.treeData[path] || state.treeLoading[path]) return;
    state.treeLoading[path] = true;
    fetch('/cloud/tree' + (path ? '?path=' + encodeURIComponent(path) : ''), { credentials: 'same-origin' })
      .then(function(r){ return r.json(); })
      .then(function(d){ state.treeData[path] = (d && d.entries) || []; })
      .catch(function(){ state.treeData[path] = []; })
      .then(function(){ delete state.treeLoading[path]; paintNav(); });
  }

  // ── tabs ────────────────────────────────────────────────────────────────────────────────────
  function openFile(path, label){
    if (!path) return;
    if (!state.tabs.some(function(t){ return t.path === path; }))
      state.tabs.push({ path: path, label: label || path.split('/').pop() });
    state.active = path;
    saveTabs(); paintTabs(); paintNav(); showActive();
  }
  function closeTab(path){
    var i = state.tabs.findIndex(function(t){ return t.path === path; });
    if (i < 0) return;
    state.tabs.splice(i, 1);
    if (state.active === path) state.active = (state.tabs[i] || state.tabs[i - 1] || {}).path || null;
    saveTabs(); paintTabs(); showActive();
  }

  // expose a global hook so the sidebar tree click opens here without a re-render race
  // Hook so the shared sidebar's file click opens a file here when this view is mounted.
  WB.openInExplorer = function(path){ WB._pendingFile = null; openFile(path); };

  // ── editing (ship 4): edit in CodeMirror → ⌘S → commit/push via the git remote ───────────────
  function setDirty(b){
    state.dirty = b;
    var btn = el.querySelector('[data-save]');
    if (btn){ btn.disabled = !b; btn.textContent = b ? 'Save' : 'Saved'; btn.classList.toggle('on', b); }
    paintTabs();  // refresh the dirty dot on the active tab
  }
  async function save(){
    if (!state.editor || !state.active || !state.dirty) return;
    var path = state.active, content = state.editor.state.doc.toString();
    var btn = el.querySelector('[data-save]'); if (btn){ btn.disabled = true; btn.textContent = 'Saving…'; }
    try {
      var r = await fetch('/cloud/file/save', { method: 'POST', credentials: 'same-origin',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ path: path, content: content }) });
      var d = await r.json();
      if (d && d.ok){ setDirty(false); WB.toast('Saved' + (d.sha ? ' · ' + d.sha : '')); }
      else { WB.toast((d && d.error) || 'Save failed', 'bad'); if (btn){ btn.disabled = false; btn.textContent = 'Save'; } }
    } catch (e) { WB.toast('Save failed', 'bad'); if (btn){ btn.disabled = false; btn.textContent = 'Save'; } }
  }

  // ── viewers (lazy esm imports, cached across the session) ───────────────────────────────────
  var _cm = null, _pdf = null, _marked = null;
  async function cm(){
    if (_cm) return _cm;
    // Assemble from the component packages — esm.sh's `codemirror?bundle` collapses to a single default
    // (no named EditorView/basicSetup), so we import the pieces directly: view (EditorView/lineNumbers/
    // keymap), state, commands (history + keymaps). Editable editor with line numbers + undo/redo.
    _cm = Promise.all([
      import('https://esm.sh/@codemirror/view@6'),
      import('https://esm.sh/@codemirror/state@6'),
      import('https://esm.sh/@codemirror/commands@6')
    ]).then(function(mods){
      var view = mods[0], state = mods[1], cmds = mods[2];
      return { view: view, EditorView: view.EditorView, EditorState: state.EditorState, cmds: cmds };
    });
    return _cm;
  }
  async function pdfjs(){
    if (_pdf) return _pdf;
    _pdf = import('https://esm.sh/pdfjs-dist@4?bundle').then(function(m){
      try { m.GlobalWorkerOptions.workerSrc = 'https://esm.sh/pdfjs-dist@4/build/pdf.worker.min.mjs'; } catch (e) {}
      return m;
    });
    return _pdf;
  }
  async function marked(){
    if (_marked) return _marked;
    _marked = import('https://esm.sh/marked@13?bundle').then(function(m){ return m.marked || m.default || m; });
    return _marked;
  }

  function viewerHost(){ return el.querySelector('#wxViewer'); }

  async function showActive(){
    var host = viewerHost();
    if (!host) return;
    if (!state.active) {
      host.innerHTML = '<div class="wxempty"><div class="wxemptymk">' + (WB.WMARK || '') + '</div>' +
        '<p>Pick a file from the navigator to open it as a tab.</p></div>';
      return;
    }
    var path = state.active, kind = kindOf(path);
    host.innerHTML = '<div class="wxloading">Loading ' + esc(path.split('/').pop()) + '…</div>';

    try {
      if (kind === 'image') return renderImage(host, path);
      if (kind === 'pdf') return renderPdf(host, path);

      // text/markdown/work/code → /cloud/file
      var r = await fetch('/cloud/file?path=' + encodeURIComponent(path), { credentials: 'same-origin' });
      var d = await r.json();
      if (d && d.error) { host.innerHTML = '<div class="wxerr">' + esc(d.error) + '</div>'; return; }
      if (d && d.binary) { return renderImage(host, path, true); } // server flagged binary → stream raw
      var content = (d && d.content) || '';
      if (kind === 'markdown') return renderMarkdown(host, content, d);
      return renderCode(host, content, path, d);
    } catch (e) {
      host.innerHTML = '<div class="wxerr">Could not open this file.</div>';
    }
  }

  function rawUrl(path){ return '/cloud/raw?path=' + encodeURIComponent(path); }

  function renderImage(host, path, asGeneric){
    host.innerHTML = '<div class="wximgwrap"><img src="' + esc(rawUrl(path)) + '" alt="' + esc(path) + '"/></div>';
  }

  async function renderMarkdown(host, content, meta){
    host.innerHTML = '<div class="wxmd markdown-body"></div>' + truncNote(meta);
    try {
      var mk = await marked();
      host.querySelector('.wxmd').innerHTML = mk.parse ? mk.parse(content) : mk(content);
    } catch (e) {
      host.querySelector('.wxmd').textContent = content; // fall back to raw text
    }
  }

  async function renderCode(host, content, path, meta){
    host.innerHTML = '<div class="wxsavebar"><span class="wxsavepath">' + esc(path) + '</span>' +
      '<button class="wxsave" data-save disabled>Saved</button></div>' +
      '<div id="wxcm" class="wxcm"></div>' + truncNote(meta);
    var mount = host.querySelector('#wxcm');
    var sb = host.querySelector('[data-save]'); if (sb) sb.onclick = save;
    state.editor = null; setDirty(false);
    try {
      var m = await cm();
      var ext6 = [
        m.view.lineNumbers(),
        m.view.highlightActiveLine(),
        m.cmds.history(),
        m.view.keymap.of(m.cmds.defaultKeymap.concat(m.cmds.historyKeymap)),
        m.EditorView.updateListener.of(function(u){ if (u.docChanged) setDirty(true); }),
        m.EditorView.theme({ '&': { height: '100%', fontSize: '12.5px' } })
      ];
      state.editor = new m.EditorView({ doc: content, extensions: ext6, parent: mount });
    } catch (e) {
      // basic fallback: a read-only <pre> (editing needs CodeMirror)
      mount.innerHTML = '<pre class="wxpre">' + esc(content) + '</pre>';
    }
  }

  function truncNote(meta){
    return (meta && meta.truncated)
      ? '<div class="wxtrunc">Showing the first 2 MB of a larger file. <a href="' + esc(rawUrl(state.active)) + '" target="_blank" rel="noopener">Open raw</a></div>'
      : '';
  }

  async function renderPdf(host, path){
    host.innerHTML = '<div class="wxpdf"><div class="wxpdftop"><span>PDF</span>' +
      '<a href="' + esc(rawUrl(path)) + '" target="_blank" rel="noopener">Open raw</a></div>' +
      '<div id="wxpdfpages" class="wxpdfpages"></div></div>';
    var pages = host.querySelector('#wxpdfpages');
    try {
      var lib = await pdfjs();
      var buf = await (await fetch(rawUrl(path), { credentials: 'same-origin' })).arrayBuffer();
      var doc = await lib.getDocument({ data: buf }).promise;
      var n = Math.min(doc.numPages, 10); // first up to 10 pages; raw link covers the rest
      for (var i = 1; i <= n; i++) {
        var page = await doc.getPage(i);
        var vp = page.getViewport({ scale: 1.3 });
        var canvas = document.createElement('canvas');
        canvas.width = vp.width; canvas.height = vp.height; canvas.className = 'wxpdfcanvas';
        pages.appendChild(canvas);
        await page.render({ canvasContext: canvas.getContext('2d'), viewport: vp }).promise;
      }
      if (doc.numPages > n) {
        var more = document.createElement('div');
        more.className = 'wxtrunc';
        more.innerHTML = 'Showing the first ' + n + ' of ' + doc.numPages + ' pages.';
        pages.appendChild(more);
      }
    } catch (e) {
      pages.innerHTML = '<div class="wxerr">Could not render this PDF. <a href="' + esc(rawUrl(path)) + '" target="_blank" rel="noopener">Open raw</a></div>';
    }
  }

  // ── nav (left) ──────────────────────────────────────────────────────────────────────────────
  function treeHtml(path, depth){
    if (state.treeLoading[path]) return '<div class="wxmsg" style="padding-left:' + (depth * 14 + 16) + 'px">Loading…</div>';
    var entries = state.treeData[path];
    if (!entries) return '';
    if (entries.length === 0) return '<div class="wxmsg" style="padding-left:' + (depth * 14 + 16) + 'px">Empty</div>';
    return entries.map(function(en){
      var pad = depth * 14 + 10;
      if (en.dir){
        var open = !!state.treeOpen[en.path];
        return '<div class="wxrow dir' + (open ? ' open' : '') + '" data-wxtoggle="' + esc(en.path) + '" style="padding-left:' + pad + 'px">' +
            '<span class="wxchev">▸</span><span class="wxfolder"></span><span class="wxname">' + esc(en.name) + '</span>' +
          '</div>' + (open ? treeHtml(en.path, depth + 1) : '');
      }
      return '<div class="wxrow file' + (state.active === en.path ? ' on' : '') + '" data-wxfile="' + esc(en.path) + '" data-wxlabel="' + esc(en.name) + '" style="padding-left:' + (pad + 16) + 'px">' +
          fileIcon(en.path) + '<span class="wxname">' + esc(en.name) + '</span>' +
          '<button class="wxpin' + (isBm(en.path) ? ' on' : '') + '" data-wxbm="' + esc(en.path) + '" data-wxbml="' + esc(en.name) + '" title="' + (isBm(en.path) ? 'Unpin' : 'Pin') + '">★</button>' +
        '</div>';
    }).join('');
  }

  function paintNav(){
    var nav = el.querySelector('#wxNav');
    if (!nav) return;
    var pinned = state.bm.length
      ? state.bm.map(function(b){
          return '<div class="wxrow file pinned' + (state.active === b.path ? ' on' : '') + '" data-wxfile="' + esc(b.path) + '" data-wxlabel="' + esc(b.label) + '">' +
            fileIcon(b.path) + '<span class="wxname">' + esc(b.label) + '</span>' +
            '<button class="wxpin on" data-wxbm="' + esc(b.path) + '" data-wxbml="' + esc(b.label) + '" title="Unpin">★</button>' +
          '</div>';
        }).join('')
      : '<div class="wxmsg">No pinned files. Click ★ on a file to pin it.</div>';

    nav.innerHTML =
      '<div class="wxsection"><div class="wxsechd">Pinned</div>' + pinned + '</div>' +
      '<div class="wxsection"><div class="wxsechd">Files</div>' + treeHtml('', 0) + '</div>';

    nav.querySelectorAll('[data-wxtoggle]').forEach(function(r){
      r.onclick = function(e){
        if (e.target.closest('[data-wxbm]')) return;
        var p = r.getAttribute('data-wxtoggle');
        if (state.treeOpen[p]) delete state.treeOpen[p]; else { state.treeOpen[p] = true; loadTree(p); }
        paintNav();
      };
    });
    nav.querySelectorAll('[data-wxfile]').forEach(function(r){
      r.onclick = function(e){
        if (e.target.closest('[data-wxbm]')) return;
        openFile(r.getAttribute('data-wxfile'), r.getAttribute('data-wxlabel'));
      };
    });
    nav.querySelectorAll('[data-wxbm]').forEach(function(b){
      b.onclick = function(e){ e.stopPropagation(); toggleBm(b.getAttribute('data-wxbm'), b.getAttribute('data-wxbml')); };
    });
  }

  // ── tabs (right) ────────────────────────────────────────────────────────────────────────────
  function paintTabs(){
    var bar = el.querySelector('#wxTabs');
    if (!bar) return;
    if (!state.tabs.length) { bar.innerHTML = '<div class="wxnotabs">No open files</div>'; return; }
    bar.innerHTML = state.tabs.map(function(t, i){
      var isDirty = state.active === t.path && state.dirty;
      return '<div class="wxtab' + (state.active === t.path ? ' on' : '') + (isDirty ? ' dirty' : '') + '" draggable="true" data-tab="' + esc(t.path) + '" data-i="' + i + '" title="' + esc(t.path) + '">' +
        fileIcon(t.path) + '<span class="wxtablbl">' + esc(t.label) + '</span>' +
        (isDirty ? '<span class="wxtabdot" title="Unsaved">●</span>' : '') +
        '<button class="wxtabx" data-tabx="' + esc(t.path) + '" title="Close" aria-label="Close">×</button>' +
      '</div>';
    }).join('');

    bar.querySelectorAll('[data-tab]').forEach(function(tb){
      tb.onclick = function(e){ if (e.target.closest('[data-tabx]')) return; state.active = tb.getAttribute('data-tab'); saveTabs(); paintTabs(); paintNav(); showActive(); };
      tb.ondragstart = function(){ state.dragFrom = parseInt(tb.getAttribute('data-i'), 10); };
      tb.ondragover = function(e){ e.preventDefault(); };
      tb.ondrop = function(e){
        e.preventDefault();
        var to = parseInt(tb.getAttribute('data-i'), 10), from = state.dragFrom;
        if (from == null || from === to) return;
        var moved = state.tabs.splice(from, 1)[0];
        state.tabs.splice(to, 0, moved);
        state.dragFrom = null; saveTabs(); paintTabs();
      };
    });
    bar.querySelectorAll('[data-tabx]').forEach(function(x){
      x.onclick = function(e){ e.stopPropagation(); closeTab(x.getAttribute('data-tabx')); };
    });
  }

  // ── workspace dropdown ──────────────────────────────────────────────────────────────────────
  function paintWsMenu(){
    var btn = el.querySelector('#wxWsBtn'), menu = el.querySelector('#wxWsMenu');
    if (!btn) return;
    btn.onclick = function(e){ e.stopPropagation(); menu.classList.toggle('open'); };
    menu.querySelectorAll('[data-wspick]').forEach(function(it){
      it.onclick = function(){ WB.ws.setActive(it.getAttribute('data-wspick')); WB.nav('/workspaces'); };
    });
    document.addEventListener('click', function once(){ menu && menu.classList.remove('open'); document.removeEventListener('click', once); });
  }

  // ── initial paint ───────────────────────────────────────────────────────────────────────────
  var wslist = WB.ws.list || [];
  var active = WB.ws.active;
  el.innerHTML =
    '<div class="wx">' +
      '<aside class="wxside">' +
        '<div class="wxwsbar">' +
          '<button class="wxwsbtn" id="wxWsBtn">' +
            '<span class="wxwsav">' + esc((active && (active.icon || (active.name || 'W')[0].toUpperCase())) || 'W') + '</span>' +
            '<span class="wxwsname">' + esc((active && active.name) || 'Workspace') + '</span>' +
            '<span class="wxwscar">▾</span>' +
          '</button>' +
          '<div class="wxwsmenu" id="wxWsMenu">' +
            (wslist.length ? wslist.map(function(w){
              return '<button class="wxwsitem' + (active && w.id === active.id ? ' on' : '') + '" data-wspick="' + esc(w.id) + '">' +
                '<span class="wxwsav sm">' + esc(w.icon || (w.name || 'W')[0].toUpperCase()) + '</span>' + esc(w.name) + '</button>';
            }).join('') : '<div class="wxmsg">No workspaces</div>') +
          '</div>' +
        '</div>' +
        '<div class="wxnav" id="wxNav"></div>' +
      '</aside>' +
      '<main class="wxmain">' +
        '<div class="wxtabs" id="wxTabs"></div>' +
        '<div class="wxviewer" id="wxViewer"></div>' +
      '</main>' +
    '</div>';

  paintWsMenu();
  paintNav();
  paintTabs();
  loadTree('');

  // ⌘S / Ctrl-S saves the active editor (the listener lives on el, which is recreated each render,
  // so it always closes over the current state). CodeMirror doesn't bind ⌘S, so it bubbles up here.
  el.addEventListener('keydown', function(e){
    if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); save(); }
  });

  // pick up a pending file from the sidebar (when this view wasn't mounted yet) + restore active
  if (WB._pendingFile) { var pf = WB._pendingFile; WB._pendingFile = null; openFile(pf); }
  else showActive();
}});

WB.scopedStyles('/workspaces', `
.wx { display: flex; height: 100%; min-height: 0; background: var(--paper); }
.wxside { flex: none; width: 280px; display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--line); background: var(--card); }
.wxwsbar { position: relative; padding: 10px; border-bottom: 1px solid var(--line); }
.wxwsbtn { width: 100%; display: flex; align-items: center; gap: 8px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 9px;
  background: var(--paper); color: var(--ink); cursor: pointer; font: 600 13.5px var(--read); }
.wxwsbtn:hover { border-color: var(--dim); }
.wxwsav { flex: none; width: 22px; height: 22px; border-radius: 6px; display: grid; place-items: center; background: var(--peach); color: #1a1b1e; font: 700 11px var(--read); }
.wxwsav.sm { width: 20px; height: 20px; }
.wxwsname { flex: 1; text-align: left; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wxwscar { color: var(--dim); font-size: 11px; }
.wxwsmenu { display: none; position: absolute; left: 10px; right: 10px; top: 52px; z-index: 20; background: var(--card);
  border: 1px solid var(--line); border-radius: 10px; box-shadow: 0 12px 30px rgba(0,0,0,.18); padding: 6px; max-height: 320px; overflow: auto; }
.wxwsmenu.open { display: block; }
.wxwsitem { width: 100%; display: flex; align-items: center; gap: 8px; padding: 7px 8px; border: none; background: none; cursor: pointer;
  color: var(--ink); font: 600 13px var(--read); border-radius: 7px; text-align: left; }
.wxwsitem:hover { background: var(--paper); }
.wxwsitem.on { background: var(--paper); }

.wxnav { flex: 1; min-height: 0; overflow: auto; padding: 8px 0 24px; }
.wxsection { margin-bottom: 6px; }
.wxsechd { font: 700 10.5px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--dim); padding: 8px 14px 4px; }
.wxrow { display: flex; align-items: center; gap: 7px; padding: 4px 10px 4px 0; cursor: pointer; font: 500 13px var(--read); color: var(--ink); user-select: none; }
.wxrow:hover { background: var(--paper); }
.wxrow.on { background: color-mix(in srgb, var(--peach) 30%, var(--paper)); }
.wxrow .wxname { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wxchev { flex: none; width: 12px; font-size: 10px; color: var(--dim); transition: transform .12s; }
.wxrow.dir.open .wxchev { transform: rotate(90deg); }
.wxfolder { flex: none; width: 0; }
.wxmsg { color: var(--dim); font: 500 12px var(--read); padding: 6px 14px; }
.ficon, .wkico { flex: none; width: 16px; height: 16px; display: inline-grid; place-items: center; }
.ficon svg { width: 16px; height: 16px; }
.wkico { width: 17px; height: 17px; border-radius: 5px; background: var(--ink); color: var(--paper); padding: 3px; }
.wkico svg { width: 100%; height: 100%; }
.wxpin { flex: none; opacity: 0; border: none; background: none; cursor: pointer; color: var(--dim); font-size: 13px; padding: 0 4px; }
.wxrow:hover .wxpin { opacity: 1; }
.wxpin.on { opacity: 1; color: var(--peach); }

.wxmain { flex: 1; min-width: 0; display: flex; flex-direction: column; min-height: 0; }
.wxtabs { flex: none; display: flex; align-items: stretch; gap: 0; height: 38px; border-bottom: 1px solid var(--line);
  background: var(--card); overflow-x: auto; }
.wxnotabs { display: flex; align-items: center; padding: 0 14px; color: var(--dim); font: 500 12.5px var(--read); }
.wxtab { display: flex; align-items: center; gap: 7px; padding: 0 10px 0 12px; border-right: 1px solid var(--line); cursor: pointer;
  font: 500 12.5px var(--read); color: var(--dim); background: var(--card); max-width: 220px; }
.wxtab:hover { color: var(--ink); }
.wxtab.on { color: var(--ink); background: var(--paper); box-shadow: inset 0 -2px 0 var(--peach); }
.wxtablbl { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wxtabx { border: none; background: none; cursor: pointer; color: var(--dim); font-size: 15px; line-height: 1; padding: 2px 3px; border-radius: 5px; }
.wxtabx:hover { background: var(--line); color: var(--ink); }

.wxviewer { flex: 1; min-height: 0; overflow: auto; background: var(--paper); position: relative; }
.wxloading, .wxerr { padding: 24px; color: var(--dim); font: 500 13px var(--read); }
.wxerr { color: var(--ink); }
.wxempty { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; color: var(--dim); }
.wxemptymk { width: 56px; height: 40px; color: var(--line); }
.wxemptymk svg { width: 100%; height: 100%; }
.wxempty p { font: 500 13.5px var(--read); margin: 0; }

.wxcm { height: calc(100% - 37px); }   /* leave room for the save bar */
.wxcm .cm-editor { height: 100%; background: var(--paper); }
.wxcm .cm-editor.cm-focused { outline: none; }
.wxcm .cm-scroller { font-family: var(--mono); color: var(--ink); }
.wxcm .cm-gutters { background: var(--card); border-right: 1px solid var(--line); color: var(--dim); }
.wxpre { margin: 0; padding: 16px; font: 12.5px/1.6 var(--mono); color: var(--ink); white-space: pre; }

.wxmd { padding: 28px 32px; max-width: 820px; font: 15px/1.7 var(--read); color: var(--ink); }
.wxmd h1, .wxmd h2, .wxmd h3 { font-weight: 700; letter-spacing: -.01em; margin: 1.4em 0 .5em; }
.wxmd h1 { font-size: 26px; } .wxmd h2 { font-size: 20px; } .wxmd h3 { font-size: 16px; }
.wxmd p { margin: .6em 0; } .wxmd ul, .wxmd ol { padding-left: 1.4em; }
.wxmd code { font: 13px var(--mono); background: var(--card); border: 1px solid var(--line); border-radius: 5px; padding: 1px 5px; }
.wxmd pre { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 14px; overflow: auto; }
.wxmd pre code { border: none; background: none; padding: 0; }
.wxmd a { color: var(--pcd); } .wxmd blockquote { border-left: 3px solid var(--line); padding-left: 14px; color: var(--dim); margin: .8em 0; }

.wximgwrap { padding: 24px; display: grid; place-items: center; }
.wximgwrap img { max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; background: #fff; }

.wxpdf { padding: 16px; }
.wxpdftop { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; color: var(--dim); font: 600 12px var(--mono); }
.wxpdftop a { color: var(--pcd); }
.wxpdfpages { display: flex; flex-direction: column; align-items: center; gap: 16px; }
.wxpdfcanvas { max-width: 100%; box-shadow: 0 4px 18px rgba(0,0,0,.18); border-radius: 4px; }

.wxtrunc { padding: 10px 16px; color: var(--dim); font: 500 12.5px var(--read); border-top: 1px solid var(--line); }
.wxtrunc a { color: var(--pcd); }
/* edit save bar (ship 4) */
.wxsavebar { display: flex; align-items: center; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--line); background: var(--card); }
.wxsavepath { flex: 1; min-width: 0; font: 500 11.5px var(--mono); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wxsave { flex: none; border: 1px solid var(--line); background: var(--card); color: var(--dim); border-radius: 7px; padding: 4px 12px; font: 600 12px var(--read); cursor: default; }
.wxsave.on { background: var(--ink); color: var(--paper); border-color: var(--ink); cursor: pointer; }
.wxtabdot { color: var(--peach, #f3c5a3); font-size: 10px; margin: 0 2px; }
`);
