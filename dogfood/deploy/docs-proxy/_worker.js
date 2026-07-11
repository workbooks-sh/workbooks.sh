// docs.workbooks.sh → the dogfood docs, served live by the nexus at wb-dogfood/docs/.
// Retires the old static workbooks-docs Pages build: maps the subdomain root onto the /docs mount
// and rebases the SPA (the one `<base href="/docs/">` → `/`) so the base-aware history router and the
// relative `data-route` links resolve at the subdomain root. Deep URLs (docs.workbooks.sh/preface/…)
// proxy to /docs/preface/… where the nexus serves the SPA shell. Same dogfood content as
// workbooks.sh/docs/ — one source of truth.
//
// EDGE CACHE (wb-jr1py.5): docs are static-per-deploy — anonymous GETs (the TRANSFORMED response,
// base-rebased HTML included) are cached at the edge so the origin pays only the fill.
const ORIGIN = "https://wb-dogfood.fly.dev";
const HTML_EDGE_CACHE = "public, max-age=0, s-maxage=300, stale-while-revalidate=86400";

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const path = "/docs" + (url.pathname === "/" ? "/" : url.pathname);

    const cacheable =
      req.method === "GET" && !req.headers.has("cookie") && !req.headers.has("authorization");
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

    const init = {
      method: req.method,
      headers: req.headers,
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
    };
    if (req.method !== "GET" && req.method !== "HEAD") init.body = req.body;

    const res = await fetch(ORIGIN + path + url.search, init);
    const ct = res.headers.get("content-type") || "";
    const fill = cacheable && res.status === 200 && !res.headers.has("set-cookie");

    if (ct.includes("text/html")) {
      const html = (await res.text()).replace('<base href="/docs/">', '<base href="/">');
      const h = new Headers(res.headers);
      h.delete("content-length");
      h.set("x-wb-origin", "dogfood-docs");
      if (fill) {
        h.set("cache-control", HTML_EDGE_CACHE);
        h.set("x-wb-cache", "fill");
        const out = new Response(html, { status: res.status, headers: h });
        ctx.waitUntil(cache.put(cacheKey, out.clone()));
        return out;
      }
      return new Response(html, { status: res.status, headers: h });
    }

    if (fill) {
      const h = new Headers(res.headers);
      if (!h.get("cache-control")) h.set("cache-control", HTML_EDGE_CACHE);
      h.set("x-wb-cache", "fill");
      const body = await res.arrayBuffer();
      const out = new Response(body, { status: res.status, headers: h });
      ctx.waitUntil(cache.put(cacheKey, out.clone()));
      return out;
    }

    return new Response(res.body, { status: res.status, headers: res.headers });
  },
};
