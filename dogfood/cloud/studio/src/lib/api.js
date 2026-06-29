// api.js — the framework-free fetch client for the real cloud backend (ports app.js WB.api/plat/rt).
//
// Two endpoint families, same as the legacy dashboard:
//   plat(path)  → /api/platform/*   (control plane: nexuses, tokens, workspaces, usage, env)
//   rt(path)    → relative           (the serving nexus: /cloud/*, /auth/*, history, drafts)
// All requests carry the session cookie (credentials:'same-origin'). A 401 throws Unauthorized so the
// auth store can show the login screen — the SPA owns its own login view rather than hard-redirecting.
//
// Graceful fallback: when there is NO runtime (standalone demo / dev), fetches reject; callers treat
// that as "offline" and fall back to the mock store, so the demo still runs with zero backend.

export class Unauthorized extends Error {
  constructor() { super('unauthorized'); this.unauthorized = true }
}

async function request(url, opts = {}) {
  const res = await fetch(url, { credentials: 'same-origin', ...opts })
  if (res.status === 401) throw new Unauthorized()
  if (res.status === 204) return null
  if (!res.ok) throw new Error(`${opts.method || 'GET'} ${url} → ${res.status}`)
  const ct = res.headers.get('content-type') || ''
  return ct.includes('application/json') ? res.json() : res.text()
}

const json = (method, body) => ({
  method,
  headers: { 'content-type': 'application/json' },
  body: body == null ? undefined : JSON.stringify(body)
})

// mutate — the WRITE path for admin/control-plane actions. Three-way result, unlike the throw-or-body read
// path: (a) ok → returns the body (which may be {ok:true} / {url} / {pending:true}); (b) error → throws an
// Error whose .message is the REAL backend string (data.error/message), .status the code, so the UI toast
// shows what actually went wrong instead of a generic "→ 400"; (c) {pending:true} (HTTP 200, e.g. Polar off)
// passes straight through as a normal result. Carries `X-Requested-With: studio` as CSRF defense-in-depth
// (a non-simple header a cross-site form can't set), on top of the SameSite session cookie.
async function mutate(url, method, body) {
  const res = await fetch(url, {
    method,
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json', 'x-requested-with': 'studio' },
    body: body == null ? undefined : JSON.stringify(body)
  })
  if (res.status === 401) throw new Unauthorized()
  const ct = res.headers.get('content-type') || ''
  const data = res.status === 204 ? null : ct.includes('application/json') ? await res.json().catch(() => null) : await res.text()
  if (!res.ok) {
    const e = new Error((data && (data.error || data.message)) || `${method} ${url} → ${res.status}`)
    e.status = res.status
    throw e
  }
  return data
}

export const api = {
  // control plane
  plat: (path, opts) => request('/api/platform' + path, opts),
  // serving nexus / relative
  rt: (path, opts) => request(path, opts),

  // identity + auth (the SPA owns these screens; the backend sets/clears the cookie).
  // The nexus /api/platform/me returns a NESTED shape { user:{id,name,email}, active_org, orgs, role,
  // roles }; the SPA shell expects a FLAT identity { id, email, name, org, role, onboarded }. Adapt here
  // so isIdentity() passes and the session is recognized. onboarded ⇐ has an active org. A non-identity
  // response (e.g. index.html on a static host) passes through so isIdentity() correctly rejects it.
  me: async () => {
    const r = await request('/api/platform/me')
    if (!r || typeof r !== 'object' || !r.user) return r
    const u = r.user
    return { id: u.id, email: u.email || '', name: u.name || '', avatar: u.avatar || u.avatar_url || '',
             org: r.active_org || null, orgs: r.orgs || [], role: r.role || 'viewer', roles: r.roles || [], onboarded: !!r.active_org }
  },
  login: (email, password) => request('/auth/login', json('POST', { email, password })),
  signup: (email, password, name) => request('/auth/signup', json('POST', { email, password, name })),
  logout: () => request('/auth/logout', json('POST')),
  forgot: (email) => request('/auth/forgot', json('POST', { email })),
  onboard: (payload) => request('/api/platform/onboard', json('POST', payload)),

  get: (path) => request(path),
  post: (path, body) => request(path, json('POST', body)),

  // control-plane + cloud WRITE helpers (3-way result, CSRF header) — the admin console's mutation surface
  platPost: (path, body) => mutate('/api/platform' + path, 'POST', body),
  platPatch: (path, body) => mutate('/api/platform' + path, 'PATCH', body),
  platDelete: (path, body) => mutate('/api/platform' + path, 'DELETE', body),
  cloudPost: (path, body) => mutate(path, 'POST', body)
}
