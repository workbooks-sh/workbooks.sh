// app.workbooks.sh → the cloud dashboard served by the nexus (wb-dogfood). Replaces the retired
// SvelteKit app: a passthrough proxy where `/` lands on the .work dashboard (/cloud/), and /login,
// /auth/*, /api/platform/* all forward straight through (native session auth — no WorkOS). One nexus,
// everything in the dogfood pile.
const ORIGIN = "https://wb-dogfood.fly.dev";
export default {
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname === "/" ? "/cloud/" : url.pathname;
    const init = { method: req.method, headers: req.headers, redirect: "manual", signal: AbortSignal.timeout(15000) };
    if (req.method !== "GET" && req.method !== "HEAD") init.body = req.body;
    const res = await fetch(ORIGIN + path + url.search, init);
    const h = new Headers(res.headers);
    const loc = h.get("location");
    if (loc && loc.startsWith(ORIGIN)) h.set("location", loc.slice(ORIGIN.length));
    h.set("x-wb-origin", "dogfood-cloud");
    return new Response(res.body, { status: res.status, headers: h });
  },
};
