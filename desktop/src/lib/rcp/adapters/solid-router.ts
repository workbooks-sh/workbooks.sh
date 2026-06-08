// SolidJS Router adapter for the RCP RouteGate (rzip part b). DEPENDENCY-FREE:
// Solid Router's `redirect` (a thrown Response, like React Router's) is INJECTED,
// so this file imports nothing from @solidjs/router.
//
// Shape: a Solid Router route `load` (preload) function runs ahead of render and
// may return data or throw `redirect(path)` to divert. We THROW redirect for
// denied, throw a Response for not_found/unavailable, and return content otherwise.
// (Solid's createAsync/cache wraps the returned promise; this stays cache-agnostic.)
//
// Usage:
//   import { redirect } from "@solidjs/router";
//   const load = solidLoad(gate, { redirect, loginPath: "/login" });
//   <Route path="/secret" component={Secret} load={({ location }) => load(location.pathname)} />

import type { RouteGate } from "../routing";

export interface SolidRouterHooks {
  /** Solid Router redirect(path, init?) — throws a Response to divert. */
  redirect: (path: string, init?: number | ResponseInit) => never;
  /** Where to send unauthenticated callers. */
  loginPath?: string;
}

export function solidLoad(gate: RouteGate, hooks: SolidRouterHooks) {
  const login = hooks.loginPath ?? "/login";
  return async (pathname: string): Promise<{ content: unknown }> => {
    const res = await gate.load(pathname);
    switch (res.status) {
      case "public":
        return { content: null };
      case "ok":
        return { content: res.content };
      case "denied":
        return hooks.redirect(`${login}?next=${encodeURIComponent(pathname)}`);
      case "unavailable":
        throw new Response("Runtime unavailable", { status: 503 });
      case "not_found":
        throw new Response("Not found", { status: 404 });
    }
  };
}
