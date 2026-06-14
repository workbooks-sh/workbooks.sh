<script>
  import { enhance } from '$app/forms';
  import { invalidateAll } from '$app/navigation';
  import { toast } from '$lib/toastStore.svelte.js';
  let { data } = $props();

  let inviteOpen = $state(false);
  let inviteEmail = $state('');
  let inviteRole = $state('member');

  // One consistent color PER ROLE — admin/member/owner look the SAME everywhere
  // (member-list tags, pending rows, AND the invite modal's selected role button).
  const ROLE_STYLE = {
    owner: 'background:var(--cream);color:var(--on-bloom);border-color:var(--cream)',
    admin: 'background:var(--mint);color:var(--on-bloom);border-color:var(--mint)',
    member: 'background:var(--sky);color:var(--on-bloom);border-color:var(--sky)',
  };
  const roleStyle = (role) => ROLE_STYLE[role] || '';
  const pickKey = (e, role) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); inviteRole = role; } };

  // Roles → capabilities, mirroring runtime Workbooks.RBAC (GET /api/roles → matrix).
  const ROLES = ['owner', 'admin', 'member', 'viewer'];
  const MATRIX = {
    owner: ['view', 'edit', 'share', 'manage', 'delete', 'manage_roles'],
    admin: ['view', 'edit', 'share', 'manage'],
    member: ['view', 'edit'],
    viewer: ['view']
  };
  const CAPS = [
    { key: 'view', label: 'View', desc: 'Open nexuses, workbooks and folders' },
    { key: 'edit', label: 'Edit', desc: 'Change workbooks and content' },
    { key: 'share', label: 'Share folders', desc: 'Share a folder with a teammate' },
    { key: 'manage', label: 'Manage nexuses', desc: 'Restart, sleep, configure' },
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
</script>

<section>
  <div class="sechead">
    <div>
      <h2>Team</h2>
      <p>Members of {data.workspace ? `the ${data.workspace}` : 'your'} workspace. Invite teammates, assign roles, and manage who can access your nexuses.</p>
    </div>
  </div>

  <!-- seat usage -->
  <div class="card" style="display:flex;align-items:center;gap:18px">
    <div style="flex:1">
      <div style="display:flex;justify-content:space-between;font-size:13px">
        <span><b>Team</b> plan · {data.members.length} of 10 seats used</span>
        <span class="dim mono">{Math.max(0, 10 - data.members.length)} seats left</span>
      </div>
      <div class="bar"><i style="width:{Math.min(100, data.members.length * 10)}%"></i></div>
      <div class="faint" style="font-size:11.5px">Seats update automatically as you add or remove members.</div>
    </div>
    <button class="btn sm" onclick={() => toast('Upgrade flow opening…')}>Upgrade plan</button>
  </div>

  <!-- members -->
  <div class="card" style="padding:0;overflow:hidden">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-bottom:2px solid var(--line)">
      <b style="font-size:13.5px">Members <span class="dim mono" style="font-weight:400">· {data.members.length}</span></b>
      <button class="btn sm primary" onclick={() => (inviteOpen = true)}>
        <svg class="ico" viewBox="0 0 24 24"><path fill="currentColor" d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6V5Z"/></svg> Invite
      </button>
    </div>
    <table>
      <thead><tr><th>Member</th><th>Role</th><th>Last active</th><th></th></tr></thead>
      <tbody>
        {#each data.members as m (m.id)}
          <tr>
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:linear-gradient(135deg,var({pair(m.name)[0]}),var({pair(m.name)[1]}))">{initials(m.name)}</span>
                <div><div style="font-weight:600">{m.name}</div><div class="faint mono" style="font-size:11px">{m.email}</div></div>
              </div>
            </td>
            <td><span class="tag" style={roleStyle(m.role)}>{m.role}</span></td>
            <td class="dim">{ago(m.lastActive)}</td>
            <td class="num">
              <form method="POST" action="?/remove" use:enhance={() => async ({ result }) => {
                if (result.type === 'success') { toast('Member removed'); await invalidateAll(); }
                else toast('Could not remove member');
              }}>
                <input type="hidden" name="id" value={m.id} />
                <button class="btn sm" type="submit">Remove</button>
              </form>
            </td>
          </tr>
        {/each}

        {#each data.pending as p (p.id)}
          <tr style="opacity:.7">
            <td>
              <div style="display:flex;align-items:center;gap:11px">
                <span class="mav" style="background:var(--panel-2);color:var(--dim)">{(p.email[0] || '?').toUpperCase()}</span>
                <div><div style="font-weight:600">{p.email}</div><div class="faint mono" style="font-size:11px">invited</div></div>
              </div>
            </td>
            <td><span class="tag" style={roleStyle('member')}>member</span></td>
            <td><span class="mono" style="color:var(--amber);font-size:12px">● pending</span></td>
            <td class="num">
              <form method="POST" action="?/revoke" use:enhance={() => async ({ result }) => {
                if (result.type === 'success') { toast('Invite revoked'); await invalidateAll(); }
              }}>
                <input type="hidden" name="id" value={p.id} />
                <button class="btn sm" type="submit">Revoke</button>
              </form>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>

  <!-- roles & access: the capability matrix, mirroring the runtime RBAC engine -->
  <div class="card" style="padding:0;overflow:hidden">
    <div style="padding:14px 18px;border-bottom:2px solid var(--line)">
      <b style="font-size:13.5px">Roles &amp; access</b>
      <div class="faint" style="font-size:11.5px">What each role can do. Access also nests — a teammate needs access to a nexus before its workbooks.</div>
    </div>
    <table>
      <thead><tr><th>Capability</th>{#each ROLES as r}<th class="cap">{r}</th>{/each}</tr></thead>
      <tbody>
        {#each CAPS as c}
          <tr>
            <td><b style="font-weight:600">{c.label}</b><div class="faint" style="font-size:11px">{c.desc}</div></td>
            {#each ROLES as r}
              <td class="cap">{MATRIX[r].includes(c.key) ? '✓' : '·'}</td>
            {/each}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
</section>

{#if inviteOpen}
  <div class="modal" onclick={(e) => { if (e.target === e.currentTarget) inviteOpen = false; }}>
    <div class="sheet" style="width:440px">
      <h2>Invite teammate</h2>
      <p class="sub">They'll get an email invitation to join the {data.workspace || 'workspace'}.</p>
      <form method="POST" action="?/invite" use:enhance={() => async ({ result, update }) => {
        if (result.type === 'success') { toast(`Invited ${inviteEmail}`); inviteOpen = false; inviteEmail = ''; await invalidateAll(); }
        else toast(result.data?.error || 'Invite failed');
        await update({ reset: false });
      }}>
        <div class="lab">Email</div>
        <div class="field"><input name="email" type="email" placeholder="teammate@company.com" bind:value={inviteEmail} required /></div>
        <div class="lab">Role</div>
        <input type="hidden" name="role" value={inviteRole} />
        <div class="regions">
          <div class="reg" role="button" tabindex="0" class:sel={inviteRole === 'member'} style={inviteRole === 'member' ? roleStyle('member') : ''} onclick={() => (inviteRole = 'member')} onkeydown={(e) => pickKey(e, 'member')}>Member</div>
          <div class="reg" role="button" tabindex="0" class:sel={inviteRole === 'admin'} style={inviteRole === 'admin' ? roleStyle('admin') : ''} onclick={() => (inviteRole = 'admin')} onkeydown={(e) => pickKey(e, 'admin')}>Admin</div>
        </div>
        <div class="sheet-foot">
          <button class="btn" type="button" onclick={() => (inviteOpen = false)}>Cancel</button>
          <button class="btn primary" type="submit">Send invite</button>
        </div>
      </form>
    </div>
  </div>
{/if}

<style>
  .mav { width:30px; height:30px; border-radius:50%; display:grid; place-items:center; flex:none;
    font:700 11px var(--mono); color:var(--on-bloom); border:2px solid var(--stroke); }
  .sheet-foot { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }
  .cap { text-align:center; text-transform:capitalize; font-variant-numeric:tabular-nums; }
  th.cap { color:var(--dim); font-size:12px; }
</style>
