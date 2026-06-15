// ── Workspace switcher store (runes module) ───────────────────────────────────
// The org's FREE workspaces + the active one. Loaded from the real platform API.
// Every org always lands in a workspace: if it has none, load() creates a default
// (named after the org) so the switcher is never empty. The active workspace
// persists in localStorage so it survives reloads.

import { listWorkspaces, createWorkspace, updateWorkspace, deleteWorkspace } from '$lib/api.js';

let list = $state([]);
let activeId = $state(null);
let loaded = $state(false);

const LS_KEY = 'wb-active-workspace';
const saveActive = (id) => {
  try {
    localStorage.setItem(LS_KEY, id);
  } catch {}
};
const readActive = () => {
  try {
    return localStorage.getItem(LS_KEY);
  } catch {
    return null;
  }
};

export const workspaceStore = {
  get list() {
    return list;
  },
  get loaded() {
    return loaded;
  },
  /** the active workspace object (falls back to the first, or null when none) */
  get active() {
    return list.find((w) => w.id === activeId) || list[0] || null;
  },
  /**
   * Load the org's workspaces (once). If the org has none, create a default named
   * `defaultName` so it always lands in a real workspace. Restores the last-active
   * from localStorage when it's still valid.
   */
  async load(defaultName, force = false) {
    if (loaded && !force) return;
    let l = await listWorkspaces();
    if (l.length === 0 && defaultName) {
      try {
        l = [await createWorkspace(defaultName)];
      } catch {
        l = [];
      }
    }
    list = l;
    const saved = readActive();
    activeId = saved && l.some((w) => w.id === saved) ? saved : (l[0]?.id ?? null);
    loaded = true;
  },
  setActive(id) {
    activeId = id;
    saveActive(id);
  },
  async create(name, icon = '') {
    const ws = await createWorkspace(name, { icon });
    list = [...list, ws];
    this.setActive(ws.id);
    return ws;
  },
  /** Patch a workspace — pass only what changes ({name} and/or {icon}). */
  async update(id, attrs) {
    const ws = await updateWorkspace(id, attrs);
    list = list.map((w) => (w.id === id ? ws : w));
    return ws;
  },
  async remove(id) {
    // never leave the org with zero workspaces
    if (list.length <= 1) return false;
    list = list.filter((w) => w.id !== id);
    if (activeId === id) this.setActive(list[0]?.id);
    try {
      await deleteWorkspace(id);
    } catch {}
    return true;
  }
};
