import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';
import {
  authKv,
  isValidRedirect,
  validChallenge,
  validOrg,
  randomToken,
  workos,
  loopbackCallback,
  STATE_TTL
} from '$lib/desktopBroker';

// Desktop sign-in, step 1: the native app opens this in a browser with its loopback
// redirect_uri + PKCE challenge (+ optional organization_id for the switcher). We
// stash the flow, then branch:
//   • normal sign-in → the branded /authorize consent page (which reuses the
//     dashboard's own login + onboarding via returnTo for new/signed-out users).
//   • org switch (organization_id) → straight to AuthKit scoped to that org (no
//     consent needed — you're moving within your own account).
// Both paths end by minting a one-time broker code bound to this flow's challenge.
export async function GET({ url, platform }) {
  const redirectUri = url.searchParams.get('redirect_uri') || '';
  const challenge = url.searchParams.get('code_challenge') || '';
  const org = url.searchParams.get('organization_id') || '';

  if (!isValidRedirect(redirectUri)) return new Response('sign-in unavailable (bad redirect)', { status: 400 });
  if (!validChallenge(challenge)) return new Response('sign-in unavailable (bad challenge)', { status: 400 });
  if (!validOrg(org)) return new Response('sign-in unavailable (bad org)', { status: 400 });

  const kv = authKv(platform);
  const flow = randomToken();
  await kv.put(`fl:${flow}`, JSON.stringify({ redirectUri, challenge, org }), { expirationTtl: STATE_TTL });

  // Org switch: scoped AuthKit round-trip (loopback callback mints the code).
  if (org) {
    const authorizationUrl = workos(env).userManagement.getAuthorizationUrl({
      provider: 'authkit',
      clientId: env.WORKOS_CLIENT_ID,
      redirectUri: loopbackCallback(url),
      state: flow,
      organizationId: org
    });
    throw redirect(302, authorizationUrl);
  }

  // Normal sign-in: the consent page (the auth gate sends signed-out users through
  // login + onboarding first, then returnTo brings them back here).
  throw redirect(302, `/authorize?flow=${flow}`);
}
