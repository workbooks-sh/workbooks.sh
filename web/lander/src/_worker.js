// CF Pages worker entry for the lander.
//
// Sole job: transparently proxy /w/<id> requests to the viewer Pages
// project so workbooks.sh/w/<id> serves viewer content under the
// canonical workbooks.sh hostname. Everything else falls through to
// normal static-asset serving.
//
// CF Pages' _redirects file only rewrites WITHIN the project — cross-
// origin destinations turn into 3xx redirects, which would change the
// URL in the recipient's browser. A worker fetch keeps the URL stable.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // /w/* — viewer pages (legacy RID-addressed reader).
    // /r/* — viewer Live URL runner (wb-v9ys). workbooks.sh/r/<slug>
    //   serves the full-bleed runner with rooms / comments / presence.
    //   Forms POST back to /r/<slug>?/comment + ?/unlock, so non-GET
    //   methods must proxy too (the upstreamReq below already forwards
    //   method + body).
    // /_app/* — viewer's bundled JS/CSS/assets. SvelteKit emits
    //   absolute paths like /_app/immutable/entry/start.<hash>.js, so
    //   they must resolve under the same hostname as the page that
    //   imports them. Without this rule the assets hit the lander and
    //   get back text/html, failing strict-MIME checks in the browser.
    // /auth/* — viewer-side broker_code → cookie exchange. Must run on
    //   the same hostname as /w/ so the session cookie scopes match.
    // /api/* — viewer-side same-origin proxies (artifact streaming,
    //   etc). Without this they hit the lander's static assets and
    //   return its index.html instead of the workbook bytes.
    // /docs/* — documentation site proxied from workbooks-docs.pages.dev
    // so workbooks.sh/docs/* serves docs under the canonical hostname.
    if (url.pathname === "/docs" || url.pathname.startsWith("/docs/")) {
      const docPath = url.pathname === "/docs" ? "/" : url.pathname.slice("/docs".length);
      const target = new URL(docPath + url.search, "https://workbooks-docs.pages.dev");
      const upstreamHeaders = new Headers(request.headers);
      upstreamHeaders.delete("host");
      // redirect:"follow" — Cloudflare Pages 308-redirects `/foo.html` → clean-URL
      // `/foo` (no extension). With "manual" that bare, /docs-less redirect leaked to
      // the browser and dropped the /docs prefix, landing on the lander. Following it
      // server-side resolves against the docs origin and returns the real page.
      return fetch(new Request(target.toString(), {
        method: request.method,
        headers: upstreamHeaders,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "follow",
      }));
    }

    // ROOT — workbooks.sh IS a live workbook (lander-live, bd wb-5vm). The
    // homepage and its change-feed are served BY the Workbooks runtime on Fly,
    // fronted (and edge-cached) through Cloudflare so a cold/asleep box never
    // means a slow or down homepage. The page is a self-contained workbook
    // (CSS/JS/demos inlined), so only the document + /_changes proxy here.
    if (url.pathname === "/" || url.pathname === "/_changes") {
      const flyPath = url.pathname === "/" ? "/w/wb-lander-live" : "/_changes";
      const target = new URL(flyPath + url.search, "https://wb-lander-live.fly.dev");
      const upstreamHeaders = new Headers(request.headers);
      upstreamHeaders.delete("host");
      // Edge-cache the homepage briefly; the live-poll reloads open tabs when
      // the keeper commits, and new visitors see fresh within the TTL.
      const cacheTtl = url.pathname === "/" ? 60 : 0;
      return fetch(new Request(target.toString(), {
        method: request.method,
        headers: upstreamHeaders,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "follow",
        cf: cacheTtl ? { cacheTtl, cacheEverything: true } : undefined,
      }));
    }

    // /live/* — alias for the living lander (kept for direct access / sharing).
    if (url.pathname === "/live" || url.pathname.startsWith("/live/")) {
      const livePath = url.pathname === "/live" ? "/w/workbooks" : url.pathname.slice("/live".length);
      const target = new URL(livePath + url.search, "https://wb-lander-live.fly.dev");
      const upstreamHeaders = new Headers(request.headers);
      upstreamHeaders.delete("host");
      return fetch(new Request(target.toString(), {
        method: request.method,
        headers: upstreamHeaders,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "follow",
      }));
    }

    if (
      url.pathname === "/w" ||
      url.pathname.startsWith("/w/") ||
      url.pathname === "/r" ||
      url.pathname.startsWith("/r/") ||
      url.pathname.startsWith("/_app/") ||
      url.pathname.startsWith("/auth/") ||
      url.pathname.startsWith("/api/")
    ) {
      const target = new URL(
        url.pathname + url.search,
        "https://workbooks-viewer.pages.dev",
      );
      // Preserve the original request shape (method, headers, body) so
      // POSTed forms or HEAD checks behave the same as a direct hit.
      // Strip the Host header — CF will set it to the destination.
      const upstreamHeaders = new Headers(request.headers);
      upstreamHeaders.delete("host");
      const upstreamReq = new Request(target.toString(), {
        method: request.method,
        headers: upstreamHeaders,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "manual",
      });
      return fetch(upstreamReq);
    }

    // All other paths: serve from the bundled static assets the way
    // CF Pages would by default.
    return env.ASSETS.fetch(request);
  },
};
