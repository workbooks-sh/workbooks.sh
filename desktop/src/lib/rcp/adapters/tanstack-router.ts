// TanStack Router adapter for the RCP RouteGate (rzip part b). DEPENDENCY-FREE:
// TanStack's `redirect`/`notFound` throwables are INJECTED (like sveltekit.ts),
// so this file imports nothing from @tanstack/router and works across versions.
//
// Shape: TanStack route `loader`/`beforeLoad` functions run during navigation and
// may THROW redirect()/notFound() to divert. We map a RouteGate.load outcome onto
// those throwables and return the loaded content for the allowed/public cases.
//
// Usage in a route definition:
//   import { redirect, notFound } from "@tanstack/react-router";
//   const guard = tanstackLoader(gate, { redirect, notFound, loginPath: "/login" });
//   export const Route = createFileRoute("/secret")({ loader: ({ location }) => guard(location.pathname) });

import type { RouteGate } from "../routing";

export interface TanStackHooks {
  /** TanStack redirect({ to }) — throws to divert navigation. */
  redirect: (opts: { to: string; search?: Record<string, unknown> }) => never;
  /** TanStack notFound() — throws to render the notFound boundary. */
  notFound: () => never;
  /** Where to send unauthenticated callers. */
  loginPath?: string;
  /** Optional error sink for unavailable runtime; defaults to throwing Error. */
  onUnavailable?: () => never;
}

export function tanstackLoader(gate: RouteGate, hooks: TanStackHooks) {
  const login = hooks.loginPath ?? "/login";
  return async (pathname: string): Promise<{ content: unknown }> => {
    const res = await gate.load(pathname);
    switch (res.status) {
      case "public":
        return { content: null };
      case "ok":
        return { content: res.content };
      case "denied":
        return hooks.redirect({ to: login, search: { next: pathname } });
      case "unavailable":
        if (hooks.onUnavailable) return hooks.onUnavailable();
        throw new Error("Runtime unavailable");
      case "not_found":
        return hooks.notFound();
    }
  };
}
