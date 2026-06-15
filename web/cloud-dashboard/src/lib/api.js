// ── Platform Control Plane (PCP) client ──────────────────────────────────────
// Typed access to the hosted-runtime ("nexus") control plane.
//
// The collaborative-workspaces calls (history / drafts / shared-folders / roles /
// backup) talk to a REAL runtime when one is configured, and fall back to MOCK
// data otherwise so the dashboard stays navigable offline. Configure the runtime
// with `VITE_WB_RUNTIME` (base URL) + `VITE_WB_TENANT` (dev x-tenant); without them
// `live()` is false and everything is mock. The platform-nexus list/usage/storage
// calls below remain mock until the PCP platform API lands.

const RUNTIME = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_WB_RUNTIME) || '';
const DEV_TENANT = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_WB_TENANT) || '';

/** True when a real runtime is configured — flips the collab calls from mock to live. */
export function live() { return RUNTIME !== ''; }

/**
 * One place that talks to the runtime, via SAME-ORIGIN relative paths. In dev the
 * Vite proxy (vite.config) forwards `/api` → VITE_WB_RUNTIME (no CORS); in prod the
 * dashboard is served same-origin as the runtime. Returns parsed JSON, throws on non-2xx.
 */
async function rt(path, { method = 'GET', body } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (DEV_TENANT) headers['x-tenant'] = DEV_TENANT;     // dev single-tenant; prod uses the session cookie/JWT
  const res = await fetch(path, { method, headers, body: body && JSON.stringify(body), credentials: 'include' });
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}`);
  return res.status === 204 ? null : res.json();
}

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

const STATE_LABEL = { run: 'Active', sleep: 'Idle', build: 'Starting', pause: 'Paused' };

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

// ── Platform control-plane (REAL, via the same-origin /api/platform proxy) ──────
// The proxy (src/routes/api/platform/[...rest]) forwards to the runtime with the
// WorkOS bearer → org-scoped. On no-runtime / error we return honest EMPTY data —
// never a fabricated fleet — so the dashboard always reflects reality.

// `fetchFn` defaults to global fetch (browser); SSR load fns pass SvelteKit's `fetch`
// so a relative same-origin path resolves server-side too.
async function plat(path, { method = 'GET', body, fetch: fetchFn = globalThis.fetch } = {}) {
  const res = await fetchFn(`/api/platform${path}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : {},
    body: body && JSON.stringify(body),
    credentials: 'include'
  });
  if (!res.ok) throw new Error(`${method} /api/platform${path} → ${res.status}`);
  return res.status === 204 ? null : res.json();
}

const SUB_FOR = { run: 'active', sleep: 'sleeping', build: 'building · weaving…', pause: 'paused' };
const withSub = (n) => ({ ...n, sub: n.sub || SUB_FOR[n.state] || '' });

/** @param {{fetch?: Function}} [opts] @returns {Promise<Nexus[]>} */
export async function listNexuses(opts = {}) {
  try {
    return (await plat('/nexuses', { fetch: opts.fetch })).nexuses.map(withSub);
  } catch {
    return []; // honest empty — no fake fleet until a runtime is connected
  }
}

/** @param {string} id @returns {Promise<{nexus: Nexus, config: object, month: object, metrics: object}|null>} */
export async function getNexus(id) {
  try {
    const nexus = withSub(await plat(`/nexuses/${id}`));
    let row;
    try {
      row = (await plat('/usage')).rows.find((r) => r.name === id);
    } catch {}
    const config = {
      region: nexus.region,
      plan: nexus.plan,
      status: nexus.state === 'run' ? 'Active' : nexus.state === 'sleep' ? 'Idle' : 'Starting',
      storage: row?.storage || '—',
      database: row?.database || 'none',
      created: '—'
    };
    const month = {
      activeCompute: row ? `${row.activeHrs} hrs` : '0.0 hrs',
      sleeping: '—',
      storage: row?.storage || '—',
      egress: '$0.00',
      subtotal: row?.cost || '$0.00'
    };
    const metrics = { cpu: 0, memMb: 0, memCapGb: 1, reqMin: 0, costMonth: (row?.cost || '$0').replace(/[$,]/g, '') };
    return { nexus, config, month, metrics };
  } catch {
    return null;
  }
}

/**
 * Provision a REAL nexus (a Fly machine via the runtime provisioner).
 * `database` carries the "comes with a database" intent; full Postgres/Neon
 * provisioning is a creds-gated follow-up (the runtime honours it when configured).
 * @param {{region?: string, plan?: string, database?: boolean}} opts
 * @returns {Promise<Nexus>}
 */
export async function createNexus(opts) {
  return withSub(await plat('/nexuses', { method: 'POST', body: { name: opts.name, region: opts.region, plan: opts.plan, database: opts.database } }));
}

export async function deleteNexus(id) {
  return plat(`/nexuses/${id}`, { method: 'DELETE' });
}
export async function wakeNexus(id) {
  return plat(`/nexuses/${id}/wake`, { method: 'POST' });
}
export async function sleepNexus(id) {
  return plat(`/nexuses/${id}/sleep`, { method: 'POST' });
}

const EMPTY_USAGE = {
  // `load` = % of compute capacity in use across the org's nexuses (idle ⇒ 0).
  summary: { monthToDate: '$0.00', compute: '$0.00', storage: '0 GB', database: '—', nexusCount: 0, activeHrs: '0.0', load: 0 },
  period: 'current cycle · billed on the 1st',
  rows: []
};

/** Usage & billing rollup for the org — REAL (Fly-grounded compute + cost). */
export async function nexusUsage(opts = {}) {
  try {
    return await plat('/usage', { fetch: opts.fetch });
  } catch {
    return structuredClone(EMPTY_USAGE);
  }
}

/** Object-storage buckets for the org — REAL per-org total. */
export async function listBuckets(opts = {}) {
  try {
    return await plat('/storage', { fetch: opts.fetch });
  } catch {
    return { buckets: [], totalSize: '0 GB' };
  }
}

// ── Workspaces — FREE, named divisions within the org (Org → Nexus → Workspaces) ──

/** @returns {Promise<Array<{id,name,nexus_id,created}>>} */
export async function listWorkspaces(opts = {}) {
  try {
    return (await plat('/workspaces', { fetch: opts.fetch })).workspaces;
  } catch {
    return [];
  }
}

export async function createWorkspace(name, opts = {}) {
  return plat('/workspaces', { method: 'POST', body: { name, icon: opts.icon, nexus_id: opts.nexus_id } });
}

/** Patch a workspace — pass only the fields to change ({name} and/or {icon}). */
export async function updateWorkspace(id, attrs) {
  return plat(`/workspaces/${id}`, { method: 'PATCH', body: attrs });
}

export async function renameWorkspace(id, name) {
  return updateWorkspace(id, { name });
}

export async function deleteWorkspace(id) {
  return plat(`/workspaces/${id}`, { method: 'DELETE' });
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
// The runtime speaks snake_case (author_type/author_name); the UI uses camelCase.
const normChange = (c) => ({ id: c.id, when: c.when, authorType: c.author_type ?? c.authorType, authorName: c.author_name ?? c.authorName, title: c.title });

export async function nexusHistory(scope) {
  if (live()) return (await rt(`/api/history/${scope}`)).map(normChange);
  return []; // honest empty — per-nexus history streams from the tenant runtime (not yet wired)
}

/** @param {string} scope @param {string} changeId @returns {Promise<{before:string, after:string}>} */
export async function changeDiff(scope, changeId) {
  if (live()) return rt(`/api/history/${scope}/${changeId}/diff`);
  return { before: '', after: '' };
}

/**
 * Append-only restore: returns a NEW Change (never erases history).
 * @param {string} scope @param {string} changeId @param {string} when ISO (caller-stamped; no Date.* in shared code)
 * @returns {Promise<Change>}
 */
export async function restoreVersion(scope, changeId, when) {
  if (live()) {
    const r = await rt(`/api/history/${scope}/restore`, { method: 'POST', body: { to: changeId } });
    return r.unchanged ? null : normChange(r);
  }
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
  if (live()) {
    const r = await rt(`/api/history/${scope}/undo`, { method: 'POST' });
    return r.nothing ? null : normChange(r);
  }
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
  if (live()) return rt('/api/shared-folders');
  return { shareable: [], shared_by: [], shared_with: [] }; // honest empty
}

/** @param {{folder:string, recipient:string, mode?:'read'|'draft'}} opts */
export async function shareFolder(opts) {
  if (live()) return rt('/api/shared-folders/share', { method: 'POST', body: { folder: opts.folder, recipient: opts.recipient, mode: opts.mode || 'read' } });
  return { id: 'g' + Math.floor(Math.random() * 1e6), owner: 'you', folder: opts.folder, recipient: opts.recipient, mode: opts.mode || 'read' };
}

/** Add a shared folder to your workspace (append-only Draft). */
export async function addSharedFolder(id) {
  if (live()) return rt(`/api/shared-folders/${id}/add`, { method: 'POST' });
  const g = MOCK_SHARED.shared_with.find((s) => s.id === id);
  return { folder: g?.folder || 'folder', files: ['logo.svg', 'colors.txt', 'guidelines.md'] };
}

/** Stop sharing a folder you own. */
export async function revokeShare(id) {
  if (live()) return rt(`/api/shared-folders/${id}/revoke`, { method: 'POST' });
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
  if (live()) return rt(`/api/nexuses/${nexus}/drafts`);
  return []; // honest empty
}

export async function createDraft(nexus, name) {
  if (live()) return rt(`/api/nexuses/${nexus}/drafts`, { method: 'POST', body: { name } });
  return { name, files_changed: 0, preview_path: `.drafts/${name}`, changes: [] };
}

export async function draftDiff(nexus, name) {
  if (live()) return rt(`/api/nexuses/${nexus}/drafts/${name}/diff`);
  const d = (MOCK_DRAFTS[nexus] || []).find((x) => x.name === name);
  return structuredClone(d?.changes || []);
}

export async function keepDraft(nexus, name) {
  if (live()) return rt(`/api/nexuses/${nexus}/drafts/${name}/keep`, { method: 'POST' });
  return { merged: name };
}

export async function discardDraft(nexus, name) {
  if (live()) return rt(`/api/nexuses/${nexus}/drafts/${name}/discard`, { method: 'POST' });
  return { ok: true, name };
}

export { STATE_LABEL, MOCK_NEXUSES, MOCK_DETAIL, MOCK_HISTORY };
