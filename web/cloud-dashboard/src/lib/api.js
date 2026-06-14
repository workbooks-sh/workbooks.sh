// ── Platform Control Plane (PCP) client ──────────────────────────────────────
// Typed access to the hosted-runtime ("nexus") control plane.
//
// RIGHT NOW these return MOCK data so the dashboard is fully navigable without a
// backend. Each function is the ONE place to swap when the PCP API lands:
//   MOCK — swap for fetch('/api/platform/nexuses') when the PCP API lands
// Keep the return shapes identical and the pages won't change.

/**
 * @typedef {'run'|'sleep'|'build'|'pause'} NexusState
 * @typedef {Object} Nexus
 * @property {string} id        machine-stable id (used in the URL)
 * @property {string} name
 * @property {string} region    e.g. "sfo"
 * @property {string} plan      e.g. "Starter · 1 GB"
 * @property {NexusState} state
 * @property {string} sub       human status line, e.g. "active · 37 req/min"
 * @property {string} url       public hostname
 */

const STATE_LABEL = { run: 'Running', sleep: 'Sleeping', build: 'Building', pause: 'Paused' };

/** @type {Nexus[]} */
const MOCK_NEXUSES = [
  { id: 'aurora', name: 'aurora', region: 'sfo', plan: 'Starter · 1 GB', state: 'run',   sub: 'active · 37 req/min',   url: 'aurora.nexus.workbooks.cloud' },
  { id: 'atlas',  name: 'atlas',  region: 'ewr', plan: 'Pro · 2 GB',     state: 'run',   sub: 'active · 112 req/min',  url: 'atlas.nexus.workbooks.cloud' },
  { id: 'relay',  name: 'relay',  region: 'fra', plan: 'Starter · 1 GB', state: 'sleep', sub: 'sleeping · woke 2h ago', url: 'relay.nexus.workbooks.cloud' },
  { id: 'beacon', name: 'beacon', region: 'sin', plan: 'Starter · 1 GB', state: 'build', sub: 'building · weaving…',   url: 'beacon.nexus.workbooks.cloud' }
];

/** Per-nexus detail (config + this-month rollup). MOCK. */
const MOCK_DETAIL = {
  config: {
    region: 'sfo · San Francisco',
    plan: 'Starter · 1 GB',
    scaleToZero: 'on · 5 min idle',
    storage: 'R2 · 2.1 GB',
    database: 'none',
    created: '2026-06-02'
  },
  month: {
    activeCompute: '6.4 hrs',
    sleeping: '11.6 days',
    storage: '2.1 GB-mo',
    egress: '0 GB · via R2',
    subtotal: '$11.40'
  },
  metrics: { cpu: 18, memMb: 412, memCapGb: 1, reqMin: 37, costMonth: '11.40' }
};

/** @returns {Promise<Nexus[]>} */
export async function listNexuses() {
  // MOCK — swap for fetch('/api/platform/nexuses') when the PCP API lands
  return structuredClone(MOCK_NEXUSES);
}

/** @param {string} id @returns {Promise<{nexus: Nexus, config: object, month: object, metrics: object}|null>} */
export async function getNexus(id) {
  // MOCK — swap for fetch(`/api/platform/nexuses/${id}`) when the PCP API lands
  const nexus = MOCK_NEXUSES.find((n) => n.id === id);
  if (!nexus) return null;
  return structuredClone({ nexus, ...MOCK_DETAIL });
}

/**
 * @param {{name: string, region: string, plan: string, addons?: string[]}} opts
 * @returns {Promise<Nexus>}
 */
export async function createNexus(opts) {
  // MOCK — swap for fetch('/api/platform/nexuses', {method:'POST', body:...}) when the PCP API lands
  const name = (opts.name || 'nova').trim();
  return {
    id: name,
    name,
    region: opts.region || 'sfo',
    plan: opts.plan || 'Starter · 1 GB',
    state: 'build',
    sub: 'building · weaving…',
    url: `${name}.nexus.workbooks.cloud`
  };
}

/** Usage & billing rollup for the org. MOCK. */
export async function nexusUsage() {
  // MOCK — swap for fetch('/api/platform/usage') when the PCP API lands
  return structuredClone({
    summary: { monthToDate: '38.10', compute: '24.60', storage: '3.50', database: '10.00', nexusCount: 3, activeHrs: '19.2' },
    period: 'June 2026 · billed on the 1st',
    rows: [
      { name: 'aurora', plan: 'Starter · 1 GB', activeHrs: '6.4',  storage: '2.1 GB', database: '—',        cost: '$11.40' },
      { name: 'atlas',  plan: 'Pro · 2 GB',     activeHrs: '12.8', storage: '0.4 GB', database: 'Postgres', cost: '$24.20' },
      { name: 'relay',  plan: 'Starter · 1 GB', activeHrs: '0.0',  storage: '0.1 GB', database: '—',        cost: '$2.50' }
    ]
  });
}

/** Object-storage buckets (R2) for the org. MOCK. */
export async function listBuckets() {
  // MOCK — swap for fetch('/api/platform/storage') when the PCP API lands
  return structuredClone({
    buckets: [
      { name: 'aurora-assets', nexus: 'aurora', objects: 1284, size: '2.1 GB', egress: '$0.00' },
      { name: 'atlas-uploads', nexus: 'atlas',  objects: 96,   size: '0.4 GB', egress: '$0.00' }
    ]
  });
}

export { STATE_LABEL, MOCK_NEXUSES, MOCK_DETAIL };
