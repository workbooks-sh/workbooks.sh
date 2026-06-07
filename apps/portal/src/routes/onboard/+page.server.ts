// /onboard — welcome screen for new accounts. Reads server-side session.

import { redirect } from "@sveltejs/kit";
import type { Actions, PageServerLoad } from "./$types";
import { env } from "$env/dynamic/private";
import { getClerkClient } from "$lib/clerk.js";

export const load: PageServerLoad = async ({ locals }) => {
  if (!locals.auth.userId) {
    redirect(303, "/app/auth/sign-in?redirect_url=/onboard");
  }
  return { user: locals.auth.user };
};

export const actions: Actions = {
  default: async ({ request, locals }) => {
    if (!locals.auth.userId) redirect(303, "/app/auth/sign-in");
    const form = await request.formData();
    const fullName = form.get("name")?.toString().trim() ?? "";
    if (fullName) {
      const [first, ...rest] = fullName.split(/\s+/);
      const last = rest.join(" ");
      try {
        const clerk = getClerkClient(env.CLERK_SECRET_KEY!, env.PUBLIC_CLERK_PUBLISHABLE_KEY!);
        await clerk.users.updateUser(locals.auth.userId, { firstName: first ?? "", lastName: last });
      } catch {
        // non-fatal
      }
    }
    redirect(303, "/app/keys");
  },
};
