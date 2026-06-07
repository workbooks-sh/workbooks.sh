// Sign-up form action. Backend API creates the user (bypasses CAPTCHA which
// would block server-to-server FAPI calls), then mints a sign-in token,
// then exchanges the ticket via FAPI to get a session JWT we can put in
// the __session cookie.

import { fail, redirect } from "@sveltejs/kit";
import { env } from "$env/dynamic/private";
import { env as pub } from "$env/dynamic/public";
import { getClerkClient } from "$lib/clerk.js";
import { fapiExchangeTicket } from "$lib/clerk-fapi.js";
import type { Actions, PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, url }) => {
  if (locals.auth.userId) {
    redirect(303, url.searchParams.get("redirect_url") ?? "/app");
  }
  return {};
};

export const actions: Actions = {
  default: async ({ request, cookies, url }) => {
    const form = await request.formData();
    const email = form.get("email")?.toString().trim().toLowerCase() ?? "";
    const password = form.get("password")?.toString() ?? "";
    const firstName = form.get("first_name")?.toString().trim() ?? "";

    if (!email || !password) {
      return fail(400, { error: "Email and password required.", email, firstName });
    }
    if (password.length < 8) {
      return fail(400, { error: "Password must be at least 8 characters.", email, firstName });
    }

    const secret = env.CLERK_SECRET_KEY;
    const publishable = pub.PUBLIC_CLERK_PUBLISHABLE_KEY;
    if (!secret || !publishable) {
      return fail(503, { error: "Auth provider not configured.", email, firstName });
    }
    const clerk = getClerkClient(secret, publishable);

    // 1. Reject duplicates.
    try {
      const existing = await clerk.users.getUserList({ emailAddress: [email] });
      const list = existing.data ?? (existing as any);
      if (Array.isArray(list) && list.length > 0) {
        return fail(409, { error: "An account with that email already exists. Try signing in instead.", email, firstName });
      }
    } catch (e) {
      // Non-fatal — proceed to create; if it dupes, createUser will reject.
    }

    // 2. Create the user (Backend API, no CAPTCHA).
    let user: any;
    try {
      user = await clerk.users.createUser({
        emailAddress: [email],
        password,
        firstName: firstName || undefined,
        skipPasswordChecks: false,
      } as any);
    } catch (e: any) {
      console.error("[sign-up] createUser failed", JSON.stringify({ message: e?.message, errors: e?.errors }));
      const msg = e?.errors?.[0]?.longMessage ?? e?.errors?.[0]?.message ?? e?.message ?? "Could not create account.";
      return fail(400, { error: msg, email, firstName });
    }

    // 3. Mint a one-time sign-in ticket for the new user.
    let ticket: string;
    try {
      const tokenObj = await (clerk as any).signInTokens.createSignInToken({
        userId: user.id,
        expiresInSeconds: 60,
      });
      ticket = tokenObj.token;
    } catch (e: any) {
      console.error("[sign-up] createSignInToken failed", JSON.stringify({ message: e?.message, errors: e?.errors }));
      return fail(500, {
        error: `Account created but auto sign-in failed (${e?.message ?? "ticket"}). Try signing in.`,
        email, firstName,
      });
    }

    // 4. Exchange the ticket for an active session JWT via FAPI.
    let session: Awaited<ReturnType<typeof fapiExchangeTicket>>;
    try {
      session = await fapiExchangeTicket(publishable, ticket);
    } catch (e: any) {
      console.error("[sign-up] ticket exchange failed", JSON.stringify({ message: e?.message, errors: e?.errors, fapi: e?.fapi }));
      return fail(500, {
        error: `Account created but auto sign-in failed (${e?.message ?? "exchange"}). Try signing in.`,
        email, firstName,
      });
    }

    cookies.set("__session", session.jwt, {
      path: "/",
      httpOnly: true,
      secure: true,
      sameSite: "lax",
      maxAge: 60 * 60 * 24 * 7,
    });
    cookies.set("__client_uat", String(Math.floor(Date.now() / 1000)), {
      path: "/",
      secure: true,
      sameSite: "lax",
      maxAge: 60 * 60 * 24 * 365,
    });

    redirect(303, url.searchParams.get("redirect_url") ?? "/onboard");
  },
};
