import { redirect } from "@sveltejs/kit";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals, url }) => {
  // Auth routes are public — skip the gate or we sign-in loop on itself.
  if (url.pathname.startsWith("/app/auth/")) {
    return { user: locals.auth.user, sessionJwt: locals.auth.sessionToken };
  }
  if (!locals.auth.userId) {
    redirect(302, `/app/auth/sign-in?redirect_url=${encodeURIComponent(url.pathname)}`);
  }
  return {
    user: locals.auth.user,
    sessionJwt: locals.auth.sessionToken,
  };
};
