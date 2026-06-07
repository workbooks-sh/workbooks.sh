// Client-side mirror of the server's session JWT. Populated by /app/+layout
// from event.locals.auth.sessionToken (which hooks.server.ts pulled from the
// __session cookie). $lib/api.ts reads this when calling /v1/auth/portal/*.
//
// This replaces the previous clerk-browser singleton + clerk.session.getToken()
// dance. The browser never loads Clerk JS now; we just plumb the JWT through.

import { writable } from "svelte/store";

export const sessionJwt = writable<string | null>(null);

let cached: string | null = null;
sessionJwt.subscribe((v) => (cached = v));

export function getSessionJwt(): string | null {
  return cached;
}
