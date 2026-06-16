import { error, redirect } from '@sveltejs/kit';
import { authKv, randomToken, storedSessionFromAuth, CODE_TTL } from '$lib/desktopBroker';

// The branded "Authorize this device" consent page for the DESKTOP sign-in flow. The
// auth gate guarantees a signed-in, allowlisted user reaches here (signed-out users
// were sent through login + onboarding first via returnTo). Approving mints the
// desktop session FROM the dashboard session — no extra WorkOS round-trip.

const EXPIRED = 'This sign-in link has expired. Please start again from the app.';

async function readFlow(platform, flow) {
  if (!flow) return null;
  const raw = await authKv(platform).get(`fl:${flow}`);
  return raw ? JSON.parse(raw) : null;
}

export async function load({ url, platform, locals }) {
  const flow = url.searchParams.get('flow') || '';
  const f = await readFlow(platform, flow);
  if (!f) throw error(400, EXPIRED);
  return { flow, email: locals.auth?.user?.email || '' };
}

export const actions = {
  approve: async ({ request, platform, locals }) => {
    const data = await request.formData();
    const flow = String(data.get('flow') || '');
    const kv = authKv(platform);
    const f = await readFlow(platform, flow);
    if (!f) throw error(400, EXPIRED);
    await kv.delete(`fl:${flow}`);

    const brokerCode = randomToken();
    await kv.put(
      `cd:${brokerCode}`,
      JSON.stringify({ session: storedSessionFromAuth(locals.auth), challenge: f.challenge }),
      { expirationTtl: CODE_TTL }
    );

    const sep = f.redirectUri.includes('?') ? '&' : '?';
    throw redirect(303, `${f.redirectUri}${sep}code=${brokerCode}`);
  },

  cancel: async ({ request, platform }) => {
    const data = await request.formData();
    const flow = String(data.get('flow') || '');
    const f = await readFlow(platform, flow);
    if (f) {
      await authKv(platform).delete(`fl:${flow}`);
      const sep = f.redirectUri.includes('?') ? '&' : '?';
      throw redirect(303, `${f.redirectUri}${sep}error=access_denied`);
    }
    throw redirect(303, '/');
  }
};
