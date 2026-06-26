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

export const api = {
  // control plane
  plat: (path, opts) => request('/api/platform' + path, opts),
  // serving nexus / relative
  rt: (path, opts) => request(path, opts),

  // identity + auth (the SPA owns these screens; the backend sets/clears the cookie)
  me: () => request('/api/platform/me'),
  login: (email, password) => request('/auth/login', json('POST', { email, password })),
  signup: (email, password, name) => request('/auth/signup', json('POST', { email, password, name })),
  logout: () => request('/auth/logout', json('POST')),
  forgot: (email) => request('/auth/forgot', json('POST', { email })),
  onboard: (payload) => request('/api/platform/onboard', json('POST', payload)),

  get: (path) => request(path),
  post: (path, body) => request(path, json('POST', body))
}
