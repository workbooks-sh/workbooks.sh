WB.scopedStyles('/shared', `
  .grp { font-size:13px; color:var(--dim); text-transform:uppercase; letter-spacing:.04em; margin:0 0 10px; font-weight:700; }
  .cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:12px; }
  .fcard { display:flex; flex-direction:column; gap:14px; }
  .ftop { display:flex; align-items:center; gap:11px; }
  .fic { font-size:22px; flex:none; }
  .fmeta { flex:1; min-width:0; }
  .fname { font-weight:650; font-size:14.5px; }
  .ffoot { display:flex; justify-content:flex-end; border-top:1px solid var(--line); padding-top:11px; }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
`);

WB.view('/shared', {
  title: 'Sharing',
  accent: 'var(--cream)',
  async render(el, ctx) {
    const MODE_STYLE = {
      read: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
      draft: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)'
    };
    const modeLabel = (m) => (m === 'draft' ? 'Can edit (Draft)' : 'View only');
    const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

    let data = { shareable: [], shared_by: [], shared_with: [] };
    let loading = true;
    let shareOpen = false;
    let pickFolder = '';
    let recipient = '';
    let mode = 'read';
    let revokeFor = null;
    let busy = null;

    async function load() {
      loading = true;
      paint();
      data = await WB.api.sharedFolders();
      if (!pickFolder) pickFolder = data.shareable[0] || '';
      loading = false;
      paint();
    }

    function sharedWithCard(g) {
      const foot = g.added
        ? `<span class="dim" style="font-size:12.5px">✓ In your workspace</span>`
        : `<button class="btn sm primary" data-add="${esc(g.id)}"${busy === g.id ? ' disabled' : ''}>${busy === g.id ? 'Adding…' : 'Add to workspace'}</button>`;
      return `
          <div class="card fcard">
            <div class="ftop">
              <span class="fic">📁</span>
              <div class="fmeta">
                <div class="fname">${esc(g.folder)}</div>
                <div class="faint mono" style="font-size:11.5px">from ${esc(g.owner)}</div>
              </div>
              <span class="tag" style="${MODE_STYLE[g.mode]}">${modeLabel(g.mode)}</span>
            </div>
            <div class="ffoot">
              ${foot}
            </div>
          </div>`;
    }

    function sharedByCard(g) {
      return `
          <div class="card fcard">
            <div class="ftop">
              <span class="fic">📁</span>
              <div class="fmeta">
                <div class="fname">${esc(g.folder)}</div>
                <div class="faint mono" style="font-size:11.5px">with ${esc(g.recipient)}</div>
              </div>
              <span class="tag" style="${MODE_STYLE[g.mode]}">${modeLabel(g.mode)}</span>
            </div>
            <div class="ffoot">
              <button class="btn sm" data-revoke="${esc(g.id)}"${busy === g.id ? ' disabled' : ''}>Stop sharing</button>
            </div>
          </div>`;
    }

    function body() {
      if (loading) {
        return `<div class="card" style="color:var(--dim);text-align:center">Loading…</div>`;
      }
      const withYou = data.shared_with.length === 0
        ? `<div class="card faint" style="text-align:center">No one has shared a folder with you yet.</div>`
        : `<div class="cards">${data.shared_with.map(sharedWithCard).join('')}</div>`;
      const youSharing = data.shared_by.length === 0
        ? `<div class="card faint" style="text-align:center">You’re not sharing any folders. Share one to collaborate with a teammate.</div>`
        : `<div class="cards">${data.shared_by.map(sharedByCard).join('')}</div>`;
      return `
    <h3 class="grp">Shared with you</h3>
    ${withYou}

    <h3 class="grp" style="margin-top:26px">You’re sharing</h3>
    ${youSharing}`;
    }

    function modalHtml() {
      if (!shareOpen) return '';
      const regions = data.shareable.map((f) => `
          <div class="reg${pickFolder === f ? ' sel' : ''}" role="button" tabindex="0" data-folder="${esc(f)}">${esc(f)}</div>`).join('');
      return `
  <div class="modal" data-modal>
    <div class="sheet" style="width:460px">
      <h2>Share a folder</h2>
      <p class="sub">The teammate gets their own copy in their workspace. Their edits become Drafts — your folder is never changed by them.</p>

      <div class="lab">Folder</div>
      <div class="regions">${regions}
      </div>

      <div class="lab">Teammate</div>
      <div class="field"><input type="text" placeholder="name or email" data-recipient value="${esc(recipient)}" /></div>

      <div class="lab">They can</div>
      <div class="regions">
        <div class="reg${mode === 'read' ? ' sel' : ''}" role="button" tabindex="0" style="${mode === 'read' ? MODE_STYLE.read : ''}" data-mode="read">View only</div>
        <div class="reg${mode === 'draft' ? ' sel' : ''}" role="button" tabindex="0" style="${mode === 'draft' ? MODE_STYLE.draft : ''}" data-mode="draft">Edit as Draft</div>
      </div>

      <div class="sheet-foot">
        <button class="btn" type="button" data-cancel>Cancel</button>
        <button class="btn primary" type="button" data-do-share>Share folder</button>
      </div>
    </div>
  </div>`;
    }

    function paint() {
      el.innerHTML = `
<section>
  <div class="sechead">
    <div>
      <h2>Shared folders</h2>
      <p>Share a folder with a teammate, or add a folder they’ve shared into your own workspace. Edits you make to a shared folder are saved as a Draft — nothing is ever overwritten.</p>
    </div>
    <button class="btn primary" data-open-share${!data.shareable.length ? ' disabled' : ''}>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Share a folder
    </button>
  </div>
  ${body()}
</section>
${modalHtml()}`;
      wire();
    }

    function wire() {
      const openBtn = el.querySelector('[data-open-share]');
      if (openBtn) openBtn.onclick = () => { shareOpen = true; paint(); };

      el.querySelectorAll('[data-add]').forEach((b) => {
        b.onclick = () => add(data.shared_with.find((s) => s.id === b.dataset.add));
      });
      el.querySelectorAll('[data-revoke]').forEach((b) => {
        b.onclick = () => { revokeFor = data.shared_by.find((s) => s.id === b.dataset.revoke); doRevokeConfirm(); };
      });

      const modal = el.querySelector('[data-modal]');
      if (modal) {
        modal.onclick = (e) => { if (e.target === modal) { shareOpen = false; paint(); } };
        el.querySelectorAll('[data-folder]').forEach((d) => {
          d.onclick = () => { pickFolder = d.dataset.folder; paint(); };
          d.onkeydown = (e) => { if (e.key === 'Enter') { pickFolder = d.dataset.folder; paint(); } };
        });
        el.querySelectorAll('[data-mode]').forEach((d) => {
          d.onclick = () => { mode = d.dataset.mode; paint(); };
        });
        const rec = el.querySelector('[data-recipient]');
        if (rec) rec.oninput = () => { recipient = rec.value; };
        el.querySelector('[data-cancel]').onclick = () => { shareOpen = false; paint(); };
        el.querySelector('[data-do-share]').onclick = doShare;
      }
    }

    async function doShare() {
      if (!pickFolder || !recipient.trim()) { WB.toast('Pick a folder and a teammate'); return; }
      const g = await WB.api.shareFolder({ folder: pickFolder, recipient: recipient.trim(), mode });
      data.shared_by = [g, ...data.shared_by];
      shareOpen = false; recipient = '';
      paint();
      WB.toast(`Shared “${g.folder}” with ${g.recipient}`);
    }

    async function add(g) {
      busy = g.id;
      paint();
      const r = await WB.api.addSharedFolder(g.id);
      busy = null;
      data.shared_with = data.shared_with.map((s) => (s.id === g.id ? { ...s, added: true } : s));
      paint();
      WB.toast(`Added “${r.folder}” to your workspace · ${r.files.length} files`);
    }

    async function doRevokeConfirm() {
      const g = revokeFor;
      const ok = await WB.confirm({
        title: 'Stop sharing this folder?',
        body: `${g.recipient} will lose access to “${g.folder}”. A copy they already added stays in their workspace as their own.`,
        danger: true,
        confirm: 'Stop sharing'
      });
      revokeFor = null;
      if (!ok) return;
      busy = g.id;
      paint();
      await WB.api.revokeShare(g.id);
      busy = null;
      data.shared_by = data.shared_by.filter((s) => s.id !== g.id);
      paint();
      WB.toast(`Stopped sharing “${g.folder}”`, 'bad');
    }

    load();
  }
});
