// ── Stateful nexus store (runes module) ──────────────────────────────────────
// Holds the org's nexus list so the list + detail pages share one source of truth.
// Seeded EMPTY and filled from the REAL platform API (`listNexuses` → the same-origin
// /api/platform proxy → the runtime registry). No fabricated fleet: an org with no
// nexuses shows an honest empty state. create/remove/setState update locally for
// responsive UI; wiring them to real provisioning is the next step (needs a connected
// runtime + FLY_API_TOKEN).

import { listNexuses, createNexus, deleteNexus, wakeNexus, sleepNexus } from '$lib/api.js';

let nexuses = $state([]);
let loaded = $state(false);

/** shared topbar search query — filters the list on `/` */
let query = $state('');

const SUB = {
  run: 'active',
  sleep: 'sleeping',
  build: 'building · weaving…',
  pause: 'paused'
};

export const nexusStore = {
  get all() {
    return nexuses;
  },
  list() {
    return nexuses;
  },
  get loaded() {
    return loaded;
  },
  /**
   * Load the org's REAL nexuses from the platform API (once per session unless
   * forced). Empty until a runtime is connected — never a fabricated fleet.
   */
  async load(force = false) {
    if (loaded && !force) return nexuses;
    nexuses = await listNexuses();
    loaded = true;
    return nexuses;
  },
  /** filtered by the shared search query */
  get filtered() {
    const q = query.trim().toLowerCase();
    if (!q) return nexuses;
    return nexuses.filter(
      (n) =>
        n.name.toLowerCase().includes(q) ||
        n.url.toLowerCase().includes(q) ||
        (n.region || '').toLowerCase().includes(q)
    );
  },
  get(id) {
    return nexuses.find((n) => n.id === id) || null;
  },
  /** detail = nexus row + config/month/metrics derived from the real row (no mock). */
  detail(id) {
    const nexus = this.get(id);
    if (!nexus) return null;
    const config = {
      region: nexus.region || '—',
      plan: nexus.plan || '—',
      scaleToZero: 'on · 5 min idle',
      storage: '—',
      database: 'none',
      created: '—'
    };
    const month = { activeCompute: '0.0 hrs', sleeping: '—', storage: '—', egress: '$0.00', subtotal: '$0.00' };
    const metrics = { cpu: 0, memMb: 0, memCapGb: 1, reqMin: 0, costMonth: '0.00' };
    return { nexus, config, month, metrics };
  },
  /**
   * Provision a REAL nexus (a Fly machine via the runtime provisioner) and prepend it.
   * The backend assigns a non-guessable id (nx-…); the returned row is the source of
   * truth. Throws on failure so the caller can surface it.
   */
  async provision({ region, plan } = {}) {
    const nexus = await createNexus({ region, plan });
    nexuses = [nexus, ...nexuses];
    return nexus;
  },
  /** Tear down a nexus — optimistic removal, real teardown in the background. */
  async remove(id) {
    nexuses = nexuses.filter((n) => n.id !== id);
    try {
      await deleteNexus(id);
    } catch {}
  },
  /** Lifecycle — optimistic state flip, real wake/sleep in the background. */
  async setState(id, state) {
    nexuses = nexuses.map((n) => (n.id === id ? { ...n, state, sub: SUB[state] || n.sub } : n));
    try {
      if (state === 'run') await wakeNexus(id);
      else if (state === 'sleep') await sleepNexus(id);
    } catch {}
  },
  // ── shared search query ──
  get query() {
    return query;
  },
  set query(v) {
    query = v;
  }
};
