// Workspace file viewer — SINGLE DOCUMENT. The GLOBAL sidebar (workspace groups + their file trees)
// is the navigator now; this page just DISPLAYS whatever you open: code (CodeMirror, editable + ⌘S),
// markdown (marked), images, PDF (pdf.js) — all no-build from esm.sh. No internal file tree, no tabs:
// opening another file replaces the current one. When nothing is open, an explore grid lists the
// active workspace's files. Data path = the cloud `server :cloud` routes /cloud/file, /cloud/raw,
// /cloud/tree, /cloud/file/save. THE LINE: those routes + this page are OUR product (dogfood/cloud).

WB.view('/workspaces', { title: 'Workspaces', accent: 'var(--peach)', fullbleed: true, async render(el){
  var esc = WB.esc;

  function wsId(){ var w = WB.ws.active; return (w && w.id) || '_'; }
  function lastKey(){ return 'wb-lastfile-' + wsId(); }
  // The folder on the nexus volume is named by the workspace ID (work_dir(id)), so tree/explore key by id.
  function root(){ var w = WB.ws.active; return (w && w.id) || ''; }

  function ext(p){ var m = (p || '').toLowerCase().match(/\.([a-z0-9]+)$/); return m ? m[1] : ''; }
  function kindOf(p){
    var e = ext(p);
    if (e === 'work') return 'work';
    if (['png','jpg','jpeg','gif','svg','webp'].indexOf(e) >= 0) return 'image';
    if (e === 'pdf') return 'pdf';
    if (e === 'md') return 'markdown';
    return 'text';
  }
  function fileIcon(p, opts){ return WB.fileIcon ? WB.fileIcon(p, opts) : ''; }

  // ── state ───────────────────────────────────────────────────────────────────────────────────
  var state = { active: null, editor: null, dirty: false };

  function openFile(path){
    if (!path) return;
    state.active = path;
    try { localStorage.setItem(lastKey(), path); } catch (e) {}
    showActive();
  }
  // Hook so the shared sidebar's file click opens the file here when this view is mounted.
  WB.openInExplorer = function(path){ WB._pendingFile = null; openFile(path); };

  // ── editing: the workedit island owns the CodeMirror surface; this view supplies the save bar +
  //    the onSave (commit/push via the git remote). ⌘S is bound inside the island. ───────────────
  function setSaveBtn(label, on, disabled){
    var btn = el.querySelector('[data-save]');
    if (btn){ btn.disabled = !!disabled; btn.textContent = label; btn.classList.toggle('on', !!on); }
  }
  function setDirty(b){ state.dirty = b; setSaveBtn(b ? 'Save' : 'Saved', b, !b); }
  // The island calls this with the current text; return false on failure (island stays dirty).
  async function persist(content){
    if (!state.active) return false;
    setSaveBtn('Saving…', true, true);
    try {
      var r = await fetch('/cloud/file/save', { method: 'POST', credentials: 'same-origin',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify({ path: state.active, content: content }) });
      var d = await r.json();
      if (d && d.ok){ WB.toast('Saved' + (d.sha ? ' · ' + d.sha : '')); return true; }
      WB.toast((d && d.error) || 'Save failed', 'bad'); setSaveBtn('Save', true, false); return false;
    } catch (e) { WB.toast('Save failed', 'bad'); setSaveBtn('Save', true, false); return false; }
  }
  function save(){ if (state.editor) state.editor.save(); }

  // ── viewers (lazy esm imports, cached across the session) ───────────────────────────────────
  var _pdf = null, _marked = null, _workedit = null;
  // The editor surface is the workedit island (loads CodeMirror itself).
  function workedit(){
    if (_workedit) return _workedit;
    _workedit = import((WB.vurl || function(u){ return u; })('../workedit/core.js'));
    return _workedit;
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
  function rawUrl(path){ return '/cloud/raw?path=' + encodeURIComponent(path); }
  function truncNote(meta){
    return (meta && meta.truncated)
      ? '<div class="wxtrunc">Showing the first 2 MB of a larger file. <a href="' + esc(rawUrl(state.active)) + '" target="_blank" rel="noopener">Open raw</a></div>'
      : '';
  }

  async function showActive(){
    var host = viewerHost();
    if (!host) return;
    if (!state.active) return showExplore();
    var path = state.active, kind = kindOf(path);
    host.innerHTML = '<div class="wxloading">Loading ' + esc(path.split('/').pop()) + '…</div>';
    try {
      if (kind === 'image') return renderImage(host, path);
      if (kind === 'pdf') return renderPdf(host, path);
      var r = await fetch('/cloud/file?path=' + encodeURIComponent(path), { credentials: 'same-origin' });
      var d = await r.json();
      if (d && d.error) { host.innerHTML = '<div class="wxerr">' + esc(d.error) + '</div>'; return; }
      if (d && d.binary) { return renderImage(host, path, true); }
      var content = (d && d.content) || '';
      if (kind === 'markdown') return renderMarkdown(host, content, d);
      return renderCode(host, content, path, d);
    } catch (e) {
      host.innerHTML = '<div class="wxerr">Could not open this file.</div>';
    }
  }

  function renderImage(host, path){
    host.innerHTML = '<div class="wxhdr"><span class="wxhdrpath">' + esc(path) + '</span></div>' +
      '<div class="wximgwrap"><img src="' + esc(rawUrl(path)) + '" alt="' + esc(path) + '"/></div>';
  }

  async function renderMarkdown(host, content, meta){
    host.innerHTML = '<div class="wxhdr"><span class="wxhdrpath">' + esc(state.active) + '</span></div>' +
      '<div class="wxmd markdown-body"></div>' + truncNote(meta);
    try {
      var mk = await marked();
      host.querySelector('.wxmd').innerHTML = mk.parse ? mk.parse(content) : mk(content);
    } catch (e) {
      host.querySelector('.wxmd').textContent = content;
    }
  }

  async function renderCode(host, content, path, meta){
    host.innerHTML = '<div class="wxsavebar"><span class="wxsavepath">' + esc(path) + '</span>' +
      '<button class="wxsave" data-save disabled>Saved</button></div>' +
      '<div id="wxcm" class="wxcm"></div>' + truncNote(meta);
    var mount = host.querySelector('#wxcm');
    var sb = host.querySelector('[data-save]'); if (sb) sb.onclick = save;
    if (state.editor && state.editor.destroy) { try { state.editor.destroy(); } catch (e) {} }
    state.editor = null; setDirty(false);
    try {
      var WE = await workedit();
      state.editor = await WE.createEditor(mount, {
        doc: content, path: path,
        resolveModule: WB.vurl,
        onDirtyChange: setDirty,
        onSave: persist,
        // .work lint: the nexus parses the buffer (Nexus.Literate + per-block Elixir check).
        lintSource: function(text){
          return fetch('/cloud/parse', { method: 'POST', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' }, body: JSON.stringify({ path: path, content: text }) })
            .then(function(r){ return r.json(); }).then(function(d){ return (d && d.diagnostics) || []; });
        },
      });
    } catch (e) {
      mount.innerHTML = '<pre class="wxpre">' + esc(content) + '</pre>';
    }
  }

  async function renderPdf(host, path){
    host.innerHTML = '<div class="wxpdf"><div class="wxpdftop"><span>' + esc(path) + '</span>' +
      '<a href="' + esc(rawUrl(path)) + '" target="_blank" rel="noopener">Open raw</a></div>' +
      '<div id="wxpdfpages" class="wxpdfpages"></div></div>';
    var pages = host.querySelector('#wxpdfpages');
    try {
      var lib = await pdfjs();
      var buf = await (await fetch(rawUrl(path), { credentials: 'same-origin' })).arrayBuffer();
      var doc = await lib.getDocument({ data: buf }).promise;
      var n = Math.min(doc.numPages, 10);
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

  // ── explore (empty state): a grid of the active workspace's files; dirs drill in ──────────────
  async function showExplore(path){
    var host = viewerHost();
    if (!host) return;
    var base = root();
    path = (path === undefined) ? base : path;
    var atRoot = path === base;
    host.innerHTML =
      '<div class="wxexplore">' +
        '<div class="wxexhd">' +
          (atRoot ? '' : '<button class="wxback" data-xback>‹ ' + esc((WB.ws.active && WB.ws.active.name) || 'Workspace') + '</button>') +
          '<span class="wxexname">' + esc(atRoot ? ((WB.ws.active && WB.ws.active.name) || 'Workspace') : path.split('/').pop()) + '</span>' +
        '</div>' +
        '<div class="wxgrid" id="wxGrid"><div class="wxmsg">Loading…</div></div>' +
      '</div>';
    var bk = host.querySelector('[data-xback]'); if (bk) bk.onclick = function(){ showExplore(base); };
    try {
      var r = await fetch('/cloud/tree' + (path ? '?path=' + encodeURIComponent(path) : ''), { credentials: 'same-origin' });
      var d = await r.json();
      var ents = (d && d.entries) || [];
      var grid = host.querySelector('#wxGrid');
      if (!grid) return;
      if (!ents.length){ grid.innerHTML = '<div class="wxmsg">This workspace is empty.</div>'; return; }
      grid.innerHTML = ents.map(function(en){
        return '<button class="wxcard" data-xopen="' + esc(en.path) + '" data-xdir="' + (en.dir ? '1' : '') + '">' +
          '<span class="wxcardico">' + fileIcon(en.name, { dir: en.dir }) + '</span>' +
          '<span class="wxcardname">' + esc(en.name) + '</span></button>';
      }).join('');
      grid.querySelectorAll('[data-xopen]').forEach(function(b){
        b.onclick = function(){
          if (b.getAttribute('data-xdir')) showExplore(b.getAttribute('data-xopen'));
          else openFile(b.getAttribute('data-xopen'));
        };
      });
    } catch (e) {
      var g = host.querySelector('#wxGrid'); if (g) g.innerHTML = '<div class="wxmsg">Couldn’t list files.</div>';
    }
  }

  // ── mount ───────────────────────────────────────────────────────────────────────────────────
  el.innerHTML = '<div class="wxv"><div class="wxviewer" id="wxViewer"></div></div>';

  // ⌘S / Ctrl-S saves the active editor (CodeMirror doesn't bind ⌘S, so it bubbles up here).
  el.addEventListener('keydown', function(e){
    if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); save(); }
  });

  // Open a pending file from the sidebar; else restore the last file opened in this workspace; else explore.
  if (WB._pendingFile) { var pf = WB._pendingFile; WB._pendingFile = null; openFile(pf); }
  else {
    var last = null; try { last = localStorage.getItem(lastKey()); } catch (e) {}
    if (last) openFile(last); else showActive();
  }
}});

WB.scopedStyles('/workspaces', `
.wxv { height: 100%; min-height: 0; background: var(--paper); }
.wxviewer { height: 100%; min-height: 0; overflow: auto; background: var(--paper); position: relative; }
.wxloading, .wxerr { padding: 24px; color: var(--dim); font: 500 13px var(--read); }
.wxerr { color: var(--ink); }
.wxhdr { display: flex; align-items: center; padding: 8px 14px; border-bottom: 1px solid var(--line); background: var(--card); }
.wxhdrpath { font: 500 11.5px var(--mono); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

/* explore grid (empty state) */
.wxexplore { padding: 22px 26px 60px; }
.wxexhd { display: flex; align-items: center; gap: 12px; margin-bottom: 18px; }
.wxexname { font: 700 18px var(--read); color: var(--ink); }
.wxback { border: 1px solid var(--line); background: var(--card); color: var(--ink); border-radius: 8px; padding: 5px 11px; font: 600 12.5px var(--read); cursor: pointer; }
.wxback:hover { border-color: var(--dim); }
.wxgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(132px, 1fr)); gap: 10px; }
.wxcard { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 20px 12px 16px; border: 1px solid var(--line);
  border-radius: 12px; background: var(--card); color: var(--ink); cursor: pointer; text-align: center; }
.wxcard:hover { border-color: var(--dim); background: color-mix(in srgb, var(--peach) 12%, var(--card)); }
.wxcardico { width: 34px; height: 34px; display: inline-grid; place-items: center; }
.wxcardico svg, .wxcardico img { width: 32px; height: 32px; }
.wxcardname { font: 500 12.5px var(--read); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
.wxmsg { color: var(--dim); font: 500 13px var(--read); padding: 8px 2px; grid-column: 1 / -1; }

/* code editor */
.wxsavebar { display: flex; align-items: center; gap: 10px; padding: 6px 12px; border-bottom: 1px solid var(--line); background: var(--card); }
.wxsavepath { flex: 1; min-width: 0; font: 500 11.5px var(--mono); color: var(--dim); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wxsave { flex: none; border: 1px solid var(--line); background: var(--card); color: var(--dim); border-radius: 7px; padding: 4px 12px; font: 600 12px var(--read); cursor: default; }
.wxsave.on { background: var(--ink); color: var(--paper); border-color: var(--ink); cursor: pointer; }
.wxcm { height: calc(100% - 37px); }
.wxcm .cm-editor { height: 100%; background: var(--paper); }
.wxcm .cm-editor.cm-focused { outline: none; }
.wxcm .cm-scroller { font-family: var(--mono); color: var(--ink); }
.wxcm .cm-gutters { background: var(--card); border-right: 1px solid var(--line); color: var(--dim); }
.wxpre { margin: 0; padding: 16px; font: 12.5px/1.6 var(--mono); color: var(--ink); white-space: pre; }

/* markdown */
.wxmd { padding: 28px 32px; max-width: 820px; font: 15px/1.7 var(--read); color: var(--ink); }
.wxmd h1, .wxmd h2, .wxmd h3 { font-weight: 700; letter-spacing: -.01em; margin: 1.4em 0 .5em; }
.wxmd h1 { font-size: 26px; } .wxmd h2 { font-size: 20px; } .wxmd h3 { font-size: 16px; }
.wxmd p { margin: .6em 0; } .wxmd ul, .wxmd ol { padding-left: 1.4em; }
.wxmd code { font: 13px var(--mono); background: var(--card); border: 1px solid var(--line); border-radius: 5px; padding: 1px 5px; }
.wxmd pre { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 14px; overflow: auto; }
.wxmd pre code { border: none; background: none; padding: 0; }
.wxmd a { color: var(--pcd); } .wxmd blockquote { border-left: 3px solid var(--line); padding-left: 14px; color: var(--dim); margin: .8em 0; }

/* image + pdf */
.wximgwrap { padding: 24px; display: grid; place-items: center; }
.wximgwrap img { max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; background: #fff; }
.wxpdf { padding: 16px; }
.wxpdftop { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; color: var(--dim); font: 600 12px var(--mono); }
.wxpdftop a { color: var(--pcd); }
.wxpdfpages { display: flex; flex-direction: column; align-items: center; gap: 16px; }
.wxpdfcanvas { max-width: 100%; box-shadow: 0 4px 18px rgba(0,0,0,.18); border-radius: 4px; }
.wxtrunc { padding: 10px 16px; color: var(--dim); font: 500 12.5px var(--read); border-top: 1px solid var(--line); }
.wxtrunc a { color: var(--pcd); }
`);
