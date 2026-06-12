// workbooks.sh edge — Cloudflare fronts the fly origin (wb-site.fly.dev, the
// site's root data source). Pages' own static copy is the FALLBACK: if the
// origin errors or is unreachable, serve the last-published static tree.
// x-wb-origin header says which plane answered. Epic wb-gnzy.
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      const res = await fetch("https://wb-site.fly.dev" + url.pathname + url.search, {
        method: req.method,
        headers: { accept: req.headers.get("accept") || "*/*" },
        cf: { cacheTtl: 60 },
      });
      if (res.status < 404 || res.status === 304) {
        const h = new Headers(res.headers);
        h.set("x-wb-origin", "fly");
        return new Response(res.body, { status: res.status, headers: h });
      }
    } catch (_) { /* origin down — fall through to static */ }
    const r = await env.ASSETS.fetch(req);
    const h = new Headers(r.headers);
    h.set("x-wb-origin", "pages-fallback");
    return new Response(r.body, { status: r.status, headers: h });
  },
};
