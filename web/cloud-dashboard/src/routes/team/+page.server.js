import { WorkOS } from '@workos-inc/node';
import { env } from '$env/dynamic/private';

// Mint the WorkOS widget token server-side (it carries the API key; never the client).
// Org/user come from the dev session env for now; in production they come from the
// signed-in session the platform auth service (auth.workbooks.sh) issues.
export async function load() {
  const workos = new WorkOS(env.WORKOS_API_KEY, { clientId: env.WORKOS_CLIENT_ID });
  try {
    const res = await workos.widgets.createToken({
      userId: env.WORKOS_DEMO_USER,
      organizationId: env.WORKOS_DEMO_ORG,
      scopes: ['widgets:users-table:manage']
    });
    return { authToken: res.token ?? res, org: env.WORKOS_DEMO_ORG };
  } catch (e) {
    return { authToken: null, error: e.message, org: env.WORKOS_DEMO_ORG };
  }
}
