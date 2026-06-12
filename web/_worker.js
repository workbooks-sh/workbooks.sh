// workbooks.sh edge — Cloudflare fronts the fly origin (wb-site.fly.dev, the
// site's root data source). Pages' own static copy is the FALLBACK: if the
// origin errors or is unreachable, serve the last-published static tree.
// x-wb-origin header says which plane answered. Epic wb-gnzy.
const ASSET_RE = /\.(css|js|mjs|json|svg|png|jpe?g|gif|webp|ico|woff2?|wasm|mp3|org|txt|xml)$/i;

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    // Static assets NEVER detour through the origin: serve straight from the
    // Pages copy with real edge caching. The fly origin is the CMS surface
    // for PAGES; making a 2KB icon pay a cross-continent round trip per view
    // was the whole reason lessons loaded in seconds instead of millis.
    if (ASSET_RE.test(url.pathname)) {
      const r = await env.ASSETS.fetch(req);
      const h = new Headers(r.headers);
      h.set("x-wb-origin", "edge-asset");
      // versioned URLs are immutable; the rest revalidate hourly
      h.set("cache-control", url.search.includes("v=")
        ? "public, max-age=31536000, immutable"
        : "public, max-age=3600, stale-while-revalidate=86400");
      return new Response(r.body, { status: r.status, headers: h });
    }

    // Pages/HTML: the edge copy serves FIRST (instant, globally cached);
    // the fly origin is the fallback for routes the static tree doesn't
    // know — the CMS surface — behind a hard timeout so a slow origin can
    // never hold a page render hostage (it was measured holding one for 5s).
    const edge = await env.ASSETS.fetch(req);
    if (edge.status < 404) {
      const h = new Headers(edge.headers);
      h.set("x-wb-origin", "edge");
      if (!h.get("cache-control")) h.set("cache-control", "public, max-age=300, stale-while-revalidate=3600");
      return new Response(edge.body, { status: edge.status, headers: h });
    }

    try {
      const res = await fetch("https://wb-site.fly.dev" + url.pathname + url.search, {
        method: req.method,
        headers: { accept: req.headers.get("accept") || "*/*", "user-agent": "wb-edge" },
        redirect: "manual",
        signal: AbortSignal.timeout(2500),
      });
      if (res.status < 404 || res.status === 304) {
        const h = new Headers(res.headers);
        h.set("x-wb-origin", "fly");
        const loc = h.get("location");
        if (loc && loc.startsWith("https://wb-site.fly.dev")) {
          h.set("location", loc.replace("https://wb-site.fly.dev", ""));
        }
        return new Response(res.body, { status: res.status, headers: h });
      }
    } catch (_) { /* origin slow or down — the edge 404 stands */ }
    const h = new Headers(edge.headers);
    h.set("x-wb-origin", "edge-404");
    return new Response(edge.body, { status: edge.status, headers: h });
  },
};
