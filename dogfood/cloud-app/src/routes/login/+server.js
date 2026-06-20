import { redirect } from '@sveltejs/kit';
import { authKit } from '@workos/authkit-sveltekit';

// Kick off WorkOS hosted sign-in. `returnTo` brings the user back to where the gate
// intercepted them. If already signed in, bounce home.
export const GET = async (event) => {
  if (event.locals.auth?.user) throw redirect(302, '/');
  const returnTo = event.url.searchParams.get('returnTo') || '/';
  const url = await authKit.getSignInUrl({ returnTo });
  throw redirect(302, url);
};
