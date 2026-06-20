// routes/workspace/history/+page.svelte + +layout.svelte wrapper + History.svelte + Confirm.svelte inlined.
WB.scopedStyles('/workspace/history', `
  /* ── +layout.svelte ── */
  .wshead { display:flex; align-items:center; gap:12px; margin-bottom:14px; }
  .wsav {
    width:40px; height:40px; border-radius:11px; flex:none; display:grid; place-items:center;
    background:var(--line); color:var(--ink);
    font:700 16px var(--read);
  }
  .wshead h2 { font-family:var(--display); font-weight:600; font-size:24px; line-height:1.1; color:var(--ink); }
  .wshead p { font:400 13.5px var(--read); color:var(--prose); margin-top:3px; }

  .wstabs {
    display:flex; gap:2px; margin-bottom:16px;
    border-bottom:1px solid var(--line);
  }
  .wstabs a {
    padding:7px 13px; font:600 13px var(--read); color:var(--dim);
    text-decoration:none; border-bottom:2px solid transparent; margin-bottom:-1px;
    transition:color .1s;
  }
  .wstabs a:hover { color:var(--ink); }
  .wstabs a.on { color:var(--ink); border-bottom-color:var(--section); }

  /* ── History.svelte ── */
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
`);

WB.view('/workspace/history', {
  title: 'Workspace',
  accent: 'var(--peach)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const attrEsc = (s) => esc(s).replace(/"/g, '&quot;');

    // layout
    const wsa = WB.ws.active;
    const wsLayoutName = wsa?.name || 'Workspace';
    const wsIcon = wsa?.icon || (wsLayoutName[0] || 'W').toUpperCase();
    const here = '/workspace/history';
    const TABS = [
      { href: '/workspace', label: 'Structure' },
      { href: '/workspace/members', label: 'Members & access' },
      { href: '/workspace/sharing', label: 'Sharing' },
      { href: '/workspace/history', label: 'History' },
      { href: '/workspace/env', label: 'Secrets' }
    ];
    const isOn = (href) => href === '/workspace' ? here === '/workspace' : (here === href || here.startsWith(href + '/'));

    function shell(inner) {
      return `
<section>
  <div class="wshead">
    <span class="wsav">${esc(wsIcon)}</span>
    <div>
      <h2>${esc(wsLayoutName)}</h2>
    </div>
  </div>
  <nav class="wstabs">
    ${TABS.map((t) => `<a href="${t.href}"${isOn(t.href) ? ' class="on"' : ''} data-nav="${t.href}">${esc(t.label)}</a>`).join('')}
  </nav>
  ${inner}
</section>`;
    }

    // ── workspace/history/+page.svelte ──
    const ws = WB.ws.active;
    const scope = ws?.id || null;

    if (!scope) {
      el.innerHTML = shell(`<div class="card faint" style="text-align:center">No workspace selected.</div>`);
      el.querySelectorAll('[data-nav]').forEach((a) =>
        a.addEventListener('click', (e) => { e.preventDefault(); WB.nav(a.dataset.nav); }));
      return;
    }

    // ── History.svelte state ──
    let changes = [];
    let loading = true;
    let openId = null;
    let diff = null;
    let diffLoading = false;
    let confirmFor = null;
    let restoring = false;
    let undoing = false;

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

    function panelHtml() {
      let inner;
      if (loading) {
        inner = `<div class="empty">Loading…</div>`;
      } else if (changes.length === 0) {
        inner = `<div class="empty">No changes yet. Edits will show up here.</div>`;
      } else {
        inner = `<ol class="tl">${changes.map((c, i) => {
          const isOpen = openId === c.id;
          let diffBlock = '';
          if (isOpen) {
            let dinner;
            if (diffLoading) {
              dinner = `<div class="empty" style="border:0">Loading before → after…</div>`;
            } else if (diff) {
              const dgrid = `<div class="dgrid">${lineDiff(diff.before, diff.after).map((r) =>
                `<div class="dl ${r.k}"><span class="sign">${r.k === 'add' ? '+' : r.k === 'del' ? '−' : ' '}</span>${esc(r.ln || ' ')}</div>`
              ).join('')}</div>`;
              const restoreFoot = i !== 0
                ? `<div class="dfoot">
                      <button class="btn sm" data-restore="${attrEsc(c.id)}"${restoring ? ' disabled' : ''}>
                        ⟲ Restore this version
                      </button>
                    </div>`
                : '';
              dinner = dgrid + restoreFoot;
            } else {
              dinner = '';
            }
            diffBlock = `<div class="diff">${dinner}</div>`;
          }
          return `
        <li${isOpen ? ' class="open"' : ''}>
          <span class="rail"><span class="node ${c.authorType}${i === 0 ? ' head' : ''}"></span></span>
          <div class="body">
            <button class="row" data-toggle="${attrEsc(c.id)}" aria-expanded="${isOpen}">
              <span class="av ${c.authorType}">${esc(initials(c.authorName))}</span>
              <span class="meta">
                <span class="title">${esc(c.title)}</span>
                <span class="sub"><b>${esc(who(c))}</b> · ${esc(ago(c.when))}</span>
              </span>
              <span class="caret${isOpen ? ' up' : ''}">›</span>
            </button>
            ${diffBlock}
          </div>
        </li>`;
        }).join('')}</ol>`;
      }

      const card = `
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
  ${inner}
</div>`;

      // Confirm (restore)
      let confirm = '';
      if (confirmFor) {
        const body = `“${confirmFor.title}” will become the current version. Nothing is deleted — this is added as a new change you can undo.`;
        confirm = `
<div class="modal" data-confirm-backdrop>
  <div class="sheet" style="width:440px">
    <h2>Restore this version?</h2>
    <p class="sub">${esc(body)}</p>
    <div class="foot" style="justify-content:flex-end">
      <div style="display:flex;gap:8px">
        <button class="btn" data-confirm-cancel>Cancel</button>
        <button class="btn primary" data-confirm-ok>Restore</button>
      </div>
    </div>
  </div>
</div>`;
      }

      return card + confirm;
    }

    function paint() {
      el.innerHTML = shell(panelHtml());
      wire();
    }

    function wire() {
      el.querySelectorAll('[data-nav]').forEach((a) =>
        a.addEventListener('click', (e) => { e.preventDefault(); WB.nav(a.dataset.nav); }));

      el.querySelectorAll('[data-toggle]').forEach((b) =>
        b.addEventListener('click', () => toggle(changes.find((c) => c.id === b.dataset.toggle))));
      el.querySelectorAll('[data-restore]').forEach((b) =>
        b.addEventListener('click', () => { confirmFor = changes.find((c) => c.id === b.dataset.restore); paint(); }));
      const undoBtn = el.querySelector('[data-undo]');
      if (undoBtn) undoBtn.addEventListener('click', undo);

      const cb = el.querySelector('[data-confirm-backdrop]');
      if (cb) cb.addEventListener('click', (e) => { if (e.target === e.currentTarget) { confirmFor = null; paint(); } });
      const cc = el.querySelector('[data-confirm-cancel]');
      if (cc) cc.addEventListener('click', () => { confirmFor = null; paint(); });
      const ck = el.querySelector('[data-confirm-ok]');
      if (ck) ck.addEventListener('click', reallyRestore);
    }

    async function toggle(c) {
      if (openId === c.id) { openId = null; diff = null; paint(); return; }
      openId = c.id; diff = null; diffLoading = true; paint();
      diff = await WB.api.changeDiff(scope, c.id);
      diffLoading = false; paint();
    }

    async function undo() {
      undoing = true; paint();
      const when = new Date().toISOString();
      const entry = await WB.api.undoLast(scope, when);
      undoing = false;
      if (!entry) { WB.toast('Nothing to undo'); paint(); return; }
      changes = [entry, ...changes];
      openId = null; diff = null;
      WB.toast(entry.title);
      paint();
    }

    async function reallyRestore() {
      const c = confirmFor;
      confirmFor = null;
      restoring = true; paint();
      const when = new Date().toISOString();
      const entry = await WB.api.restoreVersion(scope, c.id, when);
      changes = [entry, ...changes];
      openId = null; diff = null;
      restoring = false;
      WB.toast(entry.title);
      paint();
    }

    async function load() {
      loading = true; paint();
      changes = await WB.api.nexusHistory(scope);
      loading = false; paint();
    }

    await load();
  }
});
