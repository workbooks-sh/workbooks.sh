import { WorkOS } from '@workos-inc/node';
import { env } from '$env/dynamic/private';

// Mint the WorkOS widget token server-side (it carries the API key; never the client).
// Org/user come from the dev session env for now; in production they come from the
// signed-in session the platform auth service (auth.workbooks.sh) issues.
export async function load() {
  const workos = new WorkOS(env.WORKOS_API_KEY, { clientId: env.WORKOS_CLIENT_ID });
  // workspace display name (never expose the raw org id to the user)
  let workspace = null;
  try {
    const org = await workos.organizations.getOrganization(env.WORKOS_DEMO_ORG);
    workspace = org?.name ?? null;
  } catch { /* fall back to a generic label */ }
  try {
    const res = await workos.widgets.createToken({
      userId: env.WORKOS_DEMO_USER,
      organizationId: env.WORKOS_DEMO_ORG,
      scopes: ['widgets:users-table:manage']
    });
    return { authToken: res.token ?? res, workspace };
  } catch (e) {
    return { authToken: null, error: 'team panel unavailable', workspace };
  }
}
