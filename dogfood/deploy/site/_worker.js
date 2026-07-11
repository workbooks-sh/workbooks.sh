// workbooks.sh edge — Cloudflare fronts the dogfood NEXUS (wb-dogfood.fly.dev), a live
// runtime serving our .work surfaces (lander/docs/blog/toolkits/brand/cloud/...) and their
// own static assets. Unlike the old static site, the nexus serves HTML *and* assets, so the
// edge proxies EVERYTHING to it. The last-published Pages static tree is the FALLBACK if the
// origin errors/is unreachable. x-wb-origin says which plane answered. (Flipped from wb-site.)
//
// EDGE CACHE (wb-jr1py.5): anonymous GETs — HTML included — are cached at the edge so the
// origin pays egress only on the fill, not on every page view (Fly bills $0.02/GB; CF→user
// is free). Dynamic surfaces (/cloud, /api, /ws, /live, /git, auth flows) and any request
// carrying a cookie/authorization header always go to origin. Deploys bump freshness via
// s-maxage TTL now; the purge-on-deploy hook (Nexus.Cloudflare.purge_cache) tightens this.
const ORIGIN = "https://wb-dogfood.fly.dev";
const ASSET_RE = /\.(css|js|mjs|json|svg|png|jpe?g|gif|webp|ico|woff2?|wasm|mp3|mp4|txt|xml)$/i;
const DYNAMIC_RE = /^\/(cloud|api|ws|live|git|sessions|auth|login|logout|oauth)(\/|$)/;
const HTML_EDGE_CACHE = "public, max-age=0, s-maxage=300, stale-while-revalidate=86400";

// Legal pages are served DIRECTLY from the edge static tree (not the nexus origin) —
// the fly image build has a stale-COPY gremlin that won't pick up new lander surfaces,
// so these authoritative pages live on Cloudflare Pages where a deploy is reliable.
const LEGAL = new Set(["/privacy", "/terms", "/data-deletion"]);

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const clean = url.pathname.replace(/\/$/, "");
    if (LEGAL.has(clean)) {
      // Pages serves the static tree with native directory-index (/privacy →
      // /privacy/index.html). Fetch it straight from the edge assets.
      const asset = await env.ASSETS.fetch(new URL(clean + "/index.html", url).toString());
      const h = new Headers(asset.headers);
      h.set("x-wb-origin", "edge-legal");
      h.set("content-type", "text/html; charset=utf-8");
      return new Response(asset.body, { status: asset.status, headers: h });
    }
    // Homepage = the lander surface (the dogfood root is a folder-of-workbooks, so `/` would otherwise
    // be the mount index). Served transparently at `/`; the lander's <base href="/lander/"> resolves
    // its own assets.
    const path = url.pathname === "/" ? "/lander/" : url.pathname;

    // Cacheable = anonymous GET off the dynamic surfaces. A cookie/authorization header means a
    // session-varying response — never serve or fill the shared cache with it.
    const cacheable =
      req.method === "GET" &&
      !req.headers.has("cookie") &&
      !req.headers.has("authorization") &&
      !DYNAMIC_RE.test(url.pathname);
    const cache = caches.default;
    const cacheKey = new Request(ORIGIN + path + url.search, { method: "GET" });

    if (cacheable) {
      const hit = await cache.match(cacheKey);
      if (hit) {
        const h = new Headers(hit.headers);
        h.set("x-wb-cache", "hit");
        return new Response(hit.body, { status: hit.status, headers: h });
      }
    }

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

        // Fill the edge cache: 200, anonymous, no session being set. HTML gets an edge-only TTL
        // (browser always revalidates; the edge serves for s-maxage, then refills from origin).
        if (cacheable && res.status === 200 && !h.has("set-cookie")) {
          if (!ASSET_RE.test(url.pathname) && !h.get("cache-control")) {
            h.set("cache-control", HTML_EDGE_CACHE);
          }
          h.set("x-wb-cache", "fill");
          const body = await res.arrayBuffer();
          const out = new Response(body, { status: res.status, headers: h });
          ctx.waitUntil(cache.put(cacheKey, out.clone()));
          return out;
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
