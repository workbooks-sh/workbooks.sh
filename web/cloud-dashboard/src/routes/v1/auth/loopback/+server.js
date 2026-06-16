import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import { authKv, randomToken, workos, storedSession, CODE_TTL } from '$lib/desktopBroker';

// Desktop sign-in, step 2: AuthKit returns here (the desktop's WorkOS callback, kept
// separate from the web login's /v1/auth/callback). We authenticate the WorkOS code,
// mint a one-time broker code bound to the flow's PKCE challenge, and 302 back to the
// app's loopback with ?code=. (No cookie — this isn't the browser session.)
export async function GET({ url, platform }) {
  const code = url.searchParams.get('code') || '';
  const state = url.searchParams.get('state') || '';
  if (!code || !state) return new Response('bad request', { status: 400 });

  const kv = authKv(platform);
  const flowRaw = await kv.get(`st:${state}`);
  if (!flowRaw) return new Response('sign-in failed — please try again', { status: 400 });
  await kv.delete(`st:${state}`);
  const flow = JSON.parse(flowRaw);

  let auth;
  try {
    auth = await workos(env).userManagement.authenticateWithCode({ clientId: env.WORKOS_CLIENT_ID, code });
  } catch {
    return new Response('sign-in failed — please try again', { status: 400 });
  }

  const brokerCode = randomToken();
  await kv.put(
    `cd:${brokerCode}`,
    JSON.stringify({ session: storedSession(auth), challenge: flow.challenge }),
    { expirationTtl: CODE_TTL }
  );

  const sep = flow.redirectUri.includes('?') ? '&' : '?';
  throw redirect(302, `${flow.redirectUri}${sep}code=${brokerCode}`);
}
