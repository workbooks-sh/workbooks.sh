// routes/workspace/sharing/+page.svelte + +layout.svelte wrapper + Confirm.svelte inlined.
WB.scopedStyles('/workspace/sharing', `
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

  /* ── sharing/+page.svelte ── */
  .grphead { display:flex; align-items:center; justify-content:space-between; margin:0 0 10px; }
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0; font-weight:700; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:12px; }
  .fcard { display:flex; flex-direction:column; gap:14px; }
  .ftop { display:flex; align-items:center; gap:11px; }
  .fic { font-size:22px; flex:none; }
  .fmeta { flex:1; min-width:0; }
  .fname { font-weight:650; font-size:14.5px; }
  .ffoot { display:flex; justify-content:flex-end; border-top:1px solid var(--line); padding-top:11px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
  .seg { display:flex; border:2px solid var(--stroke); border-radius:9px; overflow:hidden; flex:none; }
  .seg button { padding:6px 16px; font:600 11px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--dim); background:var(--card); cursor:pointer; border:none; }
  .seg button.on { background:var(--ink); color:var(--paper); }
`);

WB.view('/workspace/sharing', {
  title: 'Workspace',
  accent: 'var(--peach)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const attrEsc = (s) => esc(s).replace(/"/g, '&quot;');

    // layout
    const wsa = WB.ws.active;
    const wsLayoutName = wsa?.name || 'Workspace';
    const wsIcon = wsa?.icon || (wsLayoutName[0] || 'W').toUpperCase();
    const here = '/workspace/sharing';
    const TABS = [
      { href: '/workspace', label: 'Structure' },
      { href: '/workspace/members', label: 'Members & access' },
      { href: '/workspace/sharing', label: 'Sharing' },
      { href: '/workspace/history', label: 'History' },
      { href: '/workspace/env', label: 'Secrets' }
    ];
    const isOn = (href) => href === '/workspace' ? here === '/workspace' : (here === href || here.startsWith(href + '/'));

    const wsName = WB.ws.active?.name || 'this workspace';

    // page state
    let data = { shareable: [], shared_by: [], shared_with: [] };
    let loading = true;
    let visibility = 'private';
    let shareOpen = false;
    let pickFolder = '';
    let recipient = '';
    let mode = 'read';
    let revokeFor = null;
    let busy = null;

    const MODE_STYLE = {
      read: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
      draft: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)'
    };
    const modeLabel = (m) => (m === 'draft' ? 'Can edit (Draft)' : 'View only');

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

    function visCard() {
      return `
<div class="card" style="display:flex;align-items:center;gap:16px">
  <div style="flex:1">
    <b style="font-size:13.5px">Visibility</b>
    <div class="faint" style="font-size:11.5px">
      ${visibility === 'public'
        ? `${esc(wsName)} is public — anyone with the link can view.`
        : `${esc(wsName)} is private — only members and named guests have access.`}
    </div>
  </div>
  <div class="seg vis">
    <button${visibility === 'private' ? ' class="on"' : ''} data-vis="private">Private</button>
    <button${visibility === 'public' ? ' class="on"' : ''} data-vis="public">Public</button>
  </div>
</div>`;
    }

    function fcard(g, kind) {
      // kind: 'with' (shared_with) | 'by' (shared_by)
      const fromLine = kind === 'with' ? `from ${esc(g.owner)}` : `with ${esc(g.recipient)}`;
      let foot;
      if (kind === 'with') {
        foot = g.added
          ? `<span class="dim" style="font-size:12.5px">✓ In ${esc(wsName)}</span>`
          : `<button class="btn sm primary" data-add="${attrEsc(g.id)}"${busy === g.id ? ' disabled' : ''}>${busy === g.id ? 'Adding…' : 'Add to workspace'}</button>`;
      } else {
        foot = `<button class="btn sm" data-revoke="${attrEsc(g.id)}"${busy === g.id ? ' disabled' : ''}>Remove access</button>`;
      }
      return `
<div class="card fcard">
  <div class="ftop">
    <span class="fic">📁</span>
    <div class="fmeta">
      <div class="fname">${esc(g.folder)}</div>
      <div class="faint mono" style="font-size:11.5px">${fromLine}</div>
    </div>
    <span class="tag" style="${MODE_STYLE[g.mode] || ''}">${esc(modeLabel(g.mode))}</span>
  </div>
  <div class="ffoot">${foot}</div>
</div>`;
    }

    function bodyHtml() {
      let html = visCard();

      if (loading) {
        html += `<div class="card" style="color:var(--dim);text-align:center">Loading…</div>`;
      } else {
        // shared WITH
        html += `
<div class="grphead">
  <h3 class="grp">Shared with ${esc(wsName)}</h3>
</div>`;
        html += data.shared_with.length === 0
          ? `<div class="card faint" style="text-align:center">No one has shared a folder with this workspace yet.</div>`
          : `<div class="cards">${data.shared_with.map((g) => fcard(g, 'with')).join('')}</div>`;

        // guests (shared OUT)
        html += `
<div class="grphead" style="margin-top:26px">
  <h3 class="grp">Guests</h3>
  <button class="btn sm primary" data-share-open${!data.shareable.length ? ' disabled' : ''}>
    <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Invite a guest
  </button>
</div>`;
        html += data.shared_by.length === 0
          ? `<div class="card faint" style="text-align:center">No guests yet. Share a folder to collaborate with someone outside this workspace.</div>`
          : `<div class="cards">${data.shared_by.map((g) => fcard(g, 'by')).join('')}</div>`;
      }

      // share modal
      if (shareOpen) {
        html += `
<div class="modal" data-share-backdrop>
  <div class="sheet" style="width:460px">
    <h2>Invite a guest</h2>
    <p class="sub">The guest gets their own copy. Their edits become Drafts — your folder is never changed by them.</p>
    <div class="lab">Folder</div>
    <div class="regions">
      ${data.shareable.map((f) => `<div class="reg${pickFolder === f ? ' sel' : ''}" role="button" tabindex="0" data-pickfolder="${attrEsc(f)}">${esc(f)}</div>`).join('')}
    </div>
    <div class="lab">Guest</div>
    <div class="field"><input type="text" placeholder="name or email" data-recipient value="${attrEsc(recipient)}" /></div>
    <div class="lab">They can</div>
    <div class="regions">
      <div class="reg${mode === 'read' ? ' sel' : ''}" role="button" tabindex="0" style="${mode === 'read' ? MODE_STYLE.read : ''}" data-mode="read">View only</div>
      <div class="reg${mode === 'draft' ? ' sel' : ''}" role="button" tabindex="0" style="${mode === 'draft' ? MODE_STYLE.draft : ''}" data-mode="draft">Edit as Draft</div>
    </div>
    <div class="sheet-foot">
      <button class="btn" type="button" data-share-cancel>Cancel</button>
      <button class="btn primary" type="button" data-do-share>Share folder</button>
    </div>
  </div>
</div>`;
      }

      // Confirm (revoke)
      if (revokeFor) {
        const body = `${revokeFor.recipient} will lose access to “${revokeFor.folder}”. A copy they already added stays in their own workspace.`;
        html += `
<div class="modal" data-confirm-backdrop>
  <div class="sheet" style="width:440px">
    <h2>Remove this guest's access?</h2>
    <p class="sub">${esc(body)}</p>
    <div class="foot" style="justify-content:flex-end">
      <div style="display:flex;gap:8px">
        <button class="btn" data-confirm-cancel>Cancel</button>
        <button class="btn danger" data-confirm-ok>Remove access</button>
      </div>
    </div>
  </div>
</div>`;
      }

      return html;
    }

    function paint() {
      el.innerHTML = shell(bodyHtml());
      wire();
    }

    function wire() {
      el.querySelectorAll('[data-nav]').forEach((a) =>
        a.addEventListener('click', (e) => { e.preventDefault(); WB.nav(a.dataset.nav); }));

      el.querySelectorAll('[data-vis]').forEach((b) => b.addEventListener('click', () => {
        visibility = b.dataset.vis;
        WB.toast(visibility === 'public' ? 'Workspace is public' : 'Workspace is private');
        paint();
      }));

      el.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', () => add(b.dataset.add)));
      el.querySelectorAll('[data-revoke]').forEach((b) => b.addEventListener('click', () => { revokeFor = data.shared_by.find((s) => s.id === b.dataset.revoke); paint(); }));

      const so = el.querySelector('[data-share-open]');
      if (so) so.addEventListener('click', () => { shareOpen = true; paint(); });

      // share modal
      const sb = el.querySelector('[data-share-backdrop]');
      if (sb) sb.addEventListener('click', (e) => { if (e.target === e.currentTarget) { shareOpen = false; paint(); } });
      el.querySelectorAll('[data-pickfolder]').forEach((d) => {
        d.addEventListener('click', () => { pickFolder = d.dataset.pickfolder; paint(); });
        d.addEventListener('keydown', (e) => { if (e.key === 'Enter') { pickFolder = d.dataset.pickfolder; paint(); } });
      });
      const rin = el.querySelector('[data-recipient]');
      if (rin) rin.addEventListener('input', () => { recipient = rin.value; });
      el.querySelectorAll('[data-mode]').forEach((d) => {
        d.addEventListener('click', () => { mode = d.dataset.mode; paint(); });
      });
      const sc = el.querySelector('[data-share-cancel]');
      if (sc) sc.addEventListener('click', () => { shareOpen = false; paint(); });
      const ds = el.querySelector('[data-do-share]');
      if (ds) ds.addEventListener('click', doShare);

      // confirm
      const cb = el.querySelector('[data-confirm-backdrop]');
      if (cb) cb.addEventListener('click', (e) => { if (e.target === e.currentTarget) { revokeFor = null; paint(); } });
      const cc = el.querySelector('[data-confirm-cancel]');
      if (cc) cc.addEventListener('click', () => { revokeFor = null; paint(); });
      const ck = el.querySelector('[data-confirm-ok]');
      if (ck) ck.addEventListener('click', reallyRevoke);
    }

    async function doShare() {
      if (!pickFolder || !recipient.trim()) { WB.toast('Pick a folder and a guest'); return; }
      const g = await WB.api.shareFolder({ folder: pickFolder, recipient: recipient.trim(), mode });
      data.shared_by = [g, ...data.shared_by];
      shareOpen = false; recipient = '';
      WB.toast(`Shared “${g.folder}” with ${g.recipient}`);
      paint();
    }

    async function add(id) {
      const g = data.shared_with.find((s) => s.id === id);
      busy = id; paint();
      const r = await WB.api.addSharedFolder(id);
      busy = null;
      data.shared_with = data.shared_with.map((s) => (s.id === id ? { ...s, added: true } : s));
      WB.toast(`Added “${r.folder}” to ${wsName} · ${r.files.length} files`);
      paint();
    }

    async function reallyRevoke() {
      const g = revokeFor;
      revokeFor = null;
      busy = g.id; paint();
      await WB.api.revokeShare(g.id);
      busy = null;
      data.shared_by = data.shared_by.filter((s) => s.id !== g.id);
      WB.toast(`Stopped sharing “${g.folder}”`, 'bad');
      paint();
    }

    async function load() {
      loading = true; paint();
      data = await WB.api.sharedFolders();
      if (!pickFolder) pickFolder = data.shareable[0] || '';
      loading = false;
      paint();
    }

    await load();
  }
});
