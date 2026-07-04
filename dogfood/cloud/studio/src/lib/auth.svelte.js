// auth.svelte.js — the session/auth state machine for the SPA shell.
//
// status: 'loading' → checking the session cookie
//         'anon'    → no session: show Login
//         'onboarding' → authenticated but org not set up: show Onboarding
//         'ready'   → authenticated + onboarded: show Studio
//         'demo'    → no runtime reachable: explore the mock demo (the standalone path)
//
// On boot we ask the backend who we are (api.me). 401 → anon. A network error → there's no runtime, so
// we offer the demo path (the SPA still works fully on its mock store). This is the seam that lets the
// SAME build be the live dashboard (with a runtime) and the standalone demo (without one).
import { api, Unauthorized } from './api.js'

export const auth = $state({
  status: 'loading',
  me: null,        // { id, email, name, org, role, onboarded }
  offline: false   // true when no runtime answered — mock-store mode
})

// a valid identity is a JSON object carrying an id — NOT the index.html a static/dev server returns
// for an unknown /api path (which would otherwise look "authenticated"). Guard on the shape.
const isIdentity = (me) => me && typeof me === 'object' && typeof me.id === 'string'

export async function initAuth() {
  try {
    const me = await api.me()
    if (isIdentity(me)) {
      auth.me = me
      auth.status = me.onboarded === false ? 'onboarding' : 'ready'
    } else {
      // a non-identity response means there's no real control plane here — standalone demo
      auth.offline = true
      auth.status = 'anon'
    }
  } catch (e) {
    if (e instanceof Unauthorized) {
      // A LIVE control plane said "not authenticated" → send the user to the standalone, server-rendered
      // /login island (wb-izz8.3): logged-out users don't sit in the SPA's in-bundle login; the island is
      // THE 401 target (unauth-reachable, no SPA bundle). If the redirect can't run (tests / non-browser),
      // fall through to the in-SPA Login. The offline/demo build (network error below) keeps in-SPA login.
      auth.status = 'anon'
      toLogin()
    } else {
      // no runtime reachable — the standalone demo path
      auth.offline = true
      auth.status = 'anon'
    }
  }
}

// Bounce to the server-rendered /login island, preserving the intended destination so /login can return
// the user there after a session issues. No-op off-browser or when already on /login (avoid a loop).
function toLogin() {
  if (typeof location === 'undefined' || location.pathname.startsWith('/login')) return
  const next = encodeURIComponent(location.pathname + location.search)
  location.assign(`/login?next=${next}`)
}

export async function login(email, password) {
  const me = await api.login(email, password)
  auth.me = me?.user || me
  auth.status = auth.me?.onboarded === false ? 'onboarding' : 'ready'
}

export async function signup(email, password, name) {
  const me = await api.signup(email, password, name)
  auth.me = me?.user || me
  auth.status = 'onboarding' // fresh accounts always onboard
}

export async function logout() {
  try { await api.logout() } catch (_) {}
  auth.me = null
  auth.status = 'anon'
}

export function finishOnboarding() {
  if (auth.me) auth.me.onboarded = true
  auth.status = 'ready'
}

// Explore the demo without a backend — used by the standalone build and the login "explore" affordance.
export function enterDemo() {
  auth.me = { id: 'demo', email: 'you@demo', name: 'You', org: 'demo', role: 'owner', onboarded: true }
  auth.offline = true
  auth.status = 'ready'
}
