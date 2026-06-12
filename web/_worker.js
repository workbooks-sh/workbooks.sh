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

    try {
      const res = await fetch("https://wb-site.fly.dev" + url.pathname + url.search, {
        method: req.method,
        headers: { accept: req.headers.get("accept") || "*/*", "user-agent": "wb-edge" },
        redirect: "manual", // the origin's clean-URL 301s must reach the client
      });
      if (res.status < 404 || res.status === 304) {
        const h = new Headers(res.headers);
        h.set("x-wb-origin", "fly");
        // never leak the fly hostname in redirect targets
        const loc = h.get("location");
        if (loc && loc.startsWith("https://wb-site.fly.dev")) {
          h.set("location", loc.replace("https://wb-site.fly.dev", ""));
        }
        return new Response(res.body, { status: res.status, headers: h });
      }
      var originNote = "origin-status-" + res.status; // wb-q: worker→fly subrequest 404s (empty body) while direct hits 200
    } catch (e) {
      var originNote = "err-" + String(e && e.message).slice(0, 60).replace(/[^\w.-]+/g, "_");
    }
    const r = await env.ASSETS.fetch(req);
    const h = new Headers(r.headers);
    h.set("x-wb-origin", "pages-fallback");
    h.set("x-wb-origin-note", typeof originNote === "string" ? originNote : "none");
    return new Response(r.body, { status: r.status, headers: h });
  },
};
