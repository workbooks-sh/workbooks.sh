// Expose minimal auth state to every page so the lander header can show
// "sign in" vs "portal →" without each page re-checking.

import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals }) => ({
  signedIn: Boolean(locals.auth.userId),
  user: locals.auth.user,
});
