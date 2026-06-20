import { redirect } from '@sveltejs/kit';

// The signed-in, allowlisted user (the gate in hooks.server guarantees this on every
// non-public route). Also drives first-run onboarding: a brand-new user is sent to
// /welcome until they finish (tracked by the wb_onboarded cookie — later, a real
// setup flag on the runtime).
export const load = async ({ locals, url, cookies }) => {
  const user = locals.auth?.user || null;
  const onboarded = cookies.get('wb_onboarded') === '1';

  // The onboarding answers (set by /welcome). Drives the org identity in the chrome
  // and the seeded first nexus on the dashboard. Null until the user finishes.
  let profile = null;
  try { profile = JSON.parse(cookies.get('wb_profile') || 'null'); } catch { profile = null; }

  // Bare routes that must NOT trigger the onboarding redirect (the wizard itself, and
  // the wall a non-allowlisted user lands on).
  const bare = url.pathname === '/welcome' || url.pathname === '/denied';
  if (user && !onboarded && !bare) {
    throw redirect(302, '/welcome');
  }

  return {
    user: user && { email: user.email, firstName: user.firstName, lastName: user.lastName },
    onboarded,
    profile
  };
};
