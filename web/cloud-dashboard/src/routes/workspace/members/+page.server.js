import { WorkOS } from '@workos-inc/node';
import { env } from '$env/dynamic/private';
import { fail } from '@sveltejs/kit';

// Members of the active WORKSPACE. The org's users are the candidate pool
// (org members ⊇ workspace members); provisioning a user INTO a workspace draws
// from that pool. Until a dedicated workspace-membership API lands in the control
// plane, the org roster IS the workspace roster — honest, no fabricated rows.
const client = () => new WorkOS(env.WORKOS_API_KEY, { clientId: env.WORKOS_CLIENT_ID });
const ORG = () => env.WORKOS_DEMO_ORG;

export async function load() {
  const workos = client();
  let members = [], pending = [];
  try {
    const mems = (await workos.userManagement.listOrganizationMemberships({ organizationId: ORG(), limit: 100 })).data;
    members = await Promise.all(mems.map(async (m) => {
      let u = {};
      try { u = await workos.userManagement.getUser(m.userId); } catch { /* skip */ }
      const name = [u.firstName, u.lastName].filter(Boolean).join(' ') || (u.email || 'unknown').split('@')[0];
      return { id: m.id, name, email: u.email || '', role: m.role?.slug || 'member', lastActive: u.lastSignInAt || null };
    }));
    pending = (await workos.userManagement.listInvitations({ organizationId: ORG(), limit: 100 })).data
      .filter((i) => i.state === 'pending')
      .map((i) => ({ id: i.id, email: i.email }));
  } catch { /* honest empty */ }
  members.sort((a, b) => (a.role === 'admin' ? 0 : 1) - (b.role === 'admin' ? 0 : 1) || a.name.localeCompare(b.name));
  return { members, pending };
}

export const actions = {
  invite: async ({ request }) => {
    const data = await request.formData();
    const email = String(data.get('email') || '').trim();
    const roleSlug = String(data.get('role') || 'member');
    if (!email) return fail(400, { error: 'Email is required' });
    try {
      await client().userManagement.sendInvitation({ email, organizationId: ORG(), roleSlug });
      return { invited: email };
    } catch (e) {
      try { await client().userManagement.sendInvitation({ email, organizationId: ORG() }); return { invited: email }; }
      catch (e2) { return fail(400, { error: e2.message || 'Invite failed' }); }
    }
  },
  remove: async ({ request }) => {
    const id = String((await request.formData()).get('id') || '');
    try { await client().userManagement.deleteOrganizationMembership(id); return { removed: true }; }
    catch (e) { return fail(400, { error: e.message || 'Remove failed' }); }
  },
  revoke: async ({ request }) => {
    const id = String((await request.formData()).get('id') || '');
    try { await client().userManagement.revokeInvitation(id); return { revoked: true }; }
    catch (e) { return fail(400, { error: e.message || 'Revoke failed' }); }
  }
};
