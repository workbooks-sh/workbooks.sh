// ── Stateful nexus store (runes module) ──────────────────────────────────────
// Holds the live nexus list so create/delete/state-changes persist and reflect
// across pages. Seeded once from the api.js mock; thereafter THIS is the source
// of truth for the list page and the detail page. Swap the seed + ops for real
// PCP calls when the API lands — the shapes are identical.

import { MOCK_NEXUSES, MOCK_DETAIL } from '$lib/api.js';

let nexuses = $state(structuredClone(MOCK_NEXUSES));

/** shared topbar search query — filters the list on `/` */
let query = $state('');

const SUB = {
  run: 'active · 37 req/min',
  sleep: 'sleeping · idle',
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
  /** filtered by the shared search query */
  get filtered() {
    const q = query.trim().toLowerCase();
    if (!q) return nexuses;
    return nexuses.filter(
      (n) =>
        n.name.toLowerCase().includes(q) ||
        n.url.toLowerCase().includes(q) ||
        n.region.toLowerCase().includes(q)
    );
  },
  get(id) {
    return nexuses.find((n) => n.id === id) || null;
  },
  /** detail = nexus row + config/month/metrics (config region/plan reflect the row) */
  detail(id) {
    const nexus = this.get(id);
    if (!nexus) return null;
    const d = structuredClone(MOCK_DETAIL);
    d.config.region = `${nexus.region} · ${nexus.region}`;
    d.config.plan = nexus.plan;
    return { nexus, ...d };
  },
  create({ name, region, plan, addons } = {}) {
    const base = (name || 'nova').trim() || 'nova';
    let id = base;
    let n = 2;
    while (this.get(id)) id = `${base}-${n++}`;
    const nexus = {
      id,
      name: id,
      region: region || 'sfo',
      plan: plan || 'Starter · 1 GB',
      state: 'build',
      sub: SUB.build,
      url: `${id}.nexus.workbooks.cloud`,
      addons: addons || []
    };
    nexuses = [nexus, ...nexuses];
    return nexus;
  },
  remove(id) {
    nexuses = nexuses.filter((n) => n.id !== id);
  },
  setState(id, state) {
    nexuses = nexuses.map((n) =>
      n.id === id ? { ...n, state, sub: SUB[state] || n.sub } : n
    );
  },
  // ── shared search query ──
  get query() {
    return query;
  },
  set query(v) {
    query = v;
  }
};
