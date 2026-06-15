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

// onboarding tier id → the plan label shown on a nexus row ("Name · Storage").
const TIER_PLAN = {
  free: 'Free · 2 GB',
  starter: 'Starter · 50 GB',
  team: 'Team · 250 GB',
  scale: 'Scale · 1 TB',
  ent: 'Enterprise · custom'
};

const slug = (s) =>
  (s || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32);

// Seed only once per session — repeated calls (layout re-renders) are no-ops.
let seeded = false;

export const nexusStore = {
  get all() {
    return nexuses;
  },
  list() {
    return nexuses;
  },
  /**
   * Replace the demo fleet with the user's real first nexus, derived from what
   * they told us in onboarding. No profile (a fresh dev with no cookie) → keep
   * the mock fleet so the dashboard still demos populated. Runs once per session.
   * SWAP SEAM: when the PCP API lands, the seed comes from a real registry fetch
   * instead of the profile cookie — the row shape is identical.
   */
  seedFromProfile(profile) {
    if (seeded) return;
    seeded = true;
    if (!profile) return;
    const base =
      slug(profile.orgName) ||
      (profile.accountType === 'personal' && slug(profile.firstName)) ||
      'workspace';
    nexuses = [
      {
        id: base,
        name: base,
        region: 'sfo',
        plan: TIER_PLAN[profile.tier] || TIER_PLAN.free,
        state: 'run',
        sub: SUB.run,
        url: `${base}.nexus.workbooks.cloud`,
        addons: []
      }
    ];
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
