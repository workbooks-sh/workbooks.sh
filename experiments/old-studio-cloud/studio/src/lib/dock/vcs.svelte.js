// Reactive VCS state — the REAL git branch the current workspace is pointed at (branches double as
// environments). Backed by /cloud/workspace/branches|checkout|branch over the workspace's repo. Offline
// (standalone demo) falls back to a single `main`. Reactive so the footer switcher updates live.
import { api } from '../api.js'
import { auth } from '../auth.svelte.js'
import { ui } from '../data.svelte.js'
import { loadRealTree } from '../fs.svelte.js'

const state = $state({ branch: 'main', branches: ['main'], dirty: 0 })
export const vcsState = state

// load the real branches for the active workspace (call on boot + when the workspace changes)
export async function loadBranches() {
  if (auth.offline) { state.branch = 'main'; state.branches = ['main']; state.dirty = 0; return }
  const ws = ui.workspace || 'cloud'
  try {
    const r = await api.rt('/cloud/workspace/branches?ws=' + encodeURIComponent(ws))
    state.branches = r.branches?.length ? r.branches : ['main']
    state.branch = r.current || state.branches[0]
    state.dirty = r.dirty || 0
  } catch (_) {}
}

export const vcs = {
  status() { return { branch: state.branch, dirty: state.dirty } },
  branches() { return state.branches },
  current() { return state.branch },
  // switch branches for real — checks out server-side, then reloads the workspace's file tree
  async checkout(b) {
    if (b === state.branch) return
    if (auth.offline) { state.branch = b; return }
    const ws = ui.workspace || 'cloud'
    try {
      const r = await api.rt('/cloud/workspace/checkout', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ws, branch: b }) })
      if (r?.ok) { state.branch = b; await loadRealTree(); await loadBranches() }
    } catch (_) {}
  },
  async createBranch(name) {
    if (!name || auth.offline) return
    const ws = ui.workspace || 'cloud'
    try {
      const r = await api.rt('/cloud/workspace/branch', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ws, name }) })
      if (r?.ok) { await loadRealTree(); await loadBranches() }
    } catch (_) {}
  },
  setDirty(n) { state.dirty = n }
}
