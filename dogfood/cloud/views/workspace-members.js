// routes/workspace/members/+page.svelte + +page.server.js loader + +layout.svelte wrapper.
//
// Org memberships come from our own control plane (Nexus.Auth.Accounts org roster). There is not yet a
// WB.api.* client surface for it, so this view renders honest-empty {members:[], pending:[]} (the empty
// state) until that endpoint is wired; the invite/remove/revoke forms are faithful UI + toasts.
WB.scopedStyles('/workspace/members', `
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

  /* ── members/+page.svelte ── */
  .lh { display:flex; align-items:center; justify-content:space-between; gap:12px;
    padding:14px 18px; border-bottom:2px solid var(--line); }
  .empty { padding:32px 18px; text-align:center; color:var(--dim); font-size:13px; }
  .mav { width:30px; height:30px; border-radius:50%; display:grid; place-items:center; flex:none;
    font:700 11px var(--mono); color:var(--on-bloom); border:2px solid var(--stroke); }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
`);

WB.view('/workspace/members', {
  title: 'Workspace',
  accent: 'var(--peach)',
  async render(el, ctx) {
    const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const attrEsc = (s) => esc(s).replace(/"/g, '&quot;');

    // layout
    const wsa = WB.ws.active;
    const wsLayoutName = wsa?.name || 'Workspace';
    const wsIcon = wsa?.icon || (wsLayoutName[0] || 'W').toUpperCase();
    const here = '/workspace/members';
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

    const wsName = WB.ws.active?.name || 'this workspace';

    // ── loader (honest-empty until the org-roster endpoint is wired) ──
    const data = { members: [], pending: [] };

    // page state
    let inviteOpen = false;
    let inviteEmail = '';
    let inviteRole = 'member';

    // ── Git remote (the nexus AS a git remote) ──
    // The workspace's bare repo is pushable at <origin>/git/<id>.git; an optional GitHub mirror is
    // pushed after each push. The id is the repo name (provisioned on workspace create).
    const wsId = wsa?.id || '';
    let git = null;          // { remote, push, mirror } from /cloud/workspace/git
    let mirrorInput = '';
    async function loadGit() {
      if (!wsId) return;
      try {
        const r = await fetch('/cloud/workspace/git?ws=' + encodeURIComponent(wsId), { credentials: 'same-origin' });
        if (!r.ok) return;
        git = await r.json();
        // Relative remote (no request host server-side) → prepend the browser origin.
        if (git.remote && git.remote[0] === '/') git.remote = location.origin + git.remote;
        if (git.push) git.push = 'git push ' + git.remote + ' main';
        mirrorInput = git.mirror || '';
      } catch (e) { /* leave git null → section shows nothing */ }
    }

    const ROLE_STYLE = {
      owner: 'background:var(--cream);color:var(--on-bloom);border-color:var(--cream)',
      admin: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)',
      member: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
      viewer: 'background:var(--panel-2);color:var(--dim);border-color:var(--line)'
    };
    const roleStyle = (role) => ROLE_STYLE[role] || '';

    const PAIRS = [['--mint', '--sky'], ['--peach', '--blue'], ['--sage', '--mint'], ['--cream', '--peach'], ['--blue', '--sage']];
    function initials(name) { return name.split(/\s+/).map((p) => p[0]).slice(0, 2).join('').toUpperCase(); }
    function pair(name) { let h = 0; for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0; return PAIRS[h % PAIRS.length]; }
    function ago(iso) {
      if (!iso) return '—';
      const d = (Date.now() - new Date(iso)) / 1000;
      if (d < 60) return 'just now';
      if (d < 3600) return Math.floor(d / 60) + 'm ago';
      if (d < 86400) return Math.floor(d / 3600) + 'h ago';
      return Math.floor(d / 86400) + 'd ago';
    }

    function bodyHtml() {
      const total = data.members.length + data.pending.length;

      let listInner;
      if (total === 0) {
        listInner = `<div class="empty">No one's in this workspace yet. Add a member to get started.</div>`;
      } else {
        const memberRows = data.members.map((m) => {
          const p = pair(m.name);
          return `
          <tr>
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:linear-gradient(135deg,var(${p[0]}),var(${p[1]}))">${esc(initials(m.name))}</span>
                <div><div style="font-weight:600">${esc(m.name)}</div><div class="faint mono" style="font-size:11px">${esc(m.email)}</div></div>
              </div>
            </td>
            <td><span class="tag" style="${roleStyle(m.role)}">${esc(m.role)}</span></td>
            <td class="dim">${esc(ago(m.lastActive))}</td>
            <td class="num">
              <form data-remove="${attrEsc(m.id)}">
                <input type="hidden" name="id" value="${attrEsc(m.id)}" />
                <button class="btn sm" type="submit">Remove</button>
              </form>
            </td>
          </tr>`;
        }).join('');

        const pendingRows = data.pending.map((p) => `
          <tr style="opacity:.7">
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:var(--panel-2);color:var(--dim)">${esc((p.email[0] || '?').toUpperCase())}</span>
                <div><div style="font-weight:600">${esc(p.email)}</div><div class="faint mono" style="font-size:11px">invited</div></div>
              </div>
            </td>
            <td><span class="tag" style="${roleStyle('member')}">member</span></td>
            <td><span class="mono" style="color:var(--amber);font-size:12px">● pending</span></td>
            <td class="num">
              <form data-revoke="${attrEsc(p.id)}">
                <input type="hidden" name="id" value="${attrEsc(p.id)}" />
                <button class="btn sm" type="submit">Revoke</button>
              </form>
            </td>
          </tr>`).join('');

        listInner = `
    <table>
      <thead><tr><th>Member</th><th>Role</th><th>Last active</th><th></th></tr></thead>
      <tbody>${memberRows}${pendingRows}</tbody>
    </table>`;
      }

      let html = `
<div class="card" style="padding:0;overflow:hidden">
  <div class="lh">
    <div style="display:flex;flex-direction:column;gap:1px">
      <b style="font-size:13.5px">In ${esc(wsName)} <span class="dim mono" style="font-weight:400">· ${data.members.length}</span></b>
      <span class="faint" style="font-size:11.5px">People provisioned into this workspace. Drawn from your nexus members.</span>
    </div>
    <button class="btn sm primary" data-invite-open>
      <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Add member
    </button>
  </div>
  ${listInner}
</div>

<p class="faint" style="font-size:11.5px;margin-top:-8px">
  Roles and capabilities are managed at the nexus level — see <a href="/team" data-nav="/team" style="color:var(--dim)">Team</a>.
</p>

${gitHtml()}`;

      if (inviteOpen) {
        html += `
<div class="modal" data-invite-backdrop>
  <div class="sheet" style="width:440px">
    <h2>Add a member</h2>
    <p class="sub">They'll get an email invitation to join ${esc(wsName)}.</p>
    <form data-invite-form>
      <div class="lab">Email</div>
      <div class="field"><input name="email" type="email" placeholder="teammate@company.com" data-invite-email value="${attrEsc(inviteEmail)}" required /></div>
      <div class="lab">Role</div>
      <input type="hidden" name="role" value="${attrEsc(inviteRole)}" />
      <div class="regions">
        <div class="reg${inviteRole === 'member' ? ' sel' : ''}" role="button" tabindex="0" style="${inviteRole === 'member' ? roleStyle('member') : ''}" data-role="member">Member</div>
        <div class="reg${inviteRole === 'admin' ? ' sel' : ''}" role="button" tabindex="0" style="${inviteRole === 'admin' ? roleStyle('admin') : ''}" data-role="admin">Admin</div>
      </div>
      <div class="sheet-foot">
        <button class="btn" type="button" data-invite-cancel>Cancel</button>
        <button class="btn primary" type="submit">Send invite</button>
      </div>
    </form>
  </div>
</div>`;
      }

      return html;
    }

    function gitHtml() {
      if (!wsId) return '';
      const remote = git && git.remote ? git.remote : (location.origin + '/git/' + encodeURIComponent(wsId) + '.git');
      const push = 'git push ' + remote + ' main';
      return `
<div class="card" style="padding:16px 18px;margin-top:14px">
  <div style="display:flex;flex-direction:column;gap:1px;margin-bottom:12px">
    <b style="font-size:13.5px">Git remote</b>
    <span class="faint" style="font-size:11.5px">Push this workspace to the nexus — it checks the files out live. Use a <code class="mono">wbk_</code> token as the password.</span>
  </div>
  <div class="lab">Push URL</div>
  <div style="display:flex;gap:8px;align-items:stretch">
    <div class="field" style="flex:1"><input data-git-remote readonly value="${attrEsc(push)}" style="font:500 12px var(--mono)" /></div>
    <button class="btn sm" data-git-copy type="button">Copy</button>
  </div>
  <div class="lab" style="margin-top:14px">GitHub remote URL (with token)</div>
  <form data-mirror-form style="display:flex;gap:8px;align-items:stretch">
    <div class="field" style="flex:1"><input name="url" data-mirror-input placeholder="https://&lt;user&gt;:&lt;token&gt;@github.com/org/repo.git" value="${attrEsc(mirrorInput)}" style="font:500 12px var(--mono)" /></div>
    <button class="btn sm primary" type="submit">Save</button>
  </form>
  <span class="faint" style="font-size:11px;display:block;margin-top:6px">After each push the nexus mirrors all refs here. The URL may embed a token; leave blank to clear.</span>
</div>`;
    }

    function paint() {
      el.innerHTML = shell(bodyHtml());
      wire();
    }

    function wire() {
      el.querySelectorAll('[data-nav]').forEach((a) =>
        a.addEventListener('click', (e) => { e.preventDefault(); WB.nav(a.dataset.nav); }));

      const io = el.querySelector('[data-invite-open]');
      if (io) io.addEventListener('click', () => { inviteOpen = true; paint(); });

      // remove / revoke forms (server actions had no client API → faithful UI behavior)
      el.querySelectorAll('[data-remove]').forEach((f) => f.addEventListener('submit', async (e) => {
        e.preventDefault();
        data.members = data.members.filter((m) => m.id !== f.dataset.remove);
        WB.toast('Member removed');
        paint();
      }));
      el.querySelectorAll('[data-revoke]').forEach((f) => f.addEventListener('submit', async (e) => {
        e.preventDefault();
        data.pending = data.pending.filter((p) => p.id !== f.dataset.revoke);
        WB.toast('Invite revoked');
        paint();
      }));

      // invite modal
      const ib = el.querySelector('[data-invite-backdrop]');
      if (ib) ib.addEventListener('click', (e) => { if (e.target === e.currentTarget) { inviteOpen = false; paint(); } });
      const iemail = el.querySelector('[data-invite-email]');
      if (iemail) iemail.addEventListener('input', () => { inviteEmail = iemail.value; });
      el.querySelectorAll('[data-role]').forEach((d) => {
        const set = () => { inviteRole = d.dataset.role; paint(); };
        d.addEventListener('click', set);
        d.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); inviteRole = d.dataset.role; paint(); } });
      });
      const ic = el.querySelector('[data-invite-cancel]');
      if (ic) ic.addEventListener('click', () => { inviteOpen = false; paint(); });
      // git remote: copy + mirror save
      const gc = el.querySelector('[data-git-copy]');
      if (gc) gc.addEventListener('click', async () => {
        const v = el.querySelector('[data-git-remote]')?.value || '';
        try { await navigator.clipboard.writeText(v); WB.toast('Push command copied'); }
        catch (e) { WB.toast('Copy failed — select and copy manually'); }
      });
      const mi = el.querySelector('[data-mirror-input]');
      if (mi) mi.addEventListener('input', () => { mirrorInput = mi.value; });
      const mf = el.querySelector('[data-mirror-form]');
      if (mf) mf.addEventListener('submit', async (e) => {
        e.preventDefault();
        try {
          const r = await fetch('/cloud/workspace/mirror', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ ws: wsId, url: mirrorInput })
          });
          if (!r.ok) throw new Error('mirror ' + r.status);
          const out = await r.json();
          if (git) git.mirror = out.mirror || null;
          WB.toast(mirrorInput ? 'GitHub mirror saved' : 'Mirror cleared');
        } catch (err) { WB.toast('Couldn’t save the mirror'); }
      });

      const iform = el.querySelector('[data-invite-form]');
      if (iform) iform.addEventListener('submit', async (e) => {
        e.preventDefault();
        if (!inviteEmail) return;
        data.pending = [...data.pending, { id: 'inv_' + Math.random().toString(36).slice(2), email: inviteEmail }];
        WB.toast(`Invited ${inviteEmail}`);
        inviteOpen = false; inviteEmail = '';
        paint();
      });
    }

    paint();
    // Load the real git remote + current mirror, then repaint that section with live data.
    loadGit().then(() => paint());
  }
});
