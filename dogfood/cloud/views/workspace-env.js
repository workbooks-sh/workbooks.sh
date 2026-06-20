// routes/workspace/env/+page.svelte (Secrets) + +layout.svelte wrapper + Confirm.svelte inlined.
WB.scopedStyles('/workspace/env', `
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

  /* ── env/+page.svelte ── */
  .grphead { display:flex; align-items:center; justify-content:space-between; margin:0 0 10px; }
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0; font-weight:700; }
  table.env { width:100%; border-collapse:collapse; font:400 13.5px var(--read); }
  table.env th {
    text-align:left; padding:10px 14px; font:700 11px var(--mono); letter-spacing:.05em;
    text-transform:uppercase; color:var(--dim); border-bottom:1px solid var(--line); background:var(--card);
  }
  table.env td { padding:11px 14px; border-bottom:1px solid var(--line); vertical-align:middle; }
  table.env tr:last-child td { border-bottom:none; }
  .nm { font-weight:600; color:var(--ink); }
  .val { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .masked { letter-spacing:.1em; color:var(--dim); }
  .plain { color:var(--ink); word-break:break-all; }
  .acts { text-align:right; white-space:nowrap; }
  .lk {
    background:none; border:none; cursor:pointer; padding:2px 4px;
    font:600 12px var(--read); color:var(--dim);
  }
  .lk:hover { color:var(--ink); }
  .lk.danger:hover { color:var(--bad, #c0392b); }
  .lk:disabled { opacity:.5; cursor:default; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
`);

WB.view('/workspace/env', {
  title: 'Workspace',
  accent: 'var(--peach)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const attrEsc = (s) => esc(s).replace(/"/g, '&quot;');

    // ── layout shell ──
    const ws = WB.ws.active;
    const wsLayoutName = ws?.name || 'Workspace';
    const wsIcon = ws?.icon || (wsLayoutName[0] || 'W').toUpperCase();
    const here = '/workspace/env';
    const TABS = [
      { href: '/workspace', label: 'Structure' },
      { href: '/workspace/members', label: 'Members & access' },
      { href: '/workspace/sharing', label: 'Sharing' },
      { href: '/workspace/history', label: 'History' },
      { href: '/workspace/env', label: 'Secrets' }
    ];
    const isOn = (href) => href === '/workspace' ? here === '/workspace' : (here === href || here.startsWith(href + '/'));

    // ── env page state ──
    const wsName = WB.ws.active?.name || 'this workspace';
    const wsId = WB.ws.active?.id;

    let list = [];
    let loading = true;
    const revealed = {};       // { [id]: string }
    let revealBusy = null;
    const timers = {};
    const byId = (id) => list.find((x) => x.id === id);

    // modal state
    let editOpen = false;
    let editing = null;
    let fName = '';
    let fValue = '';
    let saving = false;
    let deleteFor = null;

    async function loadEnv() {
      loading = true;
      paint();
      list = wsId ? await WB.api.listEnv(wsId) : [];
      loading = false;
      paint();
    }

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

    function tableRows() {
      return list.map((v) => {
        const valCell = revealed[v.id] !== undefined
          ? `<span class="mono plain">${esc(revealed[v.id])}</span>
                <button class="lk" data-copy="${attrEsc(v.id)}">Copy</button>
                <button class="lk" data-hide="${attrEsc(v.id)}">Hide</button>`
          : `<span class="mono masked">${esc(v.masked)}</span>
                <span class="faint" style="font-size:11px">${esc(v.length)} chars</span>
                <button class="lk" data-reveal="${attrEsc(v.id)}"${revealBusy === v.id ? ' disabled' : ''}>${revealBusy === v.id ? 'Revealing…' : 'Reveal'}</button>`;
        return `
          <tr>
            <td class="mono nm">${esc(v.name)}</td>
            <td class="val">${valCell}</td>
            <td class="faint" style="font-size:12px;white-space:nowrap">${esc(v.created_at)}</td>
            <td class="acts">
              <button class="lk" data-edit="${attrEsc(v.id)}">Edit</button>
              <button class="lk danger" data-del="${attrEsc(v.id)}">Delete</button>
            </td>
          </tr>`;
      }).join('');
    }

    function bodyHtml() {
      let head = `
<div class="grphead">
  <h3 class="grp">Env vars · ${esc(wsName)}</h3>
  <button class="btn sm primary" data-create>
    <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Add variable
  </button>
</div>`;

      let main;
      if (loading) {
        main = `<div class="card" style="color:var(--dim);text-align:center">Loading…</div>`;
      } else if (list.length === 0) {
        main = `<div class="card faint" style="text-align:center">
    No variables yet. Secrets you add here are encrypted and available to ${esc(wsName)}.
  </div>`;
      } else {
        main = `<div class="card" style="padding:0;overflow:hidden">
    <table class="env">
      <thead>
        <tr><th>Name</th><th>Value</th><th>Created</th><th></th></tr>
      </thead>
      <tbody>${tableRows()}</tbody>
    </table>
  </div>`;
      }

      let modal = '';
      if (editOpen) {
        modal = `
<div class="modal" data-modal-backdrop>
  <div class="sheet" style="width:460px">
    <h2>${editing ? 'Edit variable' : 'Add variable'}</h2>
    <p class="sub">Secrets are encrypted at rest. The value is shown masked everywhere — reveal one explicitly when you need it.</p>
    <div class="lab">Name</div>
    <div class="field"><input type="text" class="mono" placeholder="DATABASE_URL" data-fname value="${attrEsc(fName)}" /></div>
    <div class="lab">Value</div>
    <div class="field">
      <input type="text" class="mono" placeholder="${editing ? 'leave blank to keep current value' : 'secret value'}" data-fvalue value="${attrEsc(fValue)}" />
    </div>
    <div class="sheet-foot">
      <button class="btn" type="button" data-cancel>Cancel</button>
      <button class="btn primary" type="button" data-save${saving ? ' disabled' : ''}>${saving ? 'Saving…' : editing ? 'Save' : 'Add variable'}</button>
    </div>
  </div>
</div>`;
      }

      // Confirm.svelte (delete)
      let confirm = '';
      if (deleteFor) {
        const body = `“${deleteFor.name}” will be removed from ${wsName}. Anything relying on it will stop seeing it.`;
        confirm = `
<div class="modal" data-confirm-backdrop>
  <div class="sheet" style="width:440px">
    <h2>Delete this variable?</h2>
    <p class="sub">${esc(body)}</p>
    <div class="foot" style="justify-content:flex-end">
      <div style="display:flex;gap:8px">
        <button class="btn" data-confirm-cancel>Cancel</button>
        <button class="btn danger" data-confirm-ok>Delete</button>
      </div>
    </div>
  </div>
</div>`;
      }

      return head + main + modal + confirm;
    }

    function paint() {
      el.innerHTML = shell(bodyHtml());
      wire();
    }

    function wire() {
      el.querySelectorAll('[data-nav]').forEach((a) =>
        a.addEventListener('click', (e) => { e.preventDefault(); WB.nav(a.dataset.nav); }));

      el.querySelectorAll('[data-reveal]').forEach((b) => b.addEventListener('click', () => reveal(b.dataset.reveal)));
      el.querySelectorAll('[data-hide]').forEach((b) => b.addEventListener('click', () => hide(b.dataset.hide)));
      el.querySelectorAll('[data-copy]').forEach((b) => b.addEventListener('click', () => copy(b.dataset.copy)));
      el.querySelectorAll('[data-edit]').forEach((b) => b.addEventListener('click', () => openEdit(byId(b.dataset.edit))));
      el.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', () => { deleteFor = byId(b.dataset.del); paint(); }));
      const createBtn = el.querySelector('[data-create]');
      if (createBtn) createBtn.addEventListener('click', openCreate);

      // modal
      const fn = el.querySelector('[data-fname]');
      const fv = el.querySelector('[data-fvalue]');
      if (fn) fn.addEventListener('input', () => { fName = fn.value; });
      if (fv) fv.addEventListener('input', () => { fValue = fv.value; });
      const cancel = el.querySelector('[data-cancel]');
      if (cancel) cancel.addEventListener('click', () => { editOpen = false; paint(); });
      const saveB = el.querySelector('[data-save]');
      if (saveB) saveB.addEventListener('click', save);
      const mb = el.querySelector('[data-modal-backdrop]');
      if (mb) mb.addEventListener('click', (e) => { if (e.target === e.currentTarget) { editOpen = false; paint(); } });

      // confirm
      const cb = el.querySelector('[data-confirm-backdrop]');
      if (cb) cb.addEventListener('click', (e) => { if (e.target === e.currentTarget) { deleteFor = null; paint(); } });
      const cc = el.querySelector('[data-confirm-cancel]');
      if (cc) cc.addEventListener('click', () => { deleteFor = null; paint(); });
      const ck = el.querySelector('[data-confirm-ok]');
      if (ck) ck.addEventListener('click', reallyDelete);
    }

    async function reveal(id) {
      if (revealed[id] !== undefined) return hide(id);
      revealBusy = id;
      paint();
      try {
        const value = await WB.api.revealEnv(id);
        revealed[id] = value;
        clearTimeout(timers[id]);
        timers[id] = setTimeout(() => hide(id), 30000);
      } catch {
        WB.toast('Could not reveal this value', 'bad');
      }
      revealBusy = null;
      paint();
    }
    function hide(id) {
      clearTimeout(timers[id]);
      delete revealed[id];
      paint();
    }
    async function copy(id) {
      const v = revealed[id];
      if (v === undefined) return;
      try { await navigator.clipboard.writeText(v); WB.toast('Copied to clipboard'); }
      catch { WB.toast('Could not copy', 'bad'); }
    }

    function openCreate() { editing = null; fName = ''; fValue = ''; editOpen = true; paint(); }
    function openEdit(v) { editing = v; fName = v.name; fValue = ''; editOpen = true; paint(); }

    async function save() {
      if (!fName.trim()) { WB.toast('Give the variable a name'); return; }
      saving = true; paint();
      try {
        if (editing) {
          const attrs = { name: fName.trim() };
          if (fValue) attrs.value = fValue;
          const v = await WB.api.updateEnv(editing.id, attrs);
          list = list.map((x) => (x.id === editing.id ? v : x));
          WB.toast(`Updated ${fName.trim()}`);
        } else {
          if (!fValue) { saving = false; WB.toast('Give the variable a value'); paint(); return; }
          const v = await WB.api.createEnv(wsId, { name: fName.trim(), value: fValue });
          list = [...list, v];
          WB.toast(`Added ${fName.trim()}`);
        }
        editOpen = false;
      } catch {
        WB.toast('Could not save', 'bad');
      }
      saving = false;
      paint();
    }

    async function reallyDelete() {
      const v = deleteFor;
      deleteFor = null;
      hide(v.id);
      list = list.filter((x) => x.id !== v.id);
      paint();
      try { await WB.api.deleteEnv(v.id); } catch {}
      WB.toast(`Removed ${v.name}`, 'bad');
    }

    await loadEnv();
  }
});
