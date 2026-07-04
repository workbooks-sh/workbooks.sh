// The Data explorer (wb-i54n). One route /data, three modes off the hash query:
//   #/data            → Overview/health (backend, durable DB size, cold replica, totals + resource cards)
//   #/data?r=<name>   → a resource ("table") as REAL paginated/sorted/searchable rows
//   #/data?assets=1   → media asset grid over the data volume + upload
// Tenant-scoped on the server; this is strictly current-tenant (see memory data-unit-is-resource).
WB.scopedStyles('/data', `
.dwrap { max-width: 1100px; }
.dmetrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 6px 0 22px; }
.dmetric { background: var(--card); border: 1px solid var(--line); border-radius: 13px; padding: 16px 18px; }
.dmlabel { font: 700 10px var(--read); letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }
.dmbig { font: 700 26px var(--read); color: var(--ink); margin-top: 8px; letter-spacing: -0.02em; }
.dmsub { font: 500 12px var(--read); color: var(--dim); margin-top: 6px; }
.dpill { display: inline-flex; align-items: center; gap: 5px; font: 600 11px var(--read); padding: 3px 9px; border-radius: 20px; border: 1px solid var(--line); color: var(--dim); }
.dpill.ok { color: var(--live, #3fb950); border-color: color-mix(in srgb, var(--live, #3fb950) 40%, transparent); }
.dpill.off { color: var(--dim); }
.dcards { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
.dcard { display: block; background: var(--card); border: 1px solid var(--line); border-radius: 13px; padding: 15px 17px; text-decoration: none; color: inherit; transition: border-color .12s, transform .08s; }
.dcard:hover { border-color: var(--stroke); transform: translateY(-1px); }
.dcard .dt { font: 600 15px var(--read); color: var(--ink); display: flex; align-items: center; gap: 7px; }
.dcard .ds { font: 500 12.5px var(--read); color: var(--dim); margin-top: 5px; }
.ddot2 { display: inline-block; width: 9px; height: 9px; border-radius: 3px; flex: 0 0 auto; }
.dcount { margin-left: auto; font: 600 11px var(--read); color: var(--dim); }
.dtoolbar { display: flex; align-items: center; gap: 10px; margin: 4px 0 14px; flex-wrap: wrap; }
.dsearch { flex: 1; min-width: 180px; background: var(--card); border: 1px solid var(--line); border-radius: 9px; padding: 8px 12px; font: 500 13px var(--read); color: var(--ink); }
.dtablewrap { overflow: auto; border: 1px solid var(--line); border-radius: 12px; background: var(--card); }
table.dtable { border-collapse: collapse; width: 100%; font: 500 13px var(--read); }
.dtable th { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--line); color: var(--dim); font-weight: 700; white-space: nowrap; cursor: pointer; user-select: none; position: sticky; top: 0; background: var(--card); }
.dtable th .sortcaret { color: var(--stroke); margin-left: 4px; }
.dtable td { padding: 9px 14px; border-bottom: 1px solid var(--line); color: var(--ink); vertical-align: top; max-width: 360px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dtable tr:last-child td { border-bottom: none; }
.dtype { font: 500 11px var(--read); color: var(--dim); font-weight: 500; margin-left: 6px; }
.dpager { display: flex; align-items: center; gap: 12px; justify-content: flex-end; margin: 12px 2px; font: 500 12.5px var(--read); color: var(--dim); }
.dbtn { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 6px 12px; font: 600 12.5px var(--read); color: var(--ink); cursor: pointer; }
.dbtn:disabled { opacity: .4; cursor: default; }
.dchips { display: flex; gap: 7px; flex-wrap: wrap; }
.dchip { background: var(--card); border: 1px solid var(--line); border-radius: 20px; padding: 5px 12px; font: 600 12px var(--read); color: var(--dim); cursor: pointer; }
.dchip.on { color: var(--ink); border-color: var(--stroke); }
.dgrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 12px; margin-top: 14px; }
.dasset { border: 1px solid var(--line); border-radius: 11px; overflow: hidden; background: var(--card); text-decoration: none; color: inherit; display: block; }
.dasset .thumb { height: 110px; display: flex; align-items: center; justify-content: center; background: var(--bg); overflow: hidden; }
.dasset .thumb img { width: 100%; height: 100%; object-fit: cover; }
.dasset .thumb .ph { font-size: 30px; color: var(--stroke); }
.dasset .meta { padding: 8px 10px; }
.dasset .an { font: 600 12.5px var(--read); color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dasset .as { font: 500 11px var(--read); color: var(--dim); margin-top: 2px; }
.duploadbar { display: flex; align-items: center; gap: 10px; margin: 4px 0 6px; flex-wrap: wrap; }
.dmsg { color: var(--dim); font: 500 13px var(--read); padding: 16px 4px; }
.dtags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 8px; }
.dtag { font: 600 10.5px var(--mono, monospace); color: var(--dim); background: var(--line); border-radius: 20px; padding: 2px 8px; }
.demptyrow td { padding: 28px 14px !important; }
`);

WB.view('/data', {
  title: 'Data',
  accent: 'var(--sky)',
  async render(el, ctx) {
    const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    const getJSON = (u) => fetch(u, { credentials: 'same-origin' }).then((r) => r.json());
    const human = (b) => {
      b = +b || 0; if (b < 1024) return b + ' B';
      const u = ['KB', 'MB', 'GB', 'TB']; let i = -1;
      do { b /= 1024; i++; } while (b >= 1024 && i < u.length - 1);
      return b.toFixed(b < 10 ? 1 : 0) + ' ' + u[i];
    };
    const hash = location.hash.slice(1) || '/data';
    const q = (k) => { const m = hash.match(new RegExp('[?&]' + k + '=([^&]+)')); return m ? decodeURIComponent(m[1]) : null; };
    const resourceName = q('r');
    const assetsMode = /[?&]assets=/.test(hash);

    if (resourceName) return renderResource(resourceName);
    if (assetsMode) return renderAssets();
    return renderOverview();

    // ── Overview / health ──────────────────────────────────────────────────────────────────────
    async function renderOverview() {
      el.innerHTML = `<section class="dwrap"><div class="sechead"><div><h2>Data</h2><p>Every table on your nexus, your storage health, and your assets — all current-tenant.</p></div></div><div class="dmsg">Loading…</div></section>`;
      const [health, list] = await Promise.all([
        getJSON('/cloud/data/health').catch(() => null),
        getJSON('/cloud/data').catch(() => ({ resources: [] }))
      ]);
      const resources = (list && list.resources) || [];
      const h = health || {};
      const cold = h.cold || { enabled: false };
      const metrics = `
        <div class="dmetrics">
          <div class="dmetric"><div class="dmlabel">Backend</div><div class="dmbig" style="font-size:18px">${esc(h.backend || '—')}</div><div class="dmsub">${h.durable ? 'Durable on disk' : 'In-memory'}</div></div>
          <div class="dmetric"><div class="dmlabel">Database size</div><div class="dmbig">${esc(h.db_size || '0 B')}</div><div class="dmsub">${(h.resources || 0)} resources · ${(h.rows || 0)} rows</div></div>
          <div class="dmetric"><div class="dmlabel">Cold storage</div><div class="dmbig" style="font-size:18px">${cold.enabled ? 'Replicated' : 'Local only'}</div><div class="dmsub">${cold.enabled ? esc(cold.target || 'object store') : 'No off-box replica configured'}</div></div>
          <div class="dmetric"><div class="dmlabel">Status</div><div class="dmbig" style="font-size:18px">${(h.rows || 0) > 0 ? 'Live' : 'Empty'}</div><div class="dmsub"><span class="dpill ${h.durable ? 'ok' : 'off'}">${h.durable ? 'durable' : 'ephemeral'}</span> ${cold.enabled ? '<span class="dpill ok">replicated</span>' : ''}</div></div>
        </div>`;
      const cards = resources.length
        ? `<div class="dcards">` + resources.map((r) => {
            const tags = (r.tags || []);
            return `
            <a class="dcard" href="#/data?r=${encodeURIComponent(r.name)}">
              <div class="dt"><span class="ddot2" style="background:${r.live ? 'var(--live,#3fb950)' : 'var(--line)'}"></span>${esc(r.name)}<span class="dcount">${r.count}</span></div>
              <div class="ds">${r.description ? esc(r.description) : esc(r.workspace || 'General') + ' · ' + (r.fields || []).length + ' field' + ((r.fields || []).length === 1 ? '' : 's')}</div>
              ${tags.length ? `<div class="dtags">` + tags.map((t) => `<span class="dtag">#${esc(t)}</span>`).join('') + `</div>` : ''}
            </a>`; }).join('') + `</div>`
        : `<div class="dmsg">No resources yet. Declare a <code>resource</code> block in any workbook and it appears here.</div>`;
      el.innerHTML = `<section class="dwrap"><div class="sechead"><div><h2>Data</h2><p>Every table on your nexus, your storage health, and your assets — all current-tenant.</p></div></div>${metrics}<h3 style="margin:6px 0 12px">Tables</h3>${cards}</section>`;
    }

    // ── Resource table (real pagination/sort/filter) ─────────────────────────────────────────────
    async function renderResource(name) {
      const state = { offset: 0, limit: 50, sort: '', dir: 'asc', q: '' };
      el.innerHTML = `<section class="dwrap">
        <div class="sechead"><div><h2>${esc(name)}</h2><p id="dsub">Rows for the current tenant. Search, sort and page through the full table.</p><div id="dmeta"></div></div></div>
        <div class="dtoolbar">
          <input class="dsearch" id="dq" placeholder="Search rows…" />
        </div>
        <div id="dtable"><div class="dmsg">Loading…</div></div>
        <div class="dpager" id="dpager"></div>
      </section>`;
      const tableEl = el.querySelector('#dtable');
      const pagerEl = el.querySelector('#dpager');
      const subEl = el.querySelector('#dsub');
      const metaEl = el.querySelector('#dmeta');
      const search = el.querySelector('#dq');
      let metaPainted = false;

      let debounce;
      search.addEventListener('input', () => {
        clearTimeout(debounce);
        debounce = setTimeout(() => { state.q = search.value; state.offset = 0; load(); }, 220);
      });

      // The resource's schema (fields + description + tags) from the cached resource list — always
      // available, so we can render COLUMNS even before/without the rows fetch (empty or failed).
      const schemaOf = () => {
        const cached = WB.cache.get('data:list');
        return ((cached && cached.resources) || []).find((r) => r.name === name) || null;
      };

      function paintMeta(d, schema) {
        if (metaPainted) return;
        const description = (d && d.description) || (schema && schema.description);
        const tags = (d && d.tags && d.tags.length ? d.tags : (schema && schema.tags)) || [];
        if (!description && !tags.length) return;   // nothing to show yet — try again next load
        metaPainted = true;
        if (description) subEl.textContent = description;
        metaEl.innerHTML = tags.length ? `<div class="dtags">` + tags.map((t) => `<span class="dtag">#${esc(t)}</span>`).join('') + `</div>` : '';
      }

      async function load() {
        const url = `/cloud/data/rows?name=${encodeURIComponent(name)}&offset=${state.offset}&limit=${state.limit}`
          + (state.sort ? `&sort=${encodeURIComponent(state.sort)}&dir=${state.dir}` : '')
          + (state.q ? `&q=${encodeURIComponent(state.q)}` : '');
        let d = null;
        try { d = await getJSON(url); } catch (e) { d = null; }
        if (d && d.error) { d = null; }

        // Fields come from the rows response when available, else the cached schema — so columns ALWAYS
        // render (an empty table, or a failed rows fetch, still shows its shape).
        const schema = schemaOf();
        const fields = (d && d.fields && d.fields.length ? d.fields : null) || (schema && schema.fields) || [];
        const rows = (d && d.rows) || [];
        paintMeta(d, schema);

        if (!fields.length) {
          tableEl.innerHTML = `<div class="dmsg">This resource declares no fields.</div>`;
          pagerEl.innerHTML = '';
          return;
        }
        const head = fields.map((f) => {
          const active = state.sort === f.name;
          const caret = active ? (state.dir === 'asc' ? '▲' : '▼') : '↕';
          return `<th data-sort="${esc(f.name)}">${esc(f.name)}<span class="dtype">${esc(f.type)}</span><span class="sortcaret">${caret}</span></th>`;
        }).join('');
        const emptyMsg = !d ? 'Couldn’t load rows — showing the columns.'
          : state.q ? 'No rows match “' + esc(state.q) + '”.'
          : 'This table is empty — no rows yet.';
        const body = rows.length
          ? rows.map((row) => `<tr>` + fields.map((f) => {
              let v = row[f.name];
              if (v == null) v = '';
              else if (typeof v === 'object') v = JSON.stringify(v);
              return `<td title="${esc(v)}">${esc(v)}</td>`;
            }).join('') + `</tr>`).join('')
          : `<tr class="demptyrow"><td colspan="${fields.length}"><div class="dmsg" style="text-align:center">${emptyMsg}</div></td></tr>`;
        tableEl.innerHTML = `<div class="dtablewrap"><table class="dtable"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
        tableEl.querySelectorAll('th[data-sort]').forEach((th) => {
          th.onclick = () => {
            const f = th.getAttribute('data-sort');
            if (state.sort === f) state.dir = state.dir === 'asc' ? 'desc' : 'asc';
            else { state.sort = f; state.dir = 'asc'; }
            state.offset = 0; load();
          };
        });
        if (!d) { pagerEl.innerHTML = ''; return; }   // rows fetch failed — columns shown, no pager
        const from = d.total ? d.offset + 1 : 0, to = Math.min(d.offset + d.limit, d.total);
        pagerEl.innerHTML =
          `<span>${from}–${to} of ${d.total}</span>`
          + `<button class="dbtn" id="dprev" ${d.offset <= 0 ? 'disabled' : ''}>Prev</button>`
          + `<button class="dbtn" id="dnext" ${to >= d.total ? 'disabled' : ''}>Next</button>`;
        const prev = pagerEl.querySelector('#dprev'), next = pagerEl.querySelector('#dnext');
        if (prev) prev.onclick = () => { state.offset = Math.max(0, state.offset - state.limit); load(); };
        if (next) next.onclick = () => { state.offset = state.offset + state.limit; load(); };
      }
      load();
    }

    // ── Assets (media grid + upload) ─────────────────────────────────────────────────────────────
    async function renderAssets() {
      let type = '';
      const workspaces = (WB.ws && WB.ws.list) || [];
      const wsOptions = workspaces.map((w) => `<option value="${esc(w.id)}">${esc(w.name || w.id)}</option>`).join('');
      el.innerHTML = `<section class="dwrap">
        <div class="sechead"><div><h2>Assets</h2><p>Media on your nexus volume. Preview, download, or upload into a workspace.</p></div></div>
        <div class="duploadbar">
          <select class="dbtn" id="dws" ${wsOptions ? '' : 'disabled'}>${wsOptions || '<option>No workspaces</option>'}</select>
          <input type="file" id="dfile" style="display:none" />
          <button class="dbtn" id="dupload" ${wsOptions ? '' : 'disabled'}>Upload asset</button>
          <span class="dmsg" id="dupmsg" style="padding:0"></span>
        </div>
        <div class="dchips" id="dchips"></div>
        <div id="dassets"><div class="dmsg">Loading…</div></div>
      </section>`;
      const chipsEl = el.querySelector('#dchips');
      const gridEl = el.querySelector('#dassets');
      const TYPES = [['', 'All'], ['image', 'Images'], ['video', 'Video'], ['audio', 'Audio'], ['pdf', 'PDF'], ['archive', 'Archives']];
      const PH = { image: '🖼', video: '🎬', audio: '🎵', pdf: '📄', archive: '🗜' };

      function paintChips() {
        chipsEl.innerHTML = TYPES.map(([v, l]) => `<button class="dchip${type === v ? ' on' : ''}" data-t="${v}">${l}</button>`).join('');
        chipsEl.querySelectorAll('[data-t]').forEach((b) => { b.onclick = () => { type = b.getAttribute('data-t'); paintChips(); load(); }; });
      }

      async function load() {
        let d;
        try { d = await getJSON('/cloud/assets' + (type ? '?type=' + type : '')); } catch (e) { gridEl.innerHTML = `<div class="dmsg">Failed to load.</div>`; return; }
        const assets = (d && d.assets) || [];
        if (!assets.length) { gridEl.innerHTML = `<div class="dmsg">No assets${type ? ' of this type' : ''} yet.</div>`; return; }
        gridEl.innerHTML = `<div class="dgrid">` + assets.map((a) => {
          const thumb = a.type === 'image'
            ? `<div class="thumb"><img loading="lazy" src="${esc(a.url)}" alt="${esc(a.name)}"></div>`
            : `<div class="thumb"><span class="ph">${PH[a.type] || '📁'}</span></div>`;
          return `<a class="dasset" href="${esc(a.url)}" target="_blank" rel="noopener" title="${esc(a.path)}">${thumb}<div class="meta"><div class="an">${esc(a.name)}</div><div class="as">${esc(a.workspace)} · ${human(a.size)}</div></div></a>`;
        }).join('') + `</div>`
          + (d.truncated ? `<div class="dmsg">Showing first ${assets.length} of ${d.total}.</div>` : '');
      }

      // Upload: read the chosen file as base64, POST to the server which commits it into the workspace.
      const fileInput = el.querySelector('#dfile');
      const upBtn = el.querySelector('#dupload');
      const upMsg = el.querySelector('#dupmsg');
      const wsSel = el.querySelector('#dws');
      if (upBtn) upBtn.onclick = () => fileInput.click();
      if (fileInput) fileInput.onchange = () => {
        const file = fileInput.files && fileInput.files[0];
        if (!file) return;
        const ws = wsSel.value;
        upMsg.textContent = 'Uploading ' + file.name + '…';
        const reader = new FileReader();
        reader.onload = async () => {
          try {
            const r = await fetch('/cloud/asset/upload', {
              method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ path: ws + '/assets/' + file.name, content: String(reader.result) })
            }).then((x) => x.json());
            if (r && r.ok) { upMsg.textContent = 'Uploaded.'; WB.toast && WB.toast('Uploaded ' + file.name); load(); }
            else { upMsg.textContent = (r && r.error) || 'Upload failed'; }
          } catch (e) { upMsg.textContent = 'Upload failed'; }
          fileInput.value = '';
        };
        reader.readAsDataURL(file);
      };

      paintChips();
      load();
    }
  }
});
