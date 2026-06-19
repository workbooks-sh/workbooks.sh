// ── Env-var store (runes module) ──────────────────────────────────────────────
// Per-workspace secrets, REDACTED. Mirrors workspaceStore: a $state list keyed by
// the workspace id, with load/create/update/remove. The list NEVER holds plaintext
// — `reveal(id)` returns it transiently to the caller and is deliberately NOT
// written back into the list state.

import { listEnv, createEnv, revealEnv, updateEnv, deleteEnv } from '$lib/api.js';

let byWorkspace = $state({}); // { [workspaceId]: var[] }
let currentId = $state(null);
let loading = $state(false);

export const envStore = {
  /** the active workspace's redacted vars */
  get list() {
    return (currentId && byWorkspace[currentId]) || [];
  },
  get loading() {
    return loading;
  },
  /** Load a workspace's vars. Cached per workspace; pass force to refetch. */
  async load(workspace, force = false) {
    if (!workspace) return;
    currentId = workspace;
    if (byWorkspace[workspace] && !force) return;
    loading = true;
    const l = await listEnv(workspace);
    byWorkspace = { ...byWorkspace, [workspace]: l };
    loading = false;
  },
  async create(name, value) {
    const v = await createEnv(currentId, { name, value });
    byWorkspace = { ...byWorkspace, [currentId]: [...(byWorkspace[currentId] || []), v] };
    return v;
  },
  /** Patch a var — {name?, value?}. The returned redacted view replaces the row. */
  async update(id, attrs) {
    const v = await updateEnv(id, attrs);
    byWorkspace = {
      ...byWorkspace,
      [currentId]: (byWorkspace[currentId] || []).map((x) => (x.id === id ? v : x))
    };
    return v;
  },
  async remove(id) {
    byWorkspace = {
      ...byWorkspace,
      [currentId]: (byWorkspace[currentId] || []).filter((x) => x.id !== id)
    };
    try {
      await deleteEnv(id);
    } catch {}
    return true;
  },
  /** Plaintext, transient — returned to the caller, never cached into the list. */
  async reveal(id) {
    return revealEnv(id);
  }
};
