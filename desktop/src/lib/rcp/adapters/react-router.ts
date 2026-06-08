// React Router v6.4+ (data router) adapter for the RCP RouteGate (rzip part b).
// DEPENDENCY-FREE: React Router's `redirect`/`json` helpers are INJECTED (like
// sveltekit.ts) so this file imports nothing from react-router-dom.
//
// Shape: a data-router `loader({ request })` returns data or RETURNS a Response —
// `redirect(url)` is a 302 Response React Router follows; a thrown Response routes
// to the nearest errorElement. We RETURN redirect for denied, THROW a 404/503
// Response for not_found/unavailable, and return the content otherwise.
//
// Usage:
//   import { redirect } from "react-router-dom";
//   const loader = reactRouterLoader(gate, { redirect, loginPath: "/login" });
//   const router = createBrowserRouter([{ path: "/secret", loader, element: <Secret/> }]);

import type { RouteGate } from "../routing";

export interface ReactRouterHooks {
  /** React Router redirect(url, init?) → a 302 Response the router follows. */
  redirect: (url: string, init?: number | ResponseInit) => Response;
  /** Where to send unauthenticated callers. */
  loginPath?: string;
}

export function reactRouterLoader(gate: RouteGate, hooks: ReactRouterHooks) {
  const login = hooks.loginPath ?? "/login";
  return async ({ request }: { request: Request }): Promise<unknown> => {
    const pathname = new URL(request.url).pathname;
    const res = await gate.load(pathname);
    switch (res.status) {
      case "public":
        return { content: null };
      case "ok":
        return { content: res.content };
      case "denied":
        return hooks.redirect(`${login}?next=${encodeURIComponent(pathname)}`);
      case "unavailable":
        // Thrown Response → nearest errorElement (use useRouteError to read it).
        throw new Response("Runtime unavailable", { status: 503 });
      case "not_found":
        throw new Response("Not found", { status: 404 });
    }
  };
}
