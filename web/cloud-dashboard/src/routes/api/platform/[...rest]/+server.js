import { error, json } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

// ── Platform API proxy ───────────────────────────────────────────────────────
// The browser calls SAME-ORIGIN `/api/platform/*`; this server route forwards to the
// runtime control-plane (PCP) with the signed-in user's WorkOS access token as the
// Bearer. The runtime's OIDC verifier validates it against WorkOS' JWKS and maps the
// token's org → tenant, so every call is org-scoped end-to-end. The access token
// never reaches the browser, and there is no cross-origin call from the client.
//
// Configure with WB_RUNTIME_URL (the control-plane base, e.g. https://nexus.workbooks.cloud).
// UNSET → the dashboard shows honest empty states instead of fabricated data (502 here,
// which the api.js layer turns into an empty list / zero rollup).

const RUNTIME = (env.WB_RUNTIME_URL || '').replace(/\/$/, '');

async function proxy(event) {
  const { request, locals, params, url } = event;

  if (!RUNTIME) {
    // No runtime connected yet — be honest, not fake. api.js treats this as empty.
    throw error(502, 'no runtime connected (set WB_RUNTIME_URL)');
  }

  const token = locals.auth?.accessToken;
  if (!token) throw error(401, 'not authenticated');

  const target = `${RUNTIME}/api/platform/${params.rest}${url.search}`;
  const headers = {
    authorization: `Bearer ${token}`,
    accept: 'application/json'
  };

  let body;
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    body = await request.text();
    headers['content-type'] = 'application/json';
  }

  const res = await fetch(target, { method: request.method, headers, body });
  const text = await res.text();

  return new Response(text, {
    status: res.status,
    headers: { 'content-type': res.headers.get('content-type') || 'application/json' }
  });
}

export const GET = proxy;
export const POST = proxy;
export const DELETE = proxy;
export const PUT = proxy;
