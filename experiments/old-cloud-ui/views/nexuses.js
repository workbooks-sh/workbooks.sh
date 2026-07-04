// ── styles: nexus detail uses shared dashboard styles; History + Drafts panels inline their <style> ──
WB.scopedStyles('/nexuses', `
  /* History.svelte */
  .hh { display:flex; align-items:center; justify-content:space-between; gap:12px;
    padding:14px 18px; border-bottom:2px solid var(--line); }
  .empty { padding:26px 18px; text-align:center; color:var(--dim); font-size:13px; }

  .tl { list-style:none; margin:0; padding:6px 0; }
  .tl li { display:flex; gap:0; }
  .rail { position:relative; width:34px; flex:none; }
  /* the connecting line */
  .rail::before { content:''; position:absolute; left:50%; top:0; bottom:0; width:2px;
    background:var(--line); transform:translateX(-50%); }
  .tl li:first-child .rail::before { top:18px; }
  .tl li:last-child .rail::before { bottom:auto; height:18px; }
  .node { position:absolute; left:50%; top:16px; width:11px; height:11px; border-radius:50%;
    transform:translateX(-50%); border:2px solid var(--card); box-sizing:content-box; z-index:1;
    background:var(--sky); }
  .node.agent { background:var(--bloomd); }
  .node.head { box-shadow:0 0 0 3px color-mix(in srgb, var(--bloomd) 22%, transparent); }

  .body { flex:1; min-width:0; border-bottom:1px solid var(--line); }
  .tl li:last-child .body { border-bottom:0; }

  .row { width:100%; display:flex; align-items:center; gap:11px; padding:11px 18px 11px 4px;
    background:none; border:0; cursor:pointer; text-align:left; color:inherit; }
  .row:hover { background:var(--panel-2, color-mix(in srgb, var(--ink) 4%, transparent)); }
  .av { width:28px; height:28px; border-radius:50%; flex:none; display:grid; place-items:center;
    font:700 10.5px var(--mono); color:var(--on-bloom); border:2px solid var(--stroke);
    background:var(--sky); }
  .av.agent { background:var(--bloomd); }
  .meta { flex:1; min-width:0; display:flex; flex-direction:column; gap:1px; }
  .title { font-weight:600; font-size:13.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .sub { font-size:11.5px; color:var(--dim); }
  .caret { font-size:18px; color:var(--dim); transition:transform .15s; flex:none; padding-right:6px; }
  .caret.up { transform:rotate(90deg); }

  .diff { padding:0 18px 14px 4px; }
  .dgrid { font:12px/1.65 var(--mono); border:2px solid var(--line); border-radius:8px;
    overflow:hidden; background:var(--paper); }
  .dl { padding:0 10px; white-space:pre-wrap; word-break:break-word; }
  .dl .sign { display:inline-block; width:1.1em; color:var(--dim); user-select:none; }
  .dl.add { background:color-mix(in srgb, var(--bloomd) 15%, transparent); }
  .dl.add .sign { color:var(--bloomd); }
  .dl.del { background:var(--bad-fill); }
  .dl.del .sign { color:var(--bad); }
  .dl.del { color:var(--dim); }
  .dfoot { margin-top:10px; }

  /* Drafts.svelte */
  .dh { display:flex; align-items:center; justify-content:space-between; gap:12px;
    padding:14px 18px; border-bottom:2px solid var(--line); }
  .empty { padding:24px 18px; text-align:center; color:var(--dim); font-size:13px; }
  .dl { list-style:none; margin:0; padding:6px 0; }
  .dl > li { border-bottom:1px solid var(--line); }
  .dl > li:last-child { border-bottom:0; }
  .row { width:100%; display:flex; align-items:center; gap:11px; padding:12px 18px;
    background:none; border:0; cursor:pointer; text-align:left; color:inherit; }
  .row:hover { background:color-mix(in srgb, var(--ink) 4%, transparent); }
  .dot.draft { width:9px; height:9px; border-radius:50%; flex:none; background:var(--amber);
    box-shadow:0 0 0 3px color-mix(in srgb, var(--amber) 22%, transparent); }
  .meta { flex:1; min-width:0; display:flex; flex-direction:column; gap:1px; }
  .dname { font-weight:600; font-size:13.5px; }
  .sub { font-size:11.5px; color:var(--dim); }
  .caret { font-size:18px; color:var(--dim); transition:transform .15s; }
  .caret.up { transform:rotate(90deg); }
  .body { padding:2px 18px 16px 38px; }
  .files { list-style:none; margin:0 0 12px; padding:0; }
  .files li { display:flex; justify-content:space-between; padding:4px 0; border-bottom:1px solid var(--line); }
  .files li:last-child { border-bottom:0; }
  .acts { display:flex; align-items:center; gap:8px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
`);

WB.view('/nexuses', {
  title: 'Nexus',
  accent: 'var(--mint)',
  async render(el, ctx) {
    const id = ctx.params.id;
    const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    const detail = WB.nexus.detail(id);
    const nexus = detail && detail.nexus;
    const config = detail && detail.config;

    // ── not-found path ──
    if (!nexus) {
      el.innerHTML = `
  <section>
    <a class="dim" href="/" style="font-size:13px;display:inline-flex;gap:6px;align-items:center;margin-bottom:16px">← all nexuses</a>
    <div class="card" style="text-align:center;color:var(--dim)">
      Nexus “${esc(id)}” not found. It may have been deleted.
    </div>
  </section>`;
      const back = el.querySelector('a.dim');
      if (back) back.onclick = (e) => { e.preventDefault(); WB.nav('/'); };
      return;
    }

    // Real per-nexus usage from the platform rollup.
    let usageRow = null;
    async function loadUsage() {
      try {
        const u = await WB.api.nexusUsage();
        usageRow = (u.rows || []).find((r) => r.name === id) || null;
      } catch {
        usageRow = null;
      }
      paint();
    }

    const stateLabel = nexus.state === 'run' ? 'Running' : nexus.state === 'sleep' ? 'Sleeping' : 'Building';
    const activeHrs = () => (usageRow && usageRow.activeHrs != null ? usageRow.activeHrs : '0.0');
    const costMonth = () => (usageRow && usageRow.cost != null ? usageRow.cost : '$0.00');
    const dbLabel = () => (usageRow && usageRow.database != null ? usageRow.database : (config && config.database != null ? config.database : 'none'));

    // ── lifecycle actions ──
    function sleepIt() {
      WB.nexus.setState(id, 'sleep');
      WB.toast(`${nexus.name} is sleeping`);
    }
    function wake() {
      WB.nexus.setState(id, 'run');
      WB.toast(`${nexus.name} is waking…`);
    }
    async function restart() {
      WB.toast(`Restarting ${nexus.name}…`);
      await WB.nexus.setState(id, 'sleep');
      await WB.nexus.setState(id, 'run');
      WB.toast(`${nexus.name} restarted`);
    }
    async function reallyDelete() {
      const ok = await WB.confirm({
        title: `Delete ${nexus.name}?`,
        body: 'This permanently deletes the nexus and its storage. This cannot be undone.',
        danger: true
      });
      if (!ok) return;
      const nm = nexus.name;
      WB.nexus.remove(id);
      WB.toast(`Deleted ${nm}`, 'bad');
      WB.nav('/');
    }

    function stateAction() {
      if (nexus.state === 'sleep') return `<button class="btn sm" data-wake>Wake</button>`;
      if (nexus.state === 'run') return `<button class="btn sm" data-sleep>Sleep</button>`;
      return '';
    }

    function paint() {
      el.innerHTML = `
<section>
  <a class="dim" href="/" data-back style="font-size:13px;display:inline-flex;gap:6px;align-items:center;margin-bottom:16px">← all nexuses</a>

  <div class="sechead">
    <div>
      <h2 style="display:flex;align-items:center;gap:11px"><span class="dot ${esc(nexus.state)}"></span><span>${esc(nexus.name)}</span></h2>
      <p class="mono">${esc(config.plan)} · ${esc(config.region)}</p>
    </div>
    <div style="display:flex;gap:8px">
      <button class="btn sm" data-open>Open ↗</button>
      <button class="btn sm" data-restart${nexus.state === 'build' ? ' disabled' : ''}>Restart</button>
      ${stateAction()}
      <a class="btn sm" href="/settings" data-settings>Settings</a>
    </div>
  </div>

  <div class="stats">
    <div class="stat"><div class="k">State</div><div class="v">${esc(stateLabel)}</div><div class="d dim">scale-to-zero</div></div>
    <div class="stat"><div class="k">Plan</div><div class="v" style="font-size:18px">${esc(config.plan)}</div><div class="d dim">unlimited users</div></div>
    <div class="stat"><div class="k">Active compute</div><div class="v">${esc(activeHrs())}<small>hrs</small></div><div class="d dim">this cycle</div></div>
    <div class="stat"><div class="k">Est. this cycle</div><div class="v">${esc(costMonth())}</div><div class="d dim">at current rate</div></div>
  </div>

  <div class="grid-2">
    <div class="card">
      <h3>Configuration</h3>
      <div class="kv"><span class="k">Region</span><span class="v">${esc(config.region)}</span></div>
      <div class="kv"><span class="k">Plan</span><span class="v">${esc(config.plan)}</span></div>
      <div class="kv"><span class="k">Status</span><span class="v" style="color:var(--live)">${esc(config.status)}</span></div>
      <div class="kv"><span class="k">Storage addon</span><span class="v">${esc(config.storage)}</span></div>
      <div class="kv"><span class="k">Database</span><span class="v faint">${esc(config.database)}</span></div>
      <div class="kv"><span class="k">Created</span><span class="v">${esc(config.created)}</span></div>
    </div>
    <div class="card">
      <h3>This cycle</h3>
      <div class="kv"><span class="k">Active compute</span><span class="v">${esc(activeHrs())} hrs</span></div>
      <div class="kv"><span class="k">Storage</span><span class="v">${esc((usageRow && usageRow.storage) || '—')}</span></div>
      <div class="kv"><span class="k">Database</span><span class="v faint">${esc(dbLabel())}</span></div>
      <div class="kv"><span class="k">Egress</span><span class="v">$0.00</span></div>
      <div class="kv"><span class="k">Subtotal</span><span class="v" style="color:var(--live)">${esc(costMonth())}</span></div>
    </div>
  </div>

  <div data-drafts></div>

  <div data-history></div>

  <div class="card danger-zone">
    <h3>Danger zone</h3>
    <div style="display:flex;align-items:center;justify-content:space-between">
      <p class="dim" style="font-size:13px">Permanently delete this nexus and its storage. This cannot be undone.</p>
      <button class="btn danger sm" data-delete>Delete nexus</button>
    </div>
  </div>
</section>`;

      el.querySelector('[data-back]').onclick = (e) => { e.preventDefault(); WB.nav('/'); };
      el.querySelector('[data-open]').onclick = () => window.open(nexus.url, '_blank');
      const rb = el.querySelector('[data-restart]');
      rb.onclick = restart;
      const wb = el.querySelector('[data-wake]'); if (wb) wb.onclick = wake;
      const sb = el.querySelector('[data-sleep]'); if (sb) sb.onclick = sleepIt;
      el.querySelector('[data-settings]').onclick = (e) => { e.preventDefault(); WB.nav('/settings'); };
      el.querySelector('[data-delete]').onclick = reallyDelete;

      mountDrafts(el.querySelector('[data-drafts]'), id);
      mountHistory(el.querySelector('[data-history]'), id);
    }

    paint();
    loadUsage();
  }
});

// ── inlined Drafts.svelte ─────────────────────────────────────────────────────
function mountDrafts(host, nexus) {
  const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const STATUS_STYLE = {
    added: 'color:var(--bloomd)',
    modified: 'color:var(--amber)',
    removed: 'color:var(--bad)'
  };
  const statusMark = { added: '+ new', modified: '~ changed', removed: '− removed' };

  let drafts = [];
  let loading = true;
  let openName = null;
  let changes = null;
  let busy = null;
  let newOpen = false;
  let newName = '';

  async function load() {
    loading = true;
    paint();
    drafts = await WB.api.listDrafts(nexus);
    loading = false;
    paint();
  }

  async function toggle(d) {
    if (openName === d.name) { openName = null; changes = null; paint(); return; }
    openName = d.name; changes = null;
    paint();
    changes = await WB.api.draftDiff(nexus, d.name);
    paint();
  }

  async function startDraft() {
    const name = newName.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
    if (!name) { WB.toast('Give the draft a name'); return; }
    const d = await WB.api.createDraft(nexus, name);
    drafts = [d, ...drafts];
    newOpen = false; newName = '';
    paint();
    WB.toast(`Draft “${d.name}” started`);
  }

  async function keep(d) {
    busy = d.name;
    paint();
    await WB.api.keepDraft(nexus, d.name);
    busy = null;
    drafts = drafts.filter((x) => x.name !== d.name);
    openName = null; changes = null;
    paint();
    WB.toast(`Kept “${d.name}” — it’s now live`);
  }

  async function discard(d) {
    const ok = await WB.confirm({
      title: 'Discard this draft?',
      body: `“${d.name}” and its ${d.files_changed} change${d.files_changed === 1 ? '' : 's'} will be thrown away. The live version is untouched.`,
      danger: true
    });
    if (!ok) return;
    busy = d.name;
    paint();
    await WB.api.discardDraft(nexus, d.name);
    busy = null;
    drafts = drafts.filter((x) => x.name !== d.name);
    openName = null; changes = null;
    paint();
    WB.toast(`Discarded “${d.name}”`, 'bad');
  }

  function bodyFor(d) {
    if (openName !== d.name) return '';
    let inner;
    if (changes === null) {
      inner = `<div class="empty" style="border:0;padding:14px">Loading changes…</div>`;
    } else if (changes.length === 0) {
      inner = `<div class="faint" style="padding:6px 0 12px;font-size:12.5px">No changes yet in this draft.</div>`;
    } else {
      inner = `<ul class="files">${changes.map((c) => `<li><span class="mono" style="font-size:12.5px">${esc(c.path)}</span><span class="mono" style="font-size:11px;${STATUS_STYLE[c.status]}">${statusMark[c.status]}</span></li>`).join('')}</ul>`;
    }
    return `
            <div class="body">
              ${inner}
              <div class="acts">
                <a class="btn sm" href="${esc('/' + d.preview_path)}" data-preview>Preview</a>
                <div style="flex:1"></div>
                <button class="btn sm" data-discard="${esc(d.name)}"${busy === d.name ? ' disabled' : ''}>Discard</button>
                <button class="btn sm primary" data-keep="${esc(d.name)}"${busy === d.name ? ' disabled' : ''}>${busy === d.name ? 'Keeping…' : 'Keep'}</button>
              </div>
            </div>`;
  }

  function listHtml() {
    if (loading) return `<div class="empty">Loading…</div>`;
    if (drafts.length === 0) return `<div class="empty">No drafts. Start one to try changes without touching the live version.</div>`;
    return `<ul class="dl">${drafts.map((d) => `
        <li>
          <button class="row" data-toggle="${esc(d.name)}" aria-expanded="${openName === d.name}">
            <span class="dot draft"></span>
            <span class="meta">
              <span class="dname">${esc(d.name)}</span>
              <span class="sub">${d.files_changed} ${d.files_changed === 1 ? 'change' : 'changes'}</span>
            </span>
            <span class="caret${openName === d.name ? ' up' : ''}">›</span>
          </button>
          ${bodyFor(d)}
        </li>`).join('')}
    </ul>`;
  }

  function modalHtml() {
    if (!newOpen) return '';
    return `
  <div class="modal" data-modal>
    <div class="sheet" style="width:420px">
      <h2>New draft</h2>
      <p class="sub">A draft is a safe copy of this workspace. Edits stay in the draft until you Keep them.</p>
      <div class="lab">Name</div>
      <div class="field"><input type="text" placeholder="spring-refresh" data-newname value="${esc(newName)}" /></div>
      <div class="sheet-foot">
        <button class="btn" type="button" data-cancel>Cancel</button>
        <button class="btn primary" type="button" data-start>Start draft</button>
      </div>
    </div>
  </div>`;
  }

  function paint() {
    host.innerHTML = `
<div class="card" style="padding:0;overflow:hidden">
  <div class="dh">
    <div style="display:flex;flex-direction:column;gap:1px">
      <b style="font-size:13.5px">Drafts <span class="dim mono" style="font-weight:400">· ${drafts.length}</span></b>
      <span class="faint" style="font-size:11.5px">Try a change safely — the live version keeps running until you Keep.</span>
    </div>
    <button class="btn sm primary" data-new>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> New draft
    </button>
  </div>
  ${listHtml()}
</div>
${modalHtml()}`;

    host.querySelector('[data-new]').onclick = () => { newOpen = true; paint(); };
    host.querySelectorAll('[data-toggle]').forEach((b) => {
      b.onclick = () => toggle(drafts.find((d) => d.name === b.dataset.toggle));
    });
    host.querySelectorAll('[data-keep]').forEach((b) => {
      b.onclick = () => keep(drafts.find((d) => d.name === b.dataset.keep));
    });
    host.querySelectorAll('[data-discard]').forEach((b) => {
      b.onclick = () => discard(drafts.find((d) => d.name === b.dataset.discard));
    });
    const prev = host.querySelector('[data-preview]');
    if (prev) prev.onclick = (e) => { e.preventDefault(); WB.toast('Opening preview…'); };

    const modal = host.querySelector('[data-modal]');
    if (modal) {
      modal.onclick = (e) => { if (e.target === modal) { newOpen = false; paint(); } };
      const nn = host.querySelector('[data-newname]');
      nn.oninput = () => { newName = nn.value; };
      nn.onkeydown = (e) => { if (e.key === 'Enter') startDraft(); };
      host.querySelector('[data-cancel]').onclick = () => { newOpen = false; paint(); };
      host.querySelector('[data-start]').onclick = startDraft;
    }
  }

  load();
}

// ── inlined History.svelte ────────────────────────────────────────────────────
function mountHistory(host, scope) {
  const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  let changes = [];
  let loading = true;
  let openId = null;
  let diff = null;
  let diffLoading = false;
  let undoing = false;
  let restoring = false;

  async function load() {
    loading = true;
    paint();
    changes = await WB.api.nexusHistory(scope);
    loading = false;
    paint();
  }

  async function toggle(c) {
    if (openId === c.id) { openId = null; diff = null; paint(); return; }
    openId = c.id; diff = null; diffLoading = true;
    paint();
    diff = await WB.api.changeDiff(scope, c.id);
    diffLoading = false;
    paint();
  }

  async function undo() {
    undoing = true;
    paint();
    const when = new Date().toISOString();
    const entry = await WB.api.undoLast(scope, when);
    undoing = false;
    if (!entry) { paint(); WB.toast('Nothing to undo'); return; }
    changes = [entry, ...changes];
    openId = null; diff = null;
    paint();
    WB.toast(entry.title);
  }

  async function restore(c) {
    const ok = await WB.confirm({
      title: 'Restore this version?',
      body: `“${c.title}” will become the current version. Nothing is deleted — this is added as a new change you can undo.`
    });
    if (!ok) return;
    restoring = true;
    paint();
    const when = new Date().toISOString();
    const entry = await WB.api.restoreVersion(scope, c.id, when);
    changes = [entry, ...changes];
    openId = null; diff = null;
    restoring = false;
    paint();
    WB.toast(entry.title);
  }

  function lineDiff(before, after) {
    const a = (before || '').split('\n');
    const b = (after || '').split('\n');
    const aset = new Set(a), bset = new Set(b);
    const rows = [];
    for (const ln of a) if (!bset.has(ln)) rows.push({ k: 'del', ln });
    for (const ln of b) rows.push({ k: aset.has(ln) ? 'same' : 'add', ln });
    return rows;
  }

  function who(c) {
    if (c.authorName === 'You') return 'You';
    return c.authorType === 'agent' ? `${c.authorName} · agent` : c.authorName;
  }
  function ago(iso) {
    const d = (Date.now() - new Date(iso)) / 1000;
    if (d < 60) return 'just now';
    if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago';
    if (d < 86400 * 7) return Math.floor(d / 86400) + 'd ago';
    return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  }
  const initials = (n) => n === 'You' ? 'Y' : n.split(/\s+/).map((p) => p[0]).slice(0, 2).join('').toUpperCase();

  function diffFor(c, i) {
    if (openId !== c.id) return '';
    let inner;
    if (diffLoading) {
      inner = `<div class="empty" style="border:0">Loading before → after…</div>`;
    } else if (diff) {
      const grid = `<div class="dgrid">${lineDiff(diff.before, diff.after).map((r) => `<div class="dl ${r.k}"><span class="sign">${r.k === 'add' ? '+' : r.k === 'del' ? '−' : ' '}</span>${esc(r.ln || ' ')}</div>`).join('')}</div>`;
      const foot = i !== 0
        ? `<div class="dfoot"><button class="btn sm" data-restore="${esc(c.id)}"${restoring ? ' disabled' : ''}>⟲ Restore this version</button></div>`
        : '';
      inner = grid + foot;
    } else {
      inner = '';
    }
    return `<div class="diff">${inner}</div>`;
  }

  function listHtml() {
    if (loading) return `<div class="empty">Loading…</div>`;
    if (changes.length === 0) return `<div class="empty">No changes yet. Edits will show up here.</div>`;
    return `<ol class="tl">${changes.map((c, i) => `
        <li class="${openId === c.id ? 'open' : ''}">
          <span class="rail"><span class="node ${esc(c.authorType)}${i === 0 ? ' head' : ''}"></span></span>
          <div class="body">
            <button class="row" data-toggle="${esc(c.id)}" aria-expanded="${openId === c.id}">
              <span class="av ${esc(c.authorType)}">${esc(initials(c.authorName))}</span>
              <span class="meta">
                <span class="title">${esc(c.title)}</span>
                <span class="sub"><b>${esc(who(c))}</b> · ${esc(ago(c.when))}</span>
              </span>
              <span class="caret${openId === c.id ? ' up' : ''}">›</span>
            </button>
            ${diffFor(c, i)}
          </div>
        </li>`).join('')}
    </ol>`;
  }

  function paint() {
    host.innerHTML = `
<div class="card" style="padding:0;overflow:hidden">
  <div class="hh">
    <div style="display:flex;flex-direction:column;gap:1px">
      <b style="font-size:13.5px">History <span class="dim mono" style="font-weight:400">· ${changes.length} change${changes.length === 1 ? '' : 's'}</span></b>
      <span class="faint" style="font-size:11.5px">Nothing is lost — undo or restore any version.</span>
    </div>
    <button class="btn sm" data-undo${(undoing || changes.length < 2) ? ' disabled' : ''} title="Undo the most recent change">
      ⟲ Undo last change
    </button>
  </div>
  ${listHtml()}
</div>`;

    host.querySelector('[data-undo]').onclick = undo;
    host.querySelectorAll('[data-toggle]').forEach((b) => {
      b.onclick = () => toggle(changes.find((c) => c.id === b.dataset.toggle));
    });
    host.querySelectorAll('[data-restore]').forEach((b) => {
      b.onclick = () => restore(changes.find((c) => c.id === b.dataset.restore));
    });
  }

  load();
}
