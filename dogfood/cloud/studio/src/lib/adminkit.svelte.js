// adminkit.svelte.js — shared primitives for the admin console: a mutation runner (optimistic + toast +
// rollback that surfaces the REAL backend message), a global confirm dialog, clipboard, and role/status
// color + rank maps. Every interactive admin page uses these so behavior + security posture are uniform.
import { pushToast } from './toast.svelte.js'

// Run a mutating action. Optionally apply an optimistic change first; on success toast `success` and return
// the result; on failure roll back and toast the real backend error (e.message from api.mutate). Returns
// the result, or null on error. `{pending:true}` results are treated as success (caller can branch on it).
export async function runAction(fn, { success, optimistic, rollback } = {}) {
  if (optimistic) optimistic()
  try {
    const r = await fn()
    if (success && !(r && r.pending)) pushToast(success, 'ok')
    return r
  } catch (e) {
    if (rollback) rollback()
    pushToast(e?.message || 'Action failed', 'err')
    return null
  }
}

export async function copyText(t, label = 'Copied') {
  try { await navigator.clipboard.writeText(String(t ?? '')); pushToast(label, 'ok') }
  catch (_) { pushToast('Copy failed', 'err') }
}

// role > rank (mirror the server: owner>admin>member>viewer) — caps role selects + disables actions in-UI
export const RANK = { owner: 3, admin: 2, member: 1, viewer: 0 }
export const rank = (r) => RANK[r] ?? 0
export const ROLES = ['viewer', 'member', 'admin', 'owner']
const ROLE_COLOR = { owner: 'var(--color-fuchsia)', admin: 'var(--color-sky)', member: 'var(--color-mint)', viewer: 'var(--color-dim)' }
export const roleColor = (r) => ROLE_COLOR[r] || 'var(--color-dim)'

const STATUS_COLOR = {
  active: 'var(--color-mint)', verified: 'var(--color-mint)', ok: 'var(--color-mint)', running: 'var(--color-mint)', live: 'var(--color-mint)',
  pending: 'var(--color-amber)', verifying: 'var(--color-amber)', near: 'var(--color-amber)', settling: 'var(--color-amber)',
  error: 'var(--color-bad)', over: 'var(--color-bad)', failed: 'var(--color-bad)', stopped: 'var(--color-dim)'
}
export const statusColor = (s) => STATUS_COLOR[s] || 'var(--color-dim)'

// ── global confirm dialog (typed/named for destructive actions) ──────────────────────────────────────
export const confirmState = $state({ open: false, title: '', body: '', confirmLabel: 'Confirm', danger: false, typed: null, input: '' })
let _resolve = null
// ask for confirmation; returns Promise<boolean>. Pass `typed: '<name>'` to require typing the target name.
export function askConfirm({ title, body = '', confirmLabel = 'Confirm', danger = false, typed = null }) {
  Object.assign(confirmState, { open: true, title, body, confirmLabel, danger, typed, input: '' })
  return new Promise((res) => { _resolve = res })
}
export function resolveConfirm(ok) {
  confirmState.open = false
  const r = _resolve; _resolve = null
  if (r) r(ok)
}
