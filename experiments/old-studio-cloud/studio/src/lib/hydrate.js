// hydrate.js — the bridge that turns the mock store into a live store WITHOUT touching components.
//
// Components read the exported $state collections in data.svelte.js and never fetch. hydrate() opens
// the live-shapes socket (live.js → Nexus.Shapes over /ws) and, per resource, replaces the collection
// on the initial snapshot and upserts/removes on each delta. Svelte 5 $state proxies re-render every
// consumer on in-place mutation, so wiring is purely additive — the seed arrays just become the
// starting value until the server's snapshot lands.
//
// Offline (no runtime): the socket never connects, no snapshot arrives, and the mock seed data stays —
// so the same build runs as the live dashboard (with a nexus) and the standalone demo (without one).
import { live } from './live.js'
import { api } from './api.js'
import { auth } from './auth.svelte.js'
import { adminSurfaces, adminWorkspaces } from './admin.js'
import { loadRealTree } from './fs.svelte.js'
import { surfaces, workspaces, messages, dms, folders, workflowRuns, nexuses, ui } from './data.svelte.js'

// shape name (registered server-side via Nexus.Shapes.register) → the local $state collection
const SHAPES = {
  surfaces,
  workspaces,
  messages,
  dms,
  folders,
  nexuses
}

// replace the contents of a $state array in place (keeps the same proxy, re-renders consumers)
function replaceAll(arr, rows) {
  arr.splice(0, arr.length, ...rows)
}

// upsert-by-id (idempotent — a delta that echoes an optimistic local write replaces, never duplicates)
function upsert(arr, row) {
  const i = arr.findIndex((x) => x.id === row.id)
  if (i >= 0) Object.assign(arr[i], row)
  else arr.push(row)
}

function remove(arr, row) {
  const i = arr.findIndex((x) => x.id === row.id)
  if (i >= 0) arr.splice(i, 1)
}

// REST initial-load sources — the live-shapes socket (Nexus.Shapes) isn't serving deltas yet, so we
// fetch the REAL rows over the existing control-plane / cloud REST API now; when the socket lands, its
// `init`/`delta` frames take over the same collections seamlessly (replaceAll/upsert are idempotent).
// Each loader maps the nexus response shape → the SPA collection shape (the `/me` adapter pattern).
const REST = {
  // the user's REAL nexus machines (org control plane) — replaces the mock rail list
  nexuses: async () => {
    const r = await api.plat('/nexuses')
    return (r.nexuses || []).map((n) => ({ id: n.id, name: n.name || n.id, icon: n.icon || '◆', url: n.url, state: n.state, plan: n.plan, region: n.region }))
  },
  workspaces: async () => {
    const r = await api.plat('/workspaces')
    const real = (r.workspaces || []).map((w) => ({ id: w.id, name: w.name || w.id, icon: w.icon || 'folder', nexus_id: w.nexus_id }))
    // every nexus gets an Admin workspace for its owner/admins (nexus-wide ops). Interim client synthesis
    // until the control plane provisions it per-org (the parked rebuild).
    // Admin is a GROUP of synthesized workspaces (Account, Billing, Infrastructure, Governance), each
    // scope:'admin' so they render under the sidebar's "Admin" group — not one monolithic Admin workspace.
    const role = auth.me?.role
    if (role === 'owner' || role === 'admin') {
      for (const w of adminWorkspaces()) if (!real.find((x) => x.id === w.id)) real.push(w)
    }
    return real
  },
  // surfaces (the workspace ITEMS) come from /cloud/items per workspace — real kind-typed entries built
  // from the .work declarations (agent/app/workflow/database/chat). Fan out over the workspaces, flatten.
  surfaces: async () => {
    const wsr = await api.plat('/workspaces') // throws on failure → the caller retries
    const ids = (wsr.workspaces || []).map((w) => w.id)
    // Fetch all workspaces' items in PARALLEL — sequential measured ~3.3s (sum); parallel is ~1.3s (the
    // slowest single one). Partial-tolerant: a workspace that errors contributes []; a TOTAL failure throws
    // so the caller retries (+ self-heal), so a transient blip never permanently blanks the UI.
    const settled = await Promise.allSettled(ids.map((id) =>
      api.rt('/cloud/items?ws=' + encodeURIComponent(id)).then((r) => r.items || [])))
    if (ids.length && settled.every((s) => s.status === 'rejected')) throw new Error('items unavailable')
    const lists = settled.map((s) => (s.status === 'fulfilled' ? s.value : []))
    const real = lists.flat().map((it) => ({
      id: it.id, kind: it.kind, name: it.name, workspace: it.workspace,
      icon: it.icon || '', purpose: '', unread: 0, group: it.group || null, source: it.source || 'inferred',
      payload: { children: it.children || [] }, url: it.url, path: it.path
    }))
    // Default admin pages — synthesized as system surfaces in the Admin workspace, for admins/owners only.
    // (Interim until the control plane provisions them per-org in the batched rebuild.)
    const role = auth.me?.role
    const admin = (role === 'owner' || role === 'admin') ? adminSurfaces() : []
    return [...real, ...admin]
  }
}

// retry a loader with exponential backoff; resolves its rows on success, null after exhausting attempts
async function withRetry(fn, attempts = 6, base = 300) {
  for (let i = 0; i < attempts; i++) {
    try { return await fn() } catch (_) {}
    if (i < attempts - 1) await new Promise((r) => setTimeout(r, Math.min(base * 2 ** i, 1500)))
  }
  return null
}

// background self-heal: if any collection failed, keep retrying (escalating delay, capped) until it loads
let healTimer = null
let healDelay = 4000
function scheduleHeal() {
  if (healTimer) return
  healTimer = setTimeout(async () => {
    healTimer = null
    const ok = await loadAll()
    healDelay = ok ? 4000 : Math.min(healDelay * 2, 60000)
  }, healDelay)
}

// Load every wired collection WITH RETRIES, replacing a collection ONLY on success — a hard failure never
// blanks it (it keeps whatever it has) and schedules a heal. Returns true iff everything loaded.
async function loadAll() {
  let ok = true
  await Promise.all(Object.entries(REST).map(async ([name, load]) => {
    const rows = await withRetry(load)
    if (rows != null) replaceAll(SHAPES[name], rows)
    else ok = false
  }))
  if (nexuses.length && !nexuses.find((n) => n.id === ui.nexus)) ui.nexus = nexuses[0].id
  loadRealTree() // the Code page's real file tree (one cheap /cloud/tree request)
  mergeProfileAvatar() // /me has no avatar; the user's picture lives in /cloud/profile — fold it into identity
  if (!ok) scheduleHeal()
  return ok
}

// The identity from /api/platform/me carries no avatar; the user sets their picture in studio settings,
// which persists to /cloud/profile. Pull it and fold it into auth.me so the rail/chat/You all show it.
async function mergeProfileAvatar() {
  try {
    const a = (await api.rt('/cloud/profile'))?.profile?.avatar
    if (a && auth.me && auth.me.avatar !== a) auth.me = { ...auth.me, avatar: a }
  } catch (_) {}
}

// ONLINE = REAL DATA ONLY: purge the mock seed ONCE up front (so demo data can NEVER leak), then load real
// with retries + background self-heal so a transient blip can't leave the workspaces blank. Offline never
// calls this (hydrate() is gated on !auth.offline), so the standalone demo keeps its seed.
export async function hydrateRest() {
  for (const arr of [surfaces, workspaces, messages, dms, folders, workflowRuns, nexuses]) replaceAll(arr, [])
  await loadAll()
}

// re-load when the network returns or the tab becomes visible again (covers laptop sleep, flaky wifi, …)
function installSelfHeal() {
  if (typeof window === 'undefined' || window.__wbHeal) return
  window.__wbHeal = true
  window.addEventListener('online', () => { healDelay = 4000; loadAll() })
  document.addEventListener('visibilitychange', () => { if (!document.hidden) loadAll() })
}

let started = false

// Open the live socket and subscribe every shape. `scope` (workspace/channel) can narrow a shape;
// omitted here means "everything in the tenant" (the socket is tenant-scoped server-side).
export function hydrate() {
  if (started) return
  started = true
  hydrateRest() // REST initial-load (real rows, retried) + self-heal — the data source today
  installSelfHeal() // re-load on reconnect / tab-visible so a blip never leaves the UI blank

  // The live-shapes socket (Nexus.Shapes) ISN'T served yet, so opening it just reconnect-storms /ws every
  // 1.5s (console errors + churn). Gated OFF until the server implements shapes; REST + self-heal cover the
  // data. Re-enable by flipping LIVE_SOCKET when the server speaks the shape protocol.
  const LIVE_SOCKET = false
  if (LIVE_SOCKET) {
    const client = live()
    for (const [name, arr] of Object.entries(SHAPES)) {
      client.subscribeShape(name, undefined, {
        init: (rows) => { if (rows && rows.length) replaceAll(arr, rows) },
        delta: ({ op, row }) => {
          if (op === 'insert' || op === 'update') upsert(arr, row)
          else if (op === 'delete') remove(arr, row)
        }
      })
    }
  }
}
