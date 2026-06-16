import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import {
  authKv,
  isLoopback,
  validChallenge,
  validOrg,
  randomToken,
  workos,
  loopbackCallback,
  STATE_TTL
} from '$lib/desktopBroker';

// Desktop sign-in, step 1: the native app opens this in a browser with its loopback
// redirect_uri + PKCE challenge (+ optional organization_id for the org switcher).
// We stash the flow and 302 to hosted AuthKit — the SAME WorkOS the web login uses.
export async function GET({ url, platform }) {
  const redirectUri = url.searchParams.get('redirect_uri') || '';
  const challenge = url.searchParams.get('code_challenge') || '';
  const org = url.searchParams.get('organization_id') || '';

  if (!isLoopback(redirectUri)) return new Response('sign-in unavailable (bad redirect)', { status: 400 });
  if (!validChallenge(challenge)) return new Response('sign-in unavailable (bad challenge)', { status: 400 });
  if (!validOrg(org)) return new Response('sign-in unavailable (bad org)', { status: 400 });

  const kv = authKv(platform);
  const state = randomToken();
  await kv.put(`st:${state}`, JSON.stringify({ redirectUri, challenge }), { expirationTtl: STATE_TTL });

  const authorizationUrl = workos(env).userManagement.getAuthorizationUrl({
    provider: 'authkit',
    clientId: env.WORKOS_CLIENT_ID,
    redirectUri: loopbackCallback(url),
    state,
    ...(org ? { organizationId: org } : {})
  });

  throw redirect(302, authorizationUrl);
}
