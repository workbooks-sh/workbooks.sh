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
    storage: '2.1 GB',
    database: 'none',
    created: '2026-06-02'
  },
  month: {
    activeCompute: '6.4 hrs',
    sleeping: '11.6 days',
    storage: '2.1 GB-mo',
    egress: '0 GB',
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

/** Object-storage buckets for the org. MOCK. */
export async function listBuckets() {
  // MOCK — swap for fetch('/api/platform/storage') when the PCP API lands
  return structuredClone({
    buckets: [
      { name: 'aurora-assets', nexus: 'aurora', objects: 1284, size: '2.1 GB', egress: '$0.00' },
      { name: 'atlas-uploads', nexus: 'atlas',  objects: 96,   size: '0.4 GB', egress: '$0.00' }
    ]
  });
}

// ── History + Restore ────────────────────────────────────────────────────────
// "Nothing is lost — restore anything." A reverse-chron list of Changes, each a
// before → after, restorable append-only. Mirrors the runtime endpoints:
//   GET  /api/history/:scope             → [{ id, when, authorType, authorName, title }]
//   GET  /api/history/:scope/:id/diff    → { before, after }
//   POST /api/history/:scope/restore     → the new Change
// No git words ever cross this seam — only Change / History / Restore / before·after.

/**
 * @typedef {'human'|'agent'} AuthorType
 * @typedef {Object} Change
 * @property {string} id
 * @property {string} when        ISO timestamp
 * @property {AuthorType} authorType
 * @property {string} authorName  "You" · a teammate's name · an agent's name
 * @property {string} title       plain-language summary of what changed
 */

/** @type {Record<string, Change[]>} */
const MOCK_HISTORY = {
  aurora: [
    { id: 'c8', when: '2026-06-14T17:48:00Z', authorType: 'human', authorName: 'You',       title: 'Renamed the homepage' },
    { id: 'c7', when: '2026-06-14T15:30:00Z', authorType: 'agent', authorName: 'Waldo',     title: 'Added a pricing section' },
    { id: 'c6', when: '2026-06-13T19:02:00Z', authorType: 'human', authorName: 'Maya Chen', title: 'Fixed the contact form' },
    { id: 'c5', when: '2026-06-12T09:14:00Z', authorType: 'agent', authorName: 'Ledger',    title: 'Refreshed the testimonials' },
    { id: 'c4', when: '2026-06-11T22:40:00Z', authorType: 'human', authorName: 'You',       title: 'Reworded the hero headline' },
    { id: 'c1', when: '2026-06-02T08:00:00Z', authorType: 'agent', authorName: 'Waldo',     title: 'Initial build' }
  ]
};

/** before/after content for a given change. MOCK — keyed by change id. */
const MOCK_DIFF = {
  c8: { before: '# Welcome to Aurora\n\nThe storefront for makers.', after: '# Aurora — built by makers, for makers\n\nThe storefront for makers.' },
  c7: { before: '## Features\n- Fast\n- Simple', after: '## Features\n- Fast\n- Simple\n\n## Pricing\n- Starter — $0\n- Pro — $29/mo' },
  c6: { before: '<form>\n  <input name="email">\n</form>', after: '<form action="/contact" method="post">\n  <input name="email" required>\n</form>' },
  c5: { before: '> "Great product." — A. Customer', after: '> "Cut our launch time in half." — Dana R., Founder' },
  c4: { before: '# Hello', after: '# Welcome to Aurora\n\nThe storefront for makers.' },
  c1: { before: '', after: '# Hello' }
};

/** @param {string} scope @returns {Promise<Change[]>} */
export async function nexusHistory(scope) {
  // MOCK — swap for fetch(`/api/history/${scope}`) when wired
  return structuredClone(MOCK_HISTORY[scope] || []);
}

/** @param {string} scope @param {string} changeId @returns {Promise<{before:string, after:string}>} */
export async function changeDiff(scope, changeId) {
  // MOCK — swap for fetch(`/api/history/${scope}/${changeId}/diff`) when wired
  return structuredClone(MOCK_DIFF[changeId] || { before: '', after: '' });
}

/**
 * Append-only restore: returns a NEW Change (never erases history).
 * @param {string} scope @param {string} changeId @param {string} when ISO (caller-stamped; no Date.* in shared code)
 * @returns {Promise<Change>}
 */
export async function restoreVersion(scope, changeId, when) {
  // MOCK — swap for fetch(`/api/history/${scope}/restore`, {method:'POST', body: JSON.stringify({to: changeId})})
  const target = (MOCK_HISTORY[scope] || []).find((c) => c.id === changeId);
  const label = target ? new Date(target.when).toLocaleDateString('en-US', { month: 'long', day: 'numeric' }) : 'an earlier version';
  return { id: 'r' + changeId, when, authorType: 'human', authorName: 'You', title: `Restored the version from ${label}` };
}

/**
 * Undo the most recent change to a scope — append-only (re-applies the prior
 * version as a NEW change, reversible). Returns the new Change, or null if there
 * is nothing earlier to undo to.
 * @param {string} scope @param {string} when ISO (caller-stamped)
 * @returns {Promise<Change|null>}
 */
export async function undoLast(scope, when) {
  // MOCK — swap for fetch(`/api/history/${scope}/undo`, {method:'POST'})
  const list = MOCK_HISTORY[scope] || [];
  if (list.length < 2) return null;            // only the initial change → nothing to undo
  const previous = list[1];                    // [latest, previous, …] — undo returns to `previous`
  return restoreVersion(scope, previous.id, when);
}

// ── Shared folders ───────────────────────────────────────────────────────────
// "Share a folder · add it to your workspace." Mirrors the runtime endpoints:
//   GET  /api/shared-folders                 → { shareable, shared_by, shared_with }
//   POST /api/shared-folders/share           {folder, recipient, mode} → grant
//   POST /api/shared-folders/:id/add         → { folder, files }
//   POST /api/shared-folders/:id/revoke      → { ok }
// No git/subtree/josh words cross this seam — only Folder / Share / Add to workspace.

const MOCK_SHARED = {
  // folders you own and could share
  shareable: ['brand', 'campaign-q3', 'press-kit'],
  // folders you share OUT (with whom)
  shared_by: [
    { id: 'g1', owner: 'you', folder: 'brand', recipient: 'Maya Chen', mode: 'read' },
    { id: 'g2', owner: 'you', folder: 'campaign-q3', recipient: 'Atlas team', mode: 'draft' }
  ],
  // folders shared WITH you (addable to your workspace)
  shared_with: [
    { id: 'g7', owner: 'Dana Rivera', folder: 'design-system', recipient: 'you', mode: 'read', added: false },
    { id: 'g8', owner: 'Atlas team', folder: 'shared-assets', recipient: 'you', mode: 'draft', added: true }
  ]
};

export async function sharedFolders() {
  // MOCK — swap for fetch('/api/shared-folders')
  return structuredClone(MOCK_SHARED);
}

/** @param {{folder:string, recipient:string, mode?:'read'|'draft'}} opts */
export async function shareFolder(opts) {
  // MOCK — swap for fetch('/api/shared-folders/share', {method:'POST', ...})
  return { id: 'g' + Math.floor(Math.random() * 1e6), owner: 'you', folder: opts.folder, recipient: opts.recipient, mode: opts.mode || 'read' };
}

/** Add a shared folder to your workspace (append-only Draft). */
export async function addSharedFolder(id) {
  // MOCK — swap for fetch(`/api/shared-folders/${id}/add`, {method:'POST'})
  const g = MOCK_SHARED.shared_with.find((s) => s.id === id);
  return { folder: g?.folder || 'folder', files: ['logo.svg', 'colors.txt', 'guidelines.md'] };
}

/** Stop sharing a folder you own. */
export async function revokeShare(id) {
  // MOCK — swap for fetch(`/api/shared-folders/${id}/revoke`, {method:'POST'})
  return { ok: true, id };
}

// ── Drafts ───────────────────────────────────────────────────────────────────
// "Try a change safely — Keep it or Discard it." A Draft is an isolated copy of the
// workspace; the live version keeps serving until you Keep. Mirrors the runtime:
//   GET    /api/nexuses/:id/drafts            → [{ name, files_changed, preview_path }]
//   POST   /api/nexuses/:id/drafts {name}     → { name, preview_path }
//   GET    /api/nexuses/:id/drafts/:name/diff → [{ path, status }]
//   POST   /api/nexuses/:id/drafts/:name/keep → { merged }
//   POST   /api/nexuses/:id/drafts/:name/discard → ok
// No git/branch/merge words cross this seam — only Draft / preview / Keep / Discard.

const MOCK_DRAFTS = {
  aurora: [
    { name: 'spring-refresh', files_changed: 4, preview_path: '.drafts/spring-refresh',
      changes: [
        { path: 'home.md', status: 'modified' },
        { path: 'pricing.md', status: 'modified' },
        { path: 'hero.svg', status: 'added' },
        { path: 'old-banner.png', status: 'removed' }
      ] },
    { name: 'waldo-copy-pass', files_changed: 2, preview_path: '.drafts/waldo-copy-pass',
      changes: [{ path: 'about.md', status: 'modified' }, { path: 'faq.md', status: 'modified' }] }
  ]
};

export async function listDrafts(nexus) {
  // MOCK — swap for fetch(`/api/nexuses/${nexus}/drafts`)
  return structuredClone(MOCK_DRAFTS[nexus] || []);
}

export async function createDraft(nexus, name) {
  // MOCK — swap for fetch(`/api/nexuses/${nexus}/drafts`, {method:'POST', body:...})
  return { name, files_changed: 0, preview_path: `.drafts/${name}`, changes: [] };
}

export async function draftDiff(nexus, name) {
  // MOCK — swap for fetch(`/api/nexuses/${nexus}/drafts/${name}/diff`)
  const d = (MOCK_DRAFTS[nexus] || []).find((x) => x.name === name);
  return structuredClone(d?.changes || []);
}

export async function keepDraft(nexus, name) {
  // MOCK — swap for fetch(`/api/nexuses/${nexus}/drafts/${name}/keep`, {method:'POST'})
  return { merged: name };
}

export async function discardDraft(nexus, name) {
  // MOCK — swap for fetch(`/api/nexuses/${nexus}/drafts/${name}/discard`, {method:'POST'})
  return { ok: true, name };
}

export { STATE_LABEL, MOCK_NEXUSES, MOCK_DETAIL, MOCK_HISTORY };
