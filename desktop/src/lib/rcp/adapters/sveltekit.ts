// SvelteKit adapter for the RCP RouteGate (sealed-bundle part b). DEPENDENCY-FREE:
// SvelteKit's `redirect`/`error` are INJECTED, so this file imports nothing from
// @sveltejs/kit and works regardless of the installed kit version. A TanStack /
// custom router adapter is the same shape — wire your framework's
// redirect/error/notFound to the matching outcomes.
//
// Usage in a SvelteKit +layout.ts (or +page.ts):
//
//   import { redirect, error } from "@sveltejs/kit";
//   import { RouteGate } from "$lib/rcp/routing";
//   import { svelteKitLoad } from "$lib/rcp/adapters/sveltekit";
//   const gate = new RouteGate(ROUTE_TABLE, rcp);
//   const guarded = svelteKitLoad(gate, { redirect, error, loginPath: "/login" });
//   export const load = ({ url }) => guarded(url.pathname);

import type { RouteGate } from "../routing";

export interface SvelteKitHooks {
  /** SvelteKit's redirect(status, location) — throws. */
  redirect: (status: number, location: string) => never;
  /** SvelteKit's error(status, message) — throws. */
  error: (status: number, message: string) => never;
  /** Where to send unauthenticated callers. */
  loginPath?: string;
}

/** Build a SvelteKit `load`-shaped guard from a RouteGate. Returns the loaded
 *  content for public/gated-allowed routes; throws kit redirect/error otherwise. */
export function svelteKitLoad(gate: RouteGate, hooks: SvelteKitHooks) {
  const login = hooks.loginPath ?? "/login";
  return async (pathname: string): Promise<{ content: unknown }> => {
    const res = await gate.load(pathname);
    switch (res.status) {
      case "public":
        return { content: null };
      case "ok":
        return { content: res.content };
      case "denied":
        // Not authenticated / posture refused → bounce to login (preserve target).
        return hooks.redirect(302, `${login}?next=${encodeURIComponent(pathname)}`);
      case "unavailable":
        return hooks.error(503, "Runtime unavailable");
      case "not_found":
        return hooks.error(404, "Not found");
    }
  };
}
