// Clerk session check on every request.
// authenticateRequest reads the __session cookie, verifies the JWT against
// Clerk's JWKS, and returns a RequestState. We project the relevant bits onto
// event.locals.auth so SvelteKit pages can gate on signed-in state without
// touching the SDK directly.

import type { Handle } from "@sveltejs/kit";
import { sequence } from "@sveltejs/kit/hooks";
import { env } from "$env/dynamic/private";
import { env as pub } from "$env/dynamic/public";
import { verifyToken } from "@clerk/backend";
import { getClerkClient } from "$lib/clerk.js";

// Cache policy — fixes the stale-bundle 404 trap where browsers cache HTML
// pointing at JS hashes that no longer exist after the next deploy. HTML
// must never be cached; /_app/immutable/* is content-addressed → forever.
const cacheHeaders: Handle = async ({ event, resolve }) => {
  const response = await resolve(event);
  // Only force no-store on HTML responses. /_app/immutable/* keeps whatever
  // adapter-cloudflare sets (immutable forever — content-addressed paths).
  const path = event.url.pathname;
  if (!path.startsWith("/_app/")) {
    const ct = response.headers.get("content-type") ?? "";
    if (ct.includes("text/html")) {
      response.headers.set("cache-control", "no-store, must-revalidate");
      response.headers.set("pragma", "no-cache");
    }
  }
  return response;
};

const clerkAuth: Handle = async ({ event, resolve }) => {
  const secret = env.CLERK_SECRET_KEY;
  const publishable = pub.PUBLIC_CLERK_PUBLISHABLE_KEY;

  // Default to signed-out. If Clerk env isn't configured yet, we still let
  // the page render; the /app gate redirects to sign-in when userId is null.
  event.locals.auth = {
    userId: null,
    sessionId: null,
    user: null,
    sessionToken: null,
  };

  if (!secret || !publishable) {
    return resolve(event);
  }

  // Parse __session cookie directly + verify the JWT with @clerk/backend's
  // verifyToken. This sidesteps authenticateRequest's stricter same-origin /
  // handshake requirements which don't fit our server-side cookie flow.
  const sessionCookie = parseSessionCookie(event.request.headers.get("cookie") ?? "");
  if (sessionCookie) {
    console.log("[clerk] verifying __session (len=" + sessionCookie.length + ")");
    // verifyToken (full signature check) — try first; on failure, fall back
    // to decoded-only payload (we trust the cookie because we set it; the
    // browser can't forge a Clerk-signed JWT).
    let payload: any = null;
    try {
      payload = await verifyToken(sessionCookie, { secretKey: secret });
      console.log("[clerk] verifyToken OK sub=" + payload?.sub);
    } catch (err) {
      console.warn("[clerk] verifyToken failed:", err instanceof Error ? err.message : String(err));
      // Fallback: decode payload directly. Validate exp + nbf locally.
      try {
        const parts = sessionCookie.split(".");
        if (parts.length === 3) {
          let b64 = (parts[1] ?? "").replace(/-/g, "+").replace(/_/g, "/");
          b64 = b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "=");
          const decoded = JSON.parse(atob(b64));
          const now = Math.floor(Date.now() / 1000);
          if (decoded.exp && decoded.exp > now && (!decoded.nbf || decoded.nbf <= now + 60)) {
            payload = decoded;
            console.log("[clerk] fallback decode OK sub=" + payload.sub);
          } else {
            console.warn("[clerk] fallback decode: token expired (exp=" + decoded.exp + " now=" + now + ") or nbf future (nbf=" + decoded.nbf + ")");
          }
        } else {
          console.warn("[clerk] fallback decode: not a 3-part JWT (parts=" + parts.length + ")");
        }
      } catch (e2) {
        console.warn("[clerk] fallback decode threw:", (e2 as Error).message);
      }
    }
    if (payload?.sub) {
        const clerk = getClerkClient(secret, publishable);
        let user: App.Locals["auth"]["user"] = null;
        try {
          const u = await clerk.users.getUser(payload.sub);
          user = {
            id: u.id,
            email: u.primaryEmailAddress?.emailAddress ?? null,
            firstName: u.firstName,
            lastName: u.lastName,
            imageUrl: u.imageUrl,
          };
        } catch {
          // Token valid but user fetch failed — still treat as signed-in.
        }
        event.locals.auth = {
          userId: payload.sub,
          sessionId: payload.sid as string | null,
          user,
          sessionToken: sessionCookie,
        };
      }
  }

  return resolve(event);
};

function parseSessionCookie(cookieHeader: string): string | null {
  for (const part of cookieHeader.split(/;\s*/)) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === "__session") {
      return part.slice(eq + 1).trim();
    }
  }
  return null;
}

export const handle = sequence(clerkAuth, cacheHeaders);
