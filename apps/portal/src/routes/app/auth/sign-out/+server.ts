// /app/auth/sign-out — revoke the Clerk session via the backend SDK, clear
// cookies, redirect to /.

import { redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { getClerkClient } from "$lib/clerk.js";
import type { RequestHandler } from "./$types";

const handle: RequestHandler = async (event) => {
  const secret = env.CLERK_SECRET_KEY;
  const publishable = env.PUBLIC_CLERK_PUBLISHABLE_KEY;

  if (event.locals.auth?.sessionId && secret && publishable) {
    try {
      const clerk = getClerkClient(secret, publishable);
      await clerk.sessions.revokeSession(event.locals.auth.sessionId);
    } catch {
      // best-effort
    }
  }
  for (const name of ["__session", "__client_uat", "__client"]) {
    event.cookies.delete(name, { path: "/" });
  }
  // Send to the lander on the bare brandnana.net (not "/" — on app.brandnana.net
  // the reroute would map "/" → "/app" which redirects back to sign-in).
  redirect(302, "https://brandnana.net");
};

export const GET = handle;
export const POST = handle;
