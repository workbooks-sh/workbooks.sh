// The DESKTOP sign-in broker — server-side helpers shared by the three loopback
// endpoints (/v1/auth/authorize, /v1/auth/loopback, /v1/auth/exchange). A native app
// can't hold the WorkOS secret, so the dashboard (which already holds it) runs the
// loopback+PKCE flow on its behalf against the SAME WorkOS app the web login uses.
//
// This is the one auth front door (app.workbooks.sh) for both web and desktop. The
// short-lived flow state (state ids, one-time codes) lives in Cloudflare KV because
// Pages Functions are stateless. Security floors: loopback-only redirect (no open
// redirector), S256 PKCE on exchange, one-time + short-TTL codes, org_<id>-only.

import { WorkOS } from '@workos-inc/node';

export const STATE_TTL = 1800; // generous — a new user may sign up + onboard mid-flow
export const CODE_TTL = 300;

const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

export function randomToken() {
  const a = new Uint8Array(32);
  crypto.getRandomValues(a);
  return b64url(a);
}

// Only a loopback redirect — the broker must never bounce a code to an arbitrary host.
export function isLoopback(uri) {
  try {
    const u = new URL(uri);
    return u.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]', '::1'].includes(u.hostname);
  } catch {
    return false;
  }
}

export const validChallenge = (c) =>
  typeof c === 'string' && c.length >= 16 && c.length <= 256 && /^[A-Za-z0-9_-]+$/.test(c);

// A WorkOS org id (or absent, for a personal session) — so nothing but an id reaches
// the upstream authorize query.
export const validOrg = (o) => !o || (typeof o === 'string' && o.length <= 80 && /^org_[A-Za-z0-9]+$/.test(o));

export async function pkceOk(verifier, challenge) {
  if (typeof verifier !== 'string' || !verifier) return false;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return b64url(digest) === challenge;
}

// The access token's `exp` (unix seconds), peeked without verifying — WorkOS just
// minted it over TLS. 0 if unreadable.
export function jwtExp(token) {
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return Number(JSON.parse(atob(part)).exp) || 0;
  } catch {
    return 0;
  }
}

export const workos = (env) => new WorkOS(env.WORKOS_API_KEY);

// The desktop loopback callback on THIS host (must be a registered WorkOS redirect).
export const loopbackCallback = (requestUrl) => `${new URL(requestUrl).origin}/v1/auth/loopback`;

// The desktop's StoredSession (see desktop/src-tauri/src/network.rs).
export function storedSession({ user, organizationId, accessToken }) {
  const name = [user.firstName, user.lastName].filter(Boolean).join(' ');
  return {
    bearer: accessToken,
    expires_at: jwtExp(accessToken),
    sub: user.id || '',
    email: user.email || '',
    email_verified: user.emailVerified === true,
    organization_id: organizationId || null,
    display_name: name || null,
    picture_url: user.profilePictureUrl || null
  };
}

// Build StoredSession from an AuthKit server session (the CONSENT path — the user is
// already signed into the dashboard, so we mint from that session with no WorkOS
// round-trip). `auth` is event.locals.auth ({ user, accessToken, organizationId }).
export function storedSessionFromAuth(auth) {
  return storedSession({
    user: auth?.user || {},
    organizationId: auth?.organizationId || null,
    accessToken: auth?.accessToken || ''
  });
}

// KV is required (stateless Functions). Throws a clear error if the binding is missing
// so a misconfigured deploy fails loud, not silent.
export function authKv(platform) {
  const kv = platform?.env?.AUTH_KV;
  if (!kv) throw new Error('AUTH_KV binding missing (Cloudflare KV not configured)');
  return kv;
}
