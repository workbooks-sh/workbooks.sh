// Sign-in form action. Same Backend-API + ticket pattern as sign-up:
// lookup → verifyPassword → createSignInToken → exchangeTicket → cookie.
// All admin/server-to-server; bypasses Clerk's CAPTCHA.

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

    if (!email || !password) {
      return fail(400, { error: "Email and password required.", email });
    }
    const secret = env.CLERK_SECRET_KEY;
    const publishable = pub.PUBLIC_CLERK_PUBLISHABLE_KEY;
    if (!secret || !publishable) {
      return fail(503, { error: "Auth provider not configured.", email });
    }
    const clerk = getClerkClient(secret, publishable);

    // 1. Look up user.
    let user: any;
    try {
      const list = await clerk.users.getUserList({ emailAddress: [email] });
      user = (list.data ?? (list as any))?.[0];
    } catch (e: any) {
      console.error("[sign-in] getUserList failed", JSON.stringify({ message: e?.message, errors: e?.errors }));
    }
    if (!user) {
      return fail(401, { error: "Email or password is incorrect.", email });
    }

    // 2. Verify password.
    try {
      const r = await clerk.users.verifyPassword({ userId: user.id, password });
      if (!r?.verified) {
        return fail(401, { error: "Email or password is incorrect.", email });
      }
    } catch {
      return fail(401, { error: "Email or password is incorrect.", email });
    }

    // 3. Mint a one-time sign-in ticket.
    let ticket: string;
    try {
      const tokenObj = await (clerk as any).signInTokens.createSignInToken({
        userId: user.id,
        expiresInSeconds: 60,
      });
      ticket = tokenObj.token;
    } catch (e: any) {
      console.error("[sign-in] createSignInToken failed", JSON.stringify({ message: e?.message, errors: e?.errors }));
      return fail(500, { error: e?.message ?? "Sign-in failed (ticket).", email });
    }

    // 4. Exchange via FAPI.
    let session: Awaited<ReturnType<typeof fapiExchangeTicket>>;
    try {
      session = await fapiExchangeTicket(publishable, ticket);
    } catch (e: any) {
      console.error("[sign-in] ticket exchange failed", JSON.stringify({ message: e?.message, errors: e?.errors, fapi: e?.fapi }));
      return fail(500, { error: e?.message ?? "Sign-in failed (exchange).", email });
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

    redirect(303, url.searchParams.get("redirect_url") ?? "/app");
  },
};
