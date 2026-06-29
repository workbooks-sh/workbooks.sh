// admin.js — the DEFAULT, undeletable admin pages every nexus/org gets (nexus-wide operations, admin role).
// Each maps to a real control-plane endpoint. Synthesized client-side into the Admin workspace as system
// surfaces (system:true, deletable:false) until the control plane provisions them per-org (batched rebuild).
// Live vs offline (demo fixtures) — same two-mode pattern as the rest.
import { api } from './api.js'

// page key → { name, icon } for the synthetic Admin surfaces (Fleet removed — we manage the machines).
export const ADMIN_PAGES = [
  { page: 'members', name: 'Members', icon: 'group' },
  { page: 'tokens', name: 'API Tokens', icon: 'terminal' },
  { page: 'billing', name: 'Billing', icon: 'credit-card' },
  { page: 'usage', name: 'Usage', icon: 'reports' },
  { page: 'domains', name: 'Domains', icon: 'globe' },
  { page: 'secrets', name: 'Secrets & Env', icon: 'key' },
  { page: 'audit', name: 'Audit Log', icon: 'activity' },
  { page: 'profile', name: 'Profile & Org', icon: 'user' },
  { page: 'security', name: 'Security', icon: 'lock' },
  { page: 'visibility', name: 'Visibility', icon: 'eye' },
  { page: 'integrations', name: 'Integrations', icon: 'git-fork' },
  { page: 'schedules', name: 'Schedules', icon: 'timer' },
  { page: 'danger', name: 'Danger Zone', icon: 'warning-triangle' }
]

// ── write actions (real control-plane endpoints; the UI wraps these in runAction for toast+rollback) ──
export const inviteMember = (email, role) => api.platPost('/members/invite', { email, role })
export const setMemberRole = (id, role) => api.cloudPost('/cloud/members/role', { id, role }) // server.work wrapper (PATCH gap)
export const removeMember = (id) => api.platDelete('/members/' + encodeURIComponent(id))
export const revokeInvite = (id) => api.platPost('/invitations/' + encodeURIComponent(id) + '/revoke')

// secrets/env — write-only posture: add, rotate (replace value), delete; never read back in the list
export const addSecret = (name, value, scope) => api.platPost('/env', { name, value, scope })
export const rotateSecret = (id, value) => api.platPatch('/env/' + encodeURIComponent(id), { value })
export const deleteSecret = (id) => api.platDelete('/env/' + encodeURIComponent(id))

// domains — add (returns DNS challenge), verify (live DNS+cert), remove
export const addDomain = (host) => api.platPost('/domains', { host })
export const verifyDomain = (id) => api.platPost('/domains/' + encodeURIComponent(id) + '/verify')
export const removeDomain = (id) => api.platDelete('/domains/' + encodeURIComponent(id))

// billing/usage actions
export const changePlan = (tier) => api.cloudPost('/cloud/billing/checkout', { tier })
export const topUp = (amount) => api.cloudPost('/cloud/inference/topup', { amount })
export const saveCaps = (cfg) => api.cloudPost('/cloud/inference/config', cfg)
export const wakeNexus = (id) => api.platPost('/nexuses/' + encodeURIComponent(id) + '/wake')
export const sleepNexus = (id) => api.platPost('/nexuses/' + encodeURIComponent(id) + '/sleep')

// API tokens (PATs) — mint (value returned ONCE), revoke
export const mintToken = (name, role) => api.platPost('/tokens', { name, role })
export const revokeToken = (id) => api.platDelete('/tokens/' + encodeURIComponent(id))

// profile / security / visibility / schedules / integrations / danger
export const saveProfile = (p) => api.cloudPost('/cloud/profile', p)
export const revokeKey = (id) => api.cloudPost('/cloud/keys/revoke', { id })
export const setVisibility = (id, state) => api.cloudPost('/cloud/visibility', { id, state })
export const cancelSchedule = (id) => api.cloudPost('/cloud/schedule/cancel', { id })
export const setMirror = (ws, url) => api.cloudPost('/cloud/workspace/mirror', { ws, url })
export const deleteWorkspaceCP = (id) => api.platDelete('/workspaces/' + encodeURIComponent(id))

export function adminSurfaces() {
  return ADMIN_PAGES.map((p) => ({
    id: 'admin/' + p.page, kind: 'admin', name: p.name, icon: p.icon, workspace: 'admin',
    system: true, deletable: false, payload: { page: p.page }
  }))
}

export async function loadAdmin(page, offline) {
  if (offline) return demo(page)
  try {
    switch (page) {
      case 'secrets': return { env: (await api.plat('/env')).env || [] }
      case 'members': { const r = await api.plat('/members'); return { members: r.members || [], pending: r.pending || [] } }
      case 'domains': { const r = await api.plat('/domains'); return { domains: r.domains || (Array.isArray(r) ? r : []) } }
      case 'usage': return {
        usage: await api.plat('/usage'),
        storage: await api.plat('/storage').catch(() => ({ buckets: [] })),
        nexuses: (await api.plat('/nexuses').catch(() => ({}))).nexuses || []
      }
      case 'billing': return {
        billing: await api.rt('/cloud/billing').catch(() => ({})),
        inference: await api.rt('/cloud/inference').catch(() => ({})),
        tiers: (await api.plat('/tiers').catch(() => ({}))).tiers || []
      }
      case 'tokens': return { tokens: (await api.plat('/tokens')).tokens || [] }
      case 'audit': return { events: (await api.rt('/cloud/activity')).events || [] }
      case 'profile': return { me: await api.me(), profile: (await api.rt('/cloud/profile').catch(() => ({}))).profile || {} }
      case 'security': return { keys: (await api.rt('/cloud/keys')).keys || [] }
      case 'visibility': return { workspaces: (await api.plat('/workspaces')).workspaces || [] }
      case 'integrations': return { github: await api.rt('/cloud/github/status').catch(() => ({})) }
      case 'schedules': return { schedules: (await api.rt('/cloud/schedules')).schedules || [] }
      case 'danger': return { workspaces: (await api.plat('/workspaces')).workspaces || [], nexuses: (await api.plat('/nexuses').catch(() => ({}))).nexuses || [] }
      default: return {}
    }
  } catch (e) {
    return { error: e?.message || 'failed' }
  }
}

export async function revealSecret(id) {
  try { const r = await api.plat('/env/' + encodeURIComponent(id) + '/reveal'); return r.value ?? r.secret ?? '' } catch (_) { return null }
}

function demo(page) {
  switch (page) {
    case 'secrets': return { env: [{ id: '1', name: 'OPENAI_API_KEY', scope: 'nexus', group: 'Integrations' }] }
    case 'members': return { members: [{ id: '1', name: 'You', email: 'you@demo', role: 'owner' }], pending: [] }
    case 'domains': return { domains: [{ id: '1', domain: 'app.demo.test', verified: true }] }
    case 'fleet': return { nexuses: [{ id: 'self', state: 'running', plan: 'pro', self: true }] }
    case 'usage': return { usage: { plan: 'pro', state: 'running' } }
    default: return {}
  }
}
