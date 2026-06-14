import { sequence } from '@sveltejs/kit/hooks';
import { redirect } from '@sveltejs/kit';
import { configureAuthKit, authKitHandle } from '@workos/authkit-sveltekit';
import { env } from '$env/dynamic/private';

// WorkOS AuthKit — hosted sign-in → callback → encrypted session cookie. The handle
// only POPULATES event.locals.auth; route protection + the allowlist are ours below.
configureAuthKit({
  clientId: env.WORKOS_CLIENT_ID,
  apiKey: env.WORKOS_API_KEY,
  redirectUri: env.WORKOS_REDIRECT_URI,
  cookiePassword: env.WORKOS_COOKIE_PASSWORD
});

// PRODUCTION ALLOWLIST — only these emails may use the app. Everything else, even a
// successfully-authenticated WorkOS user, is refused. Configurable via WB_ALLOWLIST
// (comma-separated); defaults to the founder. The email must match what WorkOS
// returns as user.email at login.
const ALLOWLIST = (env.WB_ALLOWLIST || 'shane@shinyobjectz.com')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

// Routes reachable WITHOUT being a signed-in, allowlisted user.
const PUBLIC = ['/login', '/logout', '/v1/auth/callback', '/denied'];
const isPublic = (path) => PUBLIC.some((p) => path === p || path.startsWith(p + '/'));

const gate = async ({ event, resolve }) => {
  const { pathname } = event.url;

  // let the auth dance + static-ish public routes through
  if (isPublic(pathname)) return resolve(event);

  const user = event.locals.auth?.user;

  // not signed in → start the WorkOS sign-in (returnTo brings them back here)
  if (!user) throw redirect(302, `/login?returnTo=${encodeURIComponent(pathname + event.url.search)}`);

  // signed in but NOT allowlisted → hard wall (no app data ever reaches them).
  // REQUIRE a VERIFIED email: without this, a self-serve sign-up could register the
  // founder's address unverified and pass the gate. Verified + allowlisted only.
  const email = (user.email || '').toLowerCase();
  if (user.emailVerified !== true || !ALLOWLIST.includes(email)) throw redirect(302, '/denied');

  return resolve(event);
};

export const handle = sequence(authKitHandle(), gate);
