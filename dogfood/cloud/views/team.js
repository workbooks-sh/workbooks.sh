WB.scopedStyles('/team', `
  .mav { width:30px; height:30px; border-radius:50%; display:grid; place-items:center; flex:none;
    font:700 11px var(--mono); color:var(--on-bloom); border:2px solid var(--stroke); }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
  .cap { text-align:center; text-transform:capitalize; font-variant-numeric:tabular-nums; }
  th.cap { color:var(--dim); font-size:12px; }
`);

WB.view('/team', {
  title: 'Team',
  accent: 'var(--peach)',
  async render(el, ctx) {
    // ── loader data (team/+page.server.js) — sourced from the org. No team API on the
    // WB seam yet, so honest-empty (members/pending) with the workspace label from the
    // active workspace, exactly like the dashboard's other no-runtime views. ──
    const data = {
      workspace: (WB.ws.active && WB.ws.active.name) || null,
      members: [],
      pending: []
    };

    // One consistent color PER ROLE.
    const ROLE_STYLE = {
      owner: 'background:var(--cream);color:var(--on-bloom);border-color:var(--cream)',
      admin: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)',
      member: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
    };
    const roleStyle = (role) => ROLE_STYLE[role] || '';

    // Roles → capabilities, mirroring runtime Workbooks.RBAC.
    const ROLES = ['owner', 'admin', 'member', 'viewer'];
    const MATRIX = {
      owner: ['view', 'edit', 'share', 'manage', 'delete', 'manage_roles'],
      admin: ['view', 'edit', 'share', 'manage'],
      member: ['view', 'edit'],
      viewer: ['view']
    };
    const CAPS = [
      { key: 'view', label: 'View', desc: 'Open the nexus, workbooks and folders' },
      { key: 'edit', label: 'Edit', desc: 'Change workbooks and content' },
      { key: 'share', label: 'Share folders', desc: 'Share a folder with a teammate' },
      { key: 'manage', label: 'Manage nexus', desc: 'Restart, sleep, configure' },
      { key: 'delete', label: 'Delete', desc: 'Permanently remove a nexus' },
      { key: 'manage_roles', label: 'Manage roles', desc: 'Change what teammates can do' }
    ];

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

    const esc = (s) => String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');

    // ── invite modal local state ──
    let inviteOpen = false;
    let inviteEmail = '';
    let inviteRole = 'member';

    function memberRows() {
      return data.members.map((m) => {
        const p = pair(m.name);
        return `<tr>
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:linear-gradient(135deg,var(${p[0]}),var(${p[1]}))">${esc(initials(m.name))}</span>
                <div><div style="font-weight:600">${esc(m.name)}</div><div class="faint mono" style="font-size:11px">${esc(m.email)}</div></div>
              </div>
            </td>
            <td><span class="tag" style="${esc(roleStyle(m.role))}">${esc(m.role)}</span></td>
            <td class="dim">${esc(ago(m.lastActive))}</td>
            <td class="num">
              <form data-form="remove" data-id="${esc(m.id)}">
                <input type="hidden" name="id" value="${esc(m.id)}" />
                <button class="btn sm" type="submit">Remove</button>
              </form>
            </td>
          </tr>`;
      }).join('');
    }

    function pendingRows() {
      return data.pending.map((p) => `<tr style="opacity:.7">
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:var(--panel-2);color:var(--dim)">${esc((p.email[0] || '?').toUpperCase())}</span>
                <div><div style="font-weight:600">${esc(p.email)}</div><div class="faint mono" style="font-size:11px">invited</div></div>
              </div>
            </td>
            <td><span class="tag" style="${esc(roleStyle('member'))}">member</span></td>
            <td><span class="mono" style="color:var(--amber);font-size:12px">● pending</span></td>
            <td class="num">
              <form data-form="revoke" data-id="${esc(p.id)}">
                <input type="hidden" name="id" value="${esc(p.id)}" />
                <button class="btn sm" type="submit">Revoke</button>
              </form>
            </td>
          </tr>`).join('');
    }

    function capRows() {
      return CAPS.map((c) => `<tr>
            <td><b style="font-weight:600">${esc(c.label)}</b><div class="faint" style="font-size:11px">${esc(c.desc)}</div></td>
            ${ROLES.map((r) => `<td class="cap">${MATRIX[r].includes(c.key) ? '✓' : '·'}</td>`).join('')}
          </tr>`).join('');
    }

    function modalHtml() {
      if (!inviteOpen) return '';
      const memSel = inviteRole === 'member';
      const admSel = inviteRole === 'admin';
      return `<div class="modal" data-modal>
    <div class="sheet" style="width:440px">
      <h2>Invite teammate</h2>
      <p class="sub">They'll get an email invitation to join the ${esc(data.workspace || 'workspace')}.</p>
      <form data-form="invite">
        <div class="lab">Email</div>
        <div class="field"><input name="email" type="email" placeholder="teammate@company.com" data-f="email" value="${esc(inviteEmail)}" required /></div>
        <div class="lab">Role</div>
        <input type="hidden" name="role" value="${esc(inviteRole)}" />
        <div class="regions">
          <div class="reg${memSel ? ' sel' : ''}" role="button" tabindex="0" data-role="member" style="${memSel ? esc(roleStyle('member')) : ''}">Member</div>
          <div class="reg${admSel ? ' sel' : ''}" role="button" tabindex="0" data-role="admin" style="${admSel ? esc(roleStyle('admin')) : ''}">Admin</div>
        </div>
        <div class="sheet-foot">
          <button class="btn" type="button" data-act="cancel">Cancel</button>
          <button class="btn primary" type="submit">Send invite</button>
        </div>
      </form>
    </div>
  </div>`;
    }

    function paint() {
      el.innerHTML = `
<section>
  <div class="sechead">
    <div>
      <h2>Team</h2>
      <p>Members of ${data.workspace ? `the ${esc(data.workspace)}` : 'your'} workspace. Invite teammates, assign roles, and manage who can access your nexus.</p>
    </div>
  </div>

  <div class="card" style="display:flex;align-items:center;gap:18px">
    <div style="flex:1">
      <div style="display:flex;justify-content:space-between;font-size:13px">
        <span><b>Team</b> plan · ${data.members.length} of 10 seats used</span>
        <span class="dim mono">${Math.max(0, 10 - data.members.length)} seats left</span>
      </div>
      <div class="bar"><i style="width:${Math.min(100, data.members.length * 10)}%"></i></div>
      <div class="faint" style="font-size:11.5px">Seats update automatically as you add or remove members.</div>
    </div>
    <button class="btn sm" data-act="upgrade">Upgrade plan</button>
  </div>

  <div class="card" style="padding:0;overflow:hidden">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:2px solid var(--line)">
      <b style="font-size:13.5px">Members <span class="dim mono" style="font-weight:400">· ${data.members.length}</span></b>
      <button class="btn sm primary" data-act="openinvite">
        <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Invite
      </button>
    </div>
    <table>
      <thead><tr><th>Member</th><th>Role</th><th>Last active</th><th></th></tr></thead>
      <tbody>${memberRows()}${pendingRows()}</tbody>
    </table>
  </div>

  <div class="card" style="padding:0;overflow:hidden">
    <div style="padding:14px 18px;border-bottom:2px solid var(--line)">
      <b style="font-size:13.5px">Roles &amp; access</b>
      <div class="faint" style="font-size:11.5px">What each role can do. Access also nests — a teammate needs access to the nexus before its workbooks.</div>
    </div>
    <table>
      <thead><tr><th>Capability</th>${ROLES.map((r) => `<th class="cap">${esc(r)}</th>`).join('')}</tr></thead>
      <tbody>${capRows()}</tbody>
    </table>
  </div>
</section>
${modalHtml()}`;
      wire();
    }

    function wire() {
      el.querySelector('[data-act="upgrade"]')?.addEventListener('click', () => WB.toast('Upgrade flow opening…'));
      el.querySelector('[data-act="openinvite"]')?.addEventListener('click', () => { inviteOpen = true; paint(); });

      // remove member
      el.querySelectorAll('[data-form="remove"]').forEach((f) => {
        f.addEventListener('submit', async (e) => {
          e.preventDefault();
          // No team API on the seam — reflect the success path's UX.
          const id = f.getAttribute('data-id');
          data.members = data.members.filter((m) => m.id !== id);
          WB.toast('Member removed');
          paint();
        });
      });

      // revoke invite
      el.querySelectorAll('[data-form="revoke"]').forEach((f) => {
        f.addEventListener('submit', async (e) => {
          e.preventDefault();
          const id = f.getAttribute('data-id');
          data.pending = data.pending.filter((p) => p.id !== id);
          WB.toast('Invite revoked');
          paint();
        });
      });

      // invite modal
      const modal = el.querySelector('[data-modal]');
      if (modal) {
        modal.addEventListener('click', (e) => { if (e.target === e.currentTarget) { inviteOpen = false; paint(); } });
        el.querySelector('[data-act="cancel"]')?.addEventListener('click', () => { inviteOpen = false; paint(); });
        const emailI = el.querySelector('[data-f="email"]');
        if (emailI) emailI.addEventListener('input', (e) => { inviteEmail = e.target.value; });

        el.querySelectorAll('.reg[data-role]').forEach((r) => {
          const role = r.getAttribute('data-role');
          const pick = () => { inviteRole = role; paint(); };
          r.addEventListener('click', pick);
          r.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
        });

        el.querySelector('[data-form="invite"]')?.addEventListener('submit', async (e) => {
          e.preventDefault();
          WB.toast(`Invited ${inviteEmail}`);
          inviteOpen = false; inviteEmail = '';
          paint();
        });
      }
    }

    paint();
  }
});
