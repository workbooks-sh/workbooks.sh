// workbooks.sh edge — Cloudflare fronts the dogfood NEXUS (wb-dogfood.fly.dev), a live
// runtime serving our .work surfaces (lander/docs/blog/toolkits/brand/cloud/...) and their
// own static assets. Unlike the old static site, the nexus serves HTML *and* assets, so the
// edge proxies EVERYTHING to it. The last-published Pages static tree is the FALLBACK if the
// origin errors/is unreachable. x-wb-origin says which plane answered. (Flipped from wb-site.)
const ORIGIN = "https://wb-dogfood.fly.dev";
const ASSET_RE = /\.(css|js|mjs|json|svg|png|jpe?g|gif|webp|ico|woff2?|wasm|mp3|mp4|txt|xml)$/i;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    // Homepage = the lander surface (the dogfood root is a folder-of-workbooks, so `/` would otherwise
    // be the mount index). Served transparently at `/`; the lander's <base href="/lander/"> resolves
    // its own assets.
    const path = url.pathname === "/" ? "/lander/" : url.pathname;
    try {
      const init = {
        method: req.method,
        headers: req.headers,
        redirect: "manual",
        signal: AbortSignal.timeout(15000), // generous: the nexus may resume from suspend
      };
      if (req.method !== "GET" && req.method !== "HEAD") init.body = req.body;

      const res = await fetch(ORIGIN + path + url.search, init);
      if (res.status < 500) {
        const h = new Headers(res.headers);
        h.set("x-wb-origin", "dogfood");
        const loc = h.get("location");
        if (loc && loc.startsWith(ORIGIN)) h.set("location", loc.slice(ORIGIN.length));
        if (ASSET_RE.test(url.pathname) && !h.get("cache-control")) {
          h.set("cache-control", url.search.includes("v=")
            ? "public, max-age=31536000, immutable"
            : "public, max-age=3600, stale-while-revalidate=86400");
        }
        return new Response(res.body, { status: res.status, headers: h });
      }
    } catch (_) { /* origin slow/down — fall through to the static tree */ }

    const edge = await env.ASSETS.fetch(req);
    const h = new Headers(edge.headers);
    h.set("x-wb-origin", "edge-fallback");
    return new Response(edge.body, { status: edge.status, headers: h });
  },
};
