// autopoet.app edge worker: apex canonicalization + security/caching headers.
// All content is static, served from ./public via the ASSETS binding.

const LONG_CACHE = /\.(svg|png|ico|woff2?|webp|jpg)$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname === "www.autopoet.app") {
      url.hostname = "autopoet.app";
      return Response.redirect(url.toString(), 301);
    }

    const res = await env.ASSETS.fetch(request);
    const headers = new Headers(res.headers);
    headers.set("X-Content-Type-Options", "nosniff");
    headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
    headers.set("X-Frame-Options", "DENY");
    if (LONG_CACHE.test(url.pathname)) {
      headers.set("Cache-Control", "public, max-age=31536000, immutable");
    } else {
      headers.set("Cache-Control", "public, max-age=300, stale-while-revalidate=86400");
    }
    return new Response(res.body, { status: res.status, headers });
  },
};
