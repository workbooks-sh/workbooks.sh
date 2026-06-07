// Universal hooks. The reroute below lets us host the portal at two URLs
// without doubling the routes:
//
//   brandnana.net/app/keys      → /app/keys                  (no rewrite)
//   app.brandnana.net/keys      → /app/keys                  (reroute prepends /app)
//   app.brandnana.net/          → /app                       (reroute prepends /app)
//   app.brandnana.net/onboard   → /onboard                   (no rewrite — global route)
//
// The /app prefix in the source tree stays canonical; app.brandnana.net is a
// thin alias that drops it for shorter URLs.

import type { Reroute } from "@sveltejs/kit";

// Top-level routes that should NOT be moved under /app when accessed via
// the app.brandnana.net host. These are global pages shared with the
// lander OR routes that have to stay at the root for external callers.
const GLOBAL_ROUTES = new Set([
  "/onboard",
  "/cli/connect",
  "/sign-out",
]);

function isGlobal(path: string): boolean {
  if (path === "/") return false;
  for (const prefix of GLOBAL_ROUTES) {
    if (path === prefix || path.startsWith(prefix + "/")) return true;
  }
  return false;
}

export const reroute: Reroute = ({ url }) => {
  if (url.hostname !== "app.brandnana.net") return;
  if (url.pathname.startsWith("/app")) return;
  if (isGlobal(url.pathname)) return;
  if (url.pathname === "/") return "/app";
  return "/app" + url.pathname;
};
