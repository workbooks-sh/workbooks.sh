import type { PageLoad } from "./$types";

/** Workbook fetch for /w/<rid>.
 *
 *  Production: hits the network-gateway (workbooks-network-gateway on
 *  Fly) which holds a read-only radicle-node and returns the rendered
 *  workbook `.html` bytes for opt-in-public projects.
 *
 *  Phase 5 v1: gateway doesn't exist yet, so we return a sentinel
 *  hardcoded demo workbook (unsigned — the verifier will surface
 *  "unverified"). When the gateway lands (wb-u2o0.6.5), this
 *  function reaches out to it. */
const GATEWAY_URL =
  (import.meta.env as Record<string, string | undefined>)
    ?.PUBLIC_GATEWAY_URL ?? "https://network.workbooks.sh";

/** Same shape as the landing page + the manifest crate. We validate
 *  at the page-load boundary so the rest of the load can trust `rid`
 *  is a well-formed RID — defense in depth even though the template
 *  string in demoWorkbookHtml below is also HTML-escaped. */
const RID_RE = /^rad:z[1-9A-HJ-NP-Za-km-z]{20,}$/;

export const load: PageLoad = async ({ params, fetch }) => {
  const rid = params.rid;

  if (!RID_RE.test(rid)) {
    // SvelteKit returns this as a 404 to the client.
    return {
      rid: "(invalid)",
      html: null,
      source: "gateway" as const,
      error: "Not a valid Radicle RID.",
    };
  }

  try {
    const r = await fetch(`${GATEWAY_URL}/r/by-rid/${encodeURIComponent(rid)}`);
    if (r.ok) {
      const html = await r.text();
      return { rid, html, source: "gateway" as const };
    }
    if (r.status === 404) {
      return {
        rid,
        html: null,
        source: "gateway" as const,
        error: "Gateway returned 404 — RID not on the public catalog.",
      };
    }
    return {
      rid,
      html: null,
      source: "gateway" as const,
      error: `Gateway returned ${r.status}.`,
    };
  } catch {
    // Gateway unreachable (offline, not deployed yet, etc) — fall
    // through to a synthesized demo workbook so the page surface
    // exercises end-to-end.
    return {
      rid,
      html: demoWorkbookHtml(rid),
      source: "demo" as const,
    };
  }
};

/** HTML-escape — even though `rid` is RID_RE-validated above, the
 *  template string is the kind of thing that grows over time; escape
 *  defensively. */
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function demoWorkbookHtml(rid: string): string {
  const safe = escapeHtml(rid);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Demo Workbook — ${safe}</title>
<style>
  body { font-family: -apple-system, sans-serif; max-width: 640px; margin: 60px auto; padding: 0 20px; color: #222; }
  h1 { margin-top: 0; }
  .note { padding: 14px 18px; background: #fef9e7; border-left: 3px solid #f4d03f; border-radius: 4px; margin: 24px 0; color: #6b5612; font-size: 0.9rem; }
  code { font-family: ui-monospace, monospace; font-size: 0.85rem; background: #f4f4f5; padding: 2px 6px; border-radius: 4px; }
</style>
</head>
<body>
<h1>Demo Workbook</h1>
<p>This is a placeholder workbook served because the network gateway isn't reachable.</p>
<div class="note">
  In production, the gateway would fetch and return the canonical
  the canonical workbook for <code>${safe}</code> from the
  Radicle network.
</div>
<p>Real workbooks ship with a signed C2PA-style manifest that the viewer verifies in your browser.</p>
</body>
</html>`;
}
