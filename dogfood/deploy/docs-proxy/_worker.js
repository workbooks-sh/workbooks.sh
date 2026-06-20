// docs.workbooks.sh → the dogfood docs, served live by the nexus at wb-dogfood/docs/.
// Retires the old static workbooks-docs Pages build: maps the subdomain root onto the /docs mount
// and rebases the SPA (the one `<base href="/docs/">` → `/`) so the base-aware history router and the
// relative `data-route` links resolve at the subdomain root. Deep URLs (docs.workbooks.sh/preface/…)
// proxy to /docs/preface/… where the nexus serves the SPA shell. Same dogfood content as
// workbooks.sh/docs/ — one source of truth.
const ORIGIN = "https://wb-dogfood.fly.dev";

export default {
  async fetch(req) {
    const url = new URL(req.url);
    const path = "/docs" + (url.pathname === "/" ? "/" : url.pathname);

    const init = {
      method: req.method,
      headers: req.headers,
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
    };
    if (req.method !== "GET" && req.method !== "HEAD") init.body = req.body;

    const res = await fetch(ORIGIN + path + url.search, init);
    const ct = res.headers.get("content-type") || "";

    if (ct.includes("text/html")) {
      const html = (await res.text()).replace('<base href="/docs/">', '<base href="/">');
      const h = new Headers(res.headers);
      h.delete("content-length");
      h.set("x-wb-origin", "dogfood-docs");
      return new Response(html, { status: res.status, headers: h });
    }

    return new Response(res.body, { status: res.status, headers: res.headers });
  },
};
