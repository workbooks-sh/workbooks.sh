WB.scopedStyles('/secrets', `
  .grphead { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; margin:0 0 14px; }
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
  .lk { background:none; border:none; cursor:pointer; padding:2px 4px; font:600 12px var(--read); color:var(--dim); }
  .lk:hover { color:var(--ink); }
  .lk.danger:hover { color:var(--bad, #c0392b); }
  .lk:disabled { opacity:.5; cursor:default; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
  /* Platform (injected) secrets — read-only name + set/not-set badge, grouped. */
  .pgrp { font:700 10.5px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); padding:14px 4px 6px; }
  .pgrp:first-child { padding-top:2px; }
  .prow { display:flex; align-items:center; gap:12px; padding:9px 4px; border-bottom:1px solid var(--line); }
  .prow:last-child { border-bottom:none; }
  .pname { font:600 13px var(--mono); color:var(--ink); }
  .plabel { flex:1; min-width:0; font:500 12.5px var(--read); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .pbadge { flex:none; font:700 10px var(--read); letter-spacing:.04em; text-transform:uppercase; border-radius:6px; padding:3px 8px; }
  .pbadge.on { color:var(--bloomd); background:color-mix(in srgb, var(--bloom) 16%, transparent); }
  .pbadge.off { color:var(--dim); background:var(--line); }
`);

WB.view('/secrets', {
  title: 'Secrets',
  accent: 'var(--mint)',
  async render(el, ctx) {
    // NEXUS-level secrets — global pool for this nexus. Scoped by reserved "nexus:<id>"
    // key so it never collides with a workspace's vars.
    const active = WB.nexus.active;
    const scope = active ? `nexus:${active.id}` : null;
    const nxName = (active && active.name) || 'this nexus';

    // ── transient state (mirrors envStore + the page's local runes) ──
    let list = [];
    let loading = true;
    const revealed = {};       // { [id]: plaintext }
    let revealBusy = null;
    const timers = {};

    let editOpen = false;
    let editing = null;
    let fName = '';
    let fValue = '';
    let saving = false;

    let deleteFor = null;
    let injected = null;       // platform/injected secrets (names + present) — null = loading
    let lockName = false;      // when setting a platform secret, lock the name field to the known key

    // (Re)load the platform/injected secrets (names + present status) into `injected`, then repaint.
    function loadInjected() {
      return fetch('/cloud/secrets/injected', { credentials: 'same-origin' })
        .then((r) => (r.ok ? r.json() : { secrets: [] }))
        .then((d) => { injected = (d && d.secrets) || []; paint(); })
        .catch(() => { injected = []; paint(); });
    }

    const esc = (s) => String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');

    async function loadList() {
      if (!scope) { list = []; loading = false; paint(); return; }
      loading = true;
      paint();
      // Stale-while-revalidate: show last-known env list (names/metadata only — never plaintext values)
      // instantly, refresh in the background. Same instant-load behavior as the other admin pages.
      await WB.swr('secrets:' + scope, () => WB.api.listEnv(scope), (fresh) => {
        list = fresh || [];
        loading = false;
        paint();
      });
    }

    // ── reveal / hide / copy ──
    async function reveal(id) {
      if (revealed[id] !== undefined) return hide(id);
      revealBusy = id;
      paint();
      try {
        const value = await WB.api.revealEnv(id);
        revealed[id] = value;
        clearTimeout(timers[id]);
        timers[id] = setTimeout(() => { hide(id); }, 30000);
      } catch { WB.toast('Could not reveal this value', 'bad'); }
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

    // ── create / edit ──
    function openCreate() { editing = null; fName = ''; fValue = ''; lockName = false; editOpen = true; paint(); }
    function openEdit(v) { editing = v; fName = v.name; fValue = ''; lockName = false; editOpen = true; paint(); }
    // Set a known PLATFORM secret — same write path as a normal secret, but the name is fixed to the
    // canonical key. (You can set/replace the value; you still can't read it back.)
    function openSet(name) { editing = null; fName = name; fValue = ''; lockName = true; editOpen = true; paint(); }
    async function save() {
      if (!fName.trim()) { WB.toast('Give the secret a name'); return; }
      saving = true;
      paint();
      try {
        if (editing) {
          const attrs = { name: fName.trim() };
          if (fValue) attrs.value = fValue;
          const v = await WB.api.updateEnv(editing.id, attrs);
          list = list.map((x) => (x.id === editing.id ? v : x));
          WB.toast(`Updated ${fName.trim()}`);
        } else {
          if (!fValue) { saving = false; WB.toast('Give the secret a value'); paint(); return; }
          const v = await WB.api.createEnv(scope, { name: fName.trim(), value: fValue });
          list = [...list, v];
          WB.toast(`Saved ${fName.trim()}`);
        }
        editOpen = false;
        // If we just set a platform key, refresh its Set/Not-set badge from the secrets seam.
        if (lockName) loadInjected();
      } catch { WB.toast('Could not save', 'bad'); }
      saving = false;
      lockName = false;
      paint();
    }

    // ── delete ──
    async function reallyDelete() {
      const v = deleteFor;
      deleteFor = null;
      hide(v.id);
      list = list.filter((x) => x.id !== v.id);
      paint();
      try { await WB.api.deleteEnv(v.id); } catch {}
      WB.toast(`Removed ${v.name}`, 'bad');
    }

    function rowsHtml() {
      return list.map((v) => {
        const r = revealed[v.id];
        const valCell = r !== undefined
          ? `<span class="mono plain">${esc(r)}</span>
                <button class="lk" data-act="copy" data-id="${esc(v.id)}">Copy</button>
                <button class="lk" data-act="hide" data-id="${esc(v.id)}">Hide</button>`
          : `<span class="mono masked">${esc(v.masked)}</span>
                <span class="faint" style="font-size:11px">${esc(v.length)} chars</span>
                <button class="lk" data-act="reveal" data-id="${esc(v.id)}"${revealBusy === v.id ? ' disabled' : ''}>${revealBusy === v.id ? 'Revealing…' : 'Reveal'}</button>`;
        return `<tr data-ctx="secret">
            <td class="mono nm">${esc(v.name)}</td>
            <td class="val">${valCell}</td>
            <td class="faint" style="font-size:12px;white-space:nowrap">${esc(v.created_at)}</td>
            <td class="acts">
              <button class="lk" data-act="edit" data-id="${esc(v.id)}">Edit</button>
              <button class="lk danger" data-act="del" data-id="${esc(v.id)}">Delete</button>
            </td>
          </tr>`;
      }).join('');
    }

    function bodyHtml() {
      if (loading) {
        return `<div class="card" style="color:var(--dim);text-align:center">Loading…</div>`;
      }
      if (list.length === 0) {
        return `<div class="card faint" style="text-align:center">
    No secrets yet. Add a shared key (an API token, a connection string) and every workspace on ${esc(nxName)} can use it.
  </div>`;
      }
      return `<div class="card" style="padding:0;overflow:hidden">
    <table class="env">
      <thead><tr><th>Name</th><th>Value</th><th>Created</th><th></th></tr></thead>
      <tbody>${rowsHtml()}</tbody>
    </table>
  </div>`;
    }

    // Read-only platform secrets — injected at deploy (Fly secrets → Nexus.Secrets). Names + a set/not-set
    // badge only; you can't reveal or edit them here (they're managed at deploy, not in the nexus pool).
    function platformHtml() {
      if (injected === null) {
        return `<div class="card faint" style="text-align:center;color:var(--dim)">Loading platform secrets…</div>`;
      }
      if (!injected.length) return '';
      const groups = {};
      injected.forEach((s) => { (groups[s.group] = groups[s.group] || []).push(s); });
      const sections = Object.keys(groups).map((g) => `
    <div class="pgrp">${esc(g)}</div>
    ${groups[g].map((s) => `
      <div class="prow">
        <span class="pname mono">${esc(s.name)}</span>
        <span class="plabel faint">${esc(s.label)}</span>
        <span class="pbadge ${s.present ? 'on' : 'off'}">${s.present ? 'Set' : 'Not set'}</span>
        <button class="lk" data-setname="${esc(s.name)}">${s.present ? 'Replace' : 'Set'}</button>
      </div>`).join('')}`).join('');
      return `<div class="card" style="margin-top:14px">${sections}</div>`;
    }

    function modalHtml() {
      if (!editOpen) return '';
      return `<div class="modal" data-modal>
    <div class="sheet" style="width:460px">
      <h2>${lockName ? 'Set ' + esc(fName) : editing ? 'Edit secret' : 'Add secret'}</h2>
      <p class="sub">${lockName ? 'A service key the platform reads at runtime. You can set or replace its value here; you can’t read it back.' : 'Encrypted at rest. Shown masked everywhere — reveal one explicitly when you need it.'}</p>
      <div class="lab">Name</div>
      <div class="field"><input type="text" class="mono" placeholder="OPENROUTER_API_KEY" data-f="name" value="${esc(fName)}"${lockName ? ' readonly' : ''} /></div>
      <div class="lab">Value</div>
      <div class="field">
        <input type="text" class="mono" placeholder="${editing ? 'leave blank to keep current value' : 'secret value'}" data-f="value" value="${esc(fValue)}" />
      </div>
      <div class="sheet-foot">
        <button class="btn" type="button" data-act="cancel">Cancel</button>
        <button class="btn primary" type="button" data-act="save"${saving ? ' disabled' : ''}>${saving ? 'Saving…' : editing ? 'Save' : 'Add secret'}</button>
      </div>
    </div>
  </div>`;
    }

    // Inlined <Confirm> component (danger). Renders only when deleteFor is set
    // (open={!!deleteFor}). Mirrors Confirm.svelte exactly.
    function confirmHtml() {
      if (!deleteFor) return '';
      const body = `“${deleteFor.name}” will be removed from ${nxName}. Anything relying on it will stop seeing it.`;
      return `<div class="modal" data-confirm>
    <div class="sheet" style="width:440px">
      <h2>Delete this secret?</h2>
      <p class="sub">${esc(body)}</p>
      <div class="foot" style="justify-content:flex-end">
        <div style="display:flex;gap:8px">
          <button class="btn" data-cact="cancel">Cancel</button>
          <button class="btn danger" data-cact="confirm">Delete</button>
        </div>
      </div>
    </div>
  </div>`;
    }

    function paint() {
      el.innerHTML = `
<div class="grphead">
  <div>
    <h3 class="grp">Your secrets</h3>
    <p class="faint" style="margin:4px 0 0;font-size:12.5px">Keys you add and control — shared across every workspace on ${esc(nxName)}, encrypted at rest. Add, edit, or reveal them anytime.</p>
  </div>
  <button class="btn sm primary" data-act="create">
    <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Add secret
  </button>
</div>
${bodyHtml()}

<div class="grphead" style="margin-top:26px">
  <div>
    <h3 class="grp">Service keys</h3>
    <p class="faint" style="margin:4px 0 0;font-size:12.5px">The keys this platform needs to run — inference, storage, integrations. Set when you deploy, so you can see what’s configured here but can’t read the values back.</p>
  </div>
</div>
${platformHtml()}
${modalHtml()}
${confirmHtml()}`;
      wire();
    }

    function wire() {
      el.querySelector('[data-act="create"]')?.addEventListener('click', openCreate);
      el.querySelectorAll('[data-setname]').forEach((b) => b.addEventListener('click', () => openSet(b.getAttribute('data-setname'))));

      el.querySelectorAll('[data-act]').forEach((btn) => {
        const act = btn.getAttribute('data-act');
        const id = btn.getAttribute('data-id');
        if (act === 'reveal') btn.addEventListener('click', () => reveal(id));
        else if (act === 'hide') btn.addEventListener('click', () => hide(id));
        else if (act === 'copy') btn.addEventListener('click', () => copy(id));
        else if (act === 'edit') btn.addEventListener('click', () => openEdit(list.find((x) => x.id === id)));
        else if (act === 'del') btn.addEventListener('click', () => { deleteFor = list.find((x) => x.id === id); paint(); });
        else if (act === 'cancel') btn.addEventListener('click', () => { editOpen = false; paint(); });
        else if (act === 'save') btn.addEventListener('click', save);
      });

      // modal backdrop close
      const modal = el.querySelector('[data-modal]');
      if (modal) {
        modal.addEventListener('click', (e) => { if (e.target === e.currentTarget) { editOpen = false; paint(); } });
        const nameI = el.querySelector('[data-f="name"]');
        const valI = el.querySelector('[data-f="value"]');
        if (nameI) nameI.addEventListener('input', (e) => { fName = e.target.value; });
        if (valI) valI.addEventListener('input', (e) => { fValue = e.target.value; });
      }

      // inlined <Confirm> modal — backdrop close (oncancel), cancel, confirm
      const conf = el.querySelector('[data-confirm]');
      if (conf) {
        conf.addEventListener('click', (e) => { if (e.target === e.currentTarget) { deleteFor = null; paint(); } });
        conf.querySelector('[data-cact="cancel"]')?.addEventListener('click', () => { deleteFor = null; paint(); });
        conf.querySelector('[data-cact="confirm"]')?.addEventListener('click', reallyDelete);
      }
    }

    // Load the injected/platform secrets (names + present status) once, in the background.
    loadInjected();

    paint();
    await loadList();
  }
});
