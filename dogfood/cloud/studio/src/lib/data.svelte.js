// The data layer — deliberately shaped like the real live-shapes sync will be, so the UI never
// changes when we swap mock → WebSocket. A "shape" = a reactive subscription to a filtered set of
// rows (resource + workspace/channel equality filter). Today it's seeded mock state held in Svelte
// $state runes; later `subscribe()` opens a WS and patches the same store on delta.
//
// One unified entity: a Surface, kind ∈ {chat, agent, workflow, app}. Shared settings on every
// kind (name, icon, purpose, workspace). Messages ride the same store as everything else — there
// is no inbox; notifications are just system/agent/workflow messages written to a channel.

let _id = 100
const nextId = () => ++_id

// --- workspaces (the default grouping) -----------------------------------------------------------
// icon = a key into the icon LIBRARY (no emoji); workspace icons render neutral (no kind color).
// `personal: true` is the user's own PRIVATE workspace — a lock (not #) leads it, a single-person
// icon stands in for the workspace icon, and everything inside is private to them (drafts, notes).
export const workspaces = [
  { id: 'me', name: 'My Workspace', icon: 'user', personal: true },
  { id: 'cloud', name: 'Cloud', icon: 'cloud' },
  { id: 'lander', name: 'Lander', icon: 'triangle-flag' },
  { id: 'docs', name: 'Docs', icon: 'book' },
  // Admin workspaces — ALWAYS LAST so they never lead the list. They carry the highest permission
  // tier (ROOT): their surfaces operate org-wide. The old standalone "Admin" rail console is gone —
  // admin is now just a workspace, so you can build SYSTEMS around it with the same primitives. The
  // `admin: true` scope groups them under the gray "Admin" divider with a shield LEAD glyph; the
  // workspace keeps its OWN icon. Two of them here, to show the scope holds many.
  { id: 'admin', name: 'Admin', icon: 'settings', admin: true },
  { id: 'admin-sec', name: 'Security', icon: 'lock', admin: true }
]

// --- surfaces (one entity, kind facet) -----------------------------------------------------------
// payload carries kind-specific data; settings (name/icon/purpose/workspace/private) are shared.
// icon = a key into the icon LIBRARY (custom-pickable in Settings); COLOR comes from the kind.
export const surfaces = $state([
  // my workspace — all private to me (drafts, notes, a personal agent)
  { id: 20, kind: 'chat', workspace: 'me', name: 'notes', icon: 'notes', purpose: 'Personal scratchpad', unread: 0, private: true, payload: {} },
  { id: 21, kind: 'agent', workspace: 'me', name: 'My Assistant', icon: 'sparks', purpose: 'My personal agent', unread: 0, private: true, payload: { model: 'claude-opus-4-8' } },
  { id: 22, kind: 'app', workspace: 'me', name: 'Untitled App', icon: 'app-window', purpose: 'Draft — not deployed', unread: 0, private: true, payload: {
      draft: true, pages: [ { label: 'Home', path: '/' }, { label: 'Editor', path: '/edit' } ] } },
  { id: 23, kind: 'workflow', workspace: 'me', name: 'morning-digest', icon: 'journal-page', purpose: 'My daily summary', unread: 0, private: true, payload: {
      steps: ['gather', 'summarize'],
      triggerKind: 'schedule', triggerLabel: 'Scheduled · 07:00 daily',
      inputs: [
        { key: 'date', label: 'Digest date', type: 'date' },
        { key: 'focus', label: 'Focus topics', type: 'text', placeholder: 'deploys, billing' } ] } },
  // cloud
  { id: 1, kind: 'chat', workspace: 'cloud', name: 'general', icon: 'chat-bubble', purpose: 'Team-wide chatter', unread: 2, payload: {} },
  { id: 2, kind: 'chat', workspace: 'cloud', name: 'system', icon: 'bell', purpose: 'Deploys, billing, failures', unread: 5, payload: { system: true } },
  { id: 3, kind: 'agent', workspace: 'cloud', name: 'Workhorse', icon: 'cpu', purpose: 'General coding agent', unread: 0, payload: {
      model: 'claude-opus-4-8', volumes: [
        { name: 'memory', format: 'sqlite', rows: 1840 },
        { name: 'embeddings', format: 'vector', rows: 9200 },
        { name: 'tool-cache', format: 'sqlite', rows: 312 }] } },
  { id: 4, kind: 'agent', workspace: 'cloud', name: 'Scout', icon: 'search', purpose: 'Read-only researcher', unread: 0, private: true, folder: 'f-archive', payload: { model: 'claude-haiku-4-5' } },
  { id: 5, kind: 'workflow', workspace: 'cloud', name: 'deploy-check', icon: 'git-fork', purpose: 'Pre-deploy gate', unread: 0, payload: {
      steps: ['Weave the tree', 'Check capabilities', 'Verify artifact'],
      triggerKind: 'manual', triggerLabel: 'Run on a git ref',
      volumes: [{ name: 'run-logs', format: 'logs', rows: 6 }],
      inputs: [
        { key: 'ref', label: 'Git ref', type: 'text', placeholder: 'main', required: true },
        { key: 'requested_by', label: 'Requested by', type: 'text', placeholder: 'you@team' },
        { key: 'environment', label: 'Environment', type: 'choice', options: ['staging', 'production'] },
        { key: 'release_notes', label: 'Release notes', type: 'file', accept: '.pdf', optional: true } ] } },
  { id: 6, kind: 'app', workspace: 'cloud', name: 'Dashboard', icon: 'graph-up', purpose: 'Ops dashboard', unread: 0, payload: {
      pages: [ { label: 'Overview', path: '/' }, { label: 'Usage', path: '/usage' }, { label: 'Team', path: '/team' } ],
      volumes: [ { name: 'metrics', format: 'postgres', rows: 5400 }, { name: 'team', format: 'sheet', rows: 12 } ] } },
  // first-class DATABASE surfaces — each declares a FORMAT (shape you work with + engine)
  { id: 30, kind: 'database', workspace: 'cloud', name: 'CRM', icon: 'database', purpose: 'Customers & invoices', unread: 0, payload: {
      format: 'sqlite',
      tables: [
        { name: 'customers', cols: ['name', 'email', 'plan', 'mrr'], rows: [
          ['Dana Lref', 'dana@acme.co', 'pro', '$240'], ['Mira Sol', 'mira@acme.co', 'free', '$0'],
          ['Shane M', 'shane@x.co', 'team', '$890'], ['Lia Ko', 'lia@io.dev', 'pro', '$240'] ] },
        { name: 'invoices', cols: ['id', 'customer', 'amount', 'status'], rows: [
          ['INV-118', 'Dana Lref', '$240', 'paid'], ['INV-119', 'Shane M', '$890', 'paid'],
          ['INV-120', 'Lia Ko', '$240', 'open'] ] } ] } },
  { id: 31, kind: 'database', workspace: 'cloud', name: 'Signups', icon: 'table', purpose: 'Waitlist spreadsheet', unread: 0, payload: {
      format: 'sheet',
      tables: [ { name: 'waitlist', cols: ['email', 'source', 'date'], rows: [
        ['ada@lab.io', 'blog', 'Jun 24'], ['ben@co.dev', 'twitter', 'Jun 24'], ['cy@mail.com', 'referral', 'Jun 23'], ['dee@x.io', 'blog', 'Jun 22'] ] } ] } },
  { id: 32, kind: 'database', workspace: 'cloud', name: 'Webhooks', icon: 'code-brackets', purpose: 'Inbound event store', unread: 0, payload: {
      format: 'json',
      documents: [
        { id: 'evt_8821', type: 'deploy.succeeded', ref: 'main', actor: 'dana', at: '14:02' },
        { id: 'evt_8820', type: 'invoice.paid', invoice: 'INV-119', amount: '$890', at: '12:40' },
        { id: 'evt_8819', type: 'user.signed_up', email: 'ada@lab.io', plan: 'pro', at: '09:15' } ] } },
  // lander
  { id: 7, kind: 'chat', workspace: 'lander', name: 'general', icon: 'chat-bubble', purpose: 'Marketing site chat', unread: 0, payload: {} },
  { id: 8, kind: 'app', workspace: 'lander', name: 'Landing', icon: 'app-window', purpose: 'Public landing page', unread: 0, payload: {
      pages: [ { label: 'Home', path: '/' }, { label: 'Pricing', path: '/pricing' }, { label: 'Blog', path: '/blog' } ] } },
  // docs
  { id: 9, kind: 'chat', workspace: 'docs', name: 'general', icon: 'chat-bubble', purpose: 'Docs discussion', unread: 0, payload: {} },
  { id: 10, kind: 'workflow', workspace: 'docs', name: 'publish', icon: 'upload', purpose: 'Build + ship docs', unread: 0, payload: { steps: ['weave', 'deploy'] } },

  // ── Admin workspace (org · ROOT scope) — data surfaces + brains, equal weight ──────────────────
  // DATA: the records you'd manage in a classic admin console, but as first-class Studio surfaces.
  { id: 50, kind: 'chat', workspace: 'admin', name: 'audit', icon: 'list', purpose: 'Every org-level event, append-only', unread: 0, payload: { system: true } },
  { id: 51, kind: 'database', workspace: 'admin', name: 'Members', icon: 'group', purpose: 'People, roles & access', unread: 0, payload: {
      format: 'sheet',
      tables: [ { name: 'members', cols: ['name', 'role', 'status', 'last active'], rows: [
        ['shane', 'admin', 'active', '2m ago'], ['dana', 'admin', 'active', '9m ago'],
        ['mira', 'member', 'away', '1h ago'], ['lia', 'member', 'offline', '3d ago'] ] } ] } },
  { id: 52, kind: 'app', workspace: 'admin', name: 'Billing', icon: 'graph-up', purpose: 'Plan, usage & invoices', unread: 0, payload: {
      pages: [ { label: 'Usage', path: '/' }, { label: 'Invoices', path: '/invoices' }, { label: 'Plan', path: '/plan' } ],
      volumes: [ { name: 'usage', format: 'postgres', rows: 5400 }, { name: 'invoices', format: 'sheet', rows: 18 } ] } },
  { id: 53, kind: 'database', workspace: 'admin', name: 'Secrets', icon: 'lock', purpose: 'Org secrets — values masked', unread: 0, payload: {
      format: 'json',
      documents: [
        { key: 'OPENROUTER_API_KEY', value: 'sk-or-••••••4f2a', scope: 'org', rotated: '12d ago' },
        { key: 'WB_S3_KEY', value: 'AKIA••••••7Q', scope: 'org', rotated: '40d ago' },
        { key: 'WB_DATABASE_URL', value: 'postgres://••••••/wb', scope: 'org', rotated: '5d ago' } ] } },
  // BRAINS: the same agent/workflow primitives, but wired to org-scope tools — this is what lets you
  // "build systems around admin" instead of clicking through a fixed console.
  { id: 54, kind: 'agent', workspace: 'admin', name: 'Org Admin', icon: 'shield', purpose: 'Org operations copilot (root tools)', unread: 0, payload: {
      model: 'claude-opus-4-8', volumes: [ { name: 'audit-index', format: 'vector', rows: 4200 } ] } },
  { id: 55, kind: 'workflow', workspace: 'admin', name: 'provisioning', icon: 'git-fork', purpose: 'Onboard / offboard a teammate', unread: 0, payload: {
      steps: ['Create or disable account', 'Sync workspace access', 'Grant / revoke capabilities', 'Post to #audit'],
      triggerKind: 'manual', triggerLabel: 'Run on a person',
      inputs: [
        { key: 'person', label: 'Person', type: 'text', placeholder: 'lia@team', required: true },
        { key: 'action', label: 'Action', type: 'choice', options: ['onboard', 'offboard'] },
        { key: 'workspaces', label: 'Workspaces', type: 'text', placeholder: 'cloud, docs' } ] } },

  // ── Security admin workspace (a SECOND root workspace — shows the scope holds many) ─────────────
  { id: 56, kind: 'chat', workspace: 'admin-sec', name: 'incidents', icon: 'bell', purpose: 'Security alerts & response', unread: 0, payload: { system: true } },
  { id: 57, kind: 'database', workspace: 'admin-sec', name: 'Access logs', icon: 'list', purpose: 'Every auth & grant event', unread: 0, payload: {
      format: 'logs',
      tables: [ { name: 'auth', cols: ['who', 'action', 'resource', 'when'], rows: [
        ['shane', 'login', 'org', '14:00'], ['dana', 'grant', 'cloud/secrets', '13:41'],
        ['system', 'revoke', 'lia → all', '13:40'], ['mira', 'login', 'org', '11:18'] ] } ] } }
])

// --- folders (optional grouping WITHIN a workspace) ----------------------------------------------
// A folder is a lightweight container; a surface's `folder` field (a folder id) drops it inside.
// Surfaces with no `folder` sit at the workspace's top level. Drag a surface onto a folder to move it.
export const folders = $state([
  { id: 'f-archive', workspace: 'cloud', name: 'Archive' }
])
export const foldersFor = (ws) => folders.filter((f) => f.workspace === ws)

let _fid = 0
export function addFolder(wsId, name = 'New Folder') {
  const f = { id: `f-${++_fid}-${Date.now()}`, workspace: wsId, name }
  folders.push(f)
  return f
}

// blank surface of a given kind, dropped into a workspace (and optionally a folder)
const KIND_DEFAULTS = {
  chat: { icon: 'chat-bubble', name: 'new-channel', payload: {} },
  agent: { icon: 'cpu', name: 'New Agent', payload: { model: 'claude-opus-4-8' } },
  workflow: { icon: 'git-fork', name: 'new-workflow', payload: { steps: ['Do something'] } },
  app: { icon: 'app-window', name: 'Untitled App', payload: { draft: true, pages: [{ label: 'Home', path: '/' }] } },
  database: { icon: 'database', name: 'New Database', payload: { tables: [{ name: 'table1', cols: ['name', 'value'], rows: [['', '']] }] } }
}
export function addSurface(kind, wsId, folder = null) {
  const d = KIND_DEFAULTS[kind]
  const s = { id: nextId(), kind, workspace: wsId, name: d.name, icon: d.icon,
    purpose: '', unread: 0, folder, payload: structuredClone(d.payload) }
  surfaces.push(s)
  ui.surfaceId = s.id; ui.workspace = wsId
  return s
}

export function moveToFolder(surfaceId, folderId) {
  const s = surfaceById(surfaceId)
  if (s) s.folder = folderId
}

// people in the org (mention candidates alongside agents). Each carries a small profile the
// avatar-click card renders, plus a presence status ∈ active | away | offline.
export const people = [
  { name: 'shane', role: 'Founder', status: 'active', blurb: 'Building Workbooks. Usually in #general.' },
  { name: 'dana', role: 'Engineering', status: 'active', blurb: 'Ships the cloud — owns deploy-check.' },
  { name: 'mira', role: 'Design', status: 'away', blurb: 'Studio redesign + the lander.' },
  { name: 'lia', role: 'Growth', status: 'offline', blurb: 'Signups, lifecycle, the waitlist.' }
]
export const personByName = (name) => people.find((p) => p.name.toLowerCase() === String(name || '').toLowerCase())
export const agentByName = (name) => surfaces.find((s) => s.kind === 'agent' && s.name.toLowerCase() === String(name || '').toLowerCase())

// --- direct messages (a section of the sidebar, separate from workspaces) -------------------------
// A DM thread targets one or more PEOPLE (`members`); 1 member = a 1:1, >1 = a private group DM. The
// current user ("you") is always implicitly in it. Messages ride the shared `messages` store keyed by
// the thread id. Agents are NOT DMs — clicking an agent jumps to its agent surface.
export const dms = $state([
  { id: 'dm-dana', members: ['dana'], unread: 0 },
  { id: 'dm-mira', members: ['mira'], unread: 1 },
  { id: 'dm-dana-mira', members: ['dana', 'mira'], unread: 0 } // a private group DM
])
export const dmById = (id) => dms.find((d) => d.id === id)
export const isGroupDM = (d) => (d?.members?.length || 0) > 1
// a thread id is derived from its sorted members, so the same group always maps to one thread
export const dmKey = (members) => 'dm-' + [...members].map((m) => m.toLowerCase()).sort().join('-')
export const dmTitle = (d) => d ? d.members.join(', ') : ''

// resolve a selected id to a renderable entity: a real Surface, or a DM thread as a surface-like view.
export function entityById(id) {
  const s = surfaceById(id)
  if (s) return s
  const d = dmById(id)
  if (!d) return null
  const group = isGroupDM(d)
  const p = group ? null : personByName(d.members[0])
  return { id: d.id, kind: 'dm', name: dmTitle(d), icon: group ? 'group' : 'user', dm: true, group, members: d.members, person: p,
    purpose: group ? `Group · ${d.members.length + 1} people` : (p ? `${p.role} · direct message` : 'Direct message') }
}

// open (or create) a DM with one or more people and select it; clears any open profile card.
export function openDMWith(members) {
  members = (members || []).filter(Boolean)
  if (!members.length) return null
  const id = dmKey(members)
  let d = dmById(id)
  if (!d) { d = { id, members: [...members], unread: 0 }; dms.push(d) }
  d.unread = 0
  ui.surfaceId = id; ui.profile = null
  return d
}
export const openDM = (name) => openDMWith([name])

// click a message avatar: agents jump straight to their agent surface; people open a profile card.
export function openAuthor(author, kind) {
  if (kind === 'agent') {
    const a = agentByName(author)
    if (a) { ui.surfaceId = a.id; ui.workspace = a.workspace; ui.profile = null }
    return
  }
  if (kind === 'system') return
  if (personByName(author)) ui.profile = author
}

// built-in slash commands (shown under the workspace's workflows in the / picker)
export const SLASH = [
  { name: 'remind', hint: 'Set a reminder in this channel', icon: 'alarm' },
  { name: 'invite', hint: 'Invite a teammate', icon: 'group' }
]

// --- messages (same store model; a channel = surfaceId) ------------------------------------------
// A message may carry attachments [{type:'image'|'file', name, size, color}] and, for kind
// 'workflow-run', a run {workflow, status, steps:[{name,status}]}.
export const messages = $state([
  { id: 11, surfaceId: 1, author: 'shane', kind: 'human', text: 'morning team', ts: '09:01' },
  { id: 12, surfaceId: 1, author: 'dana', kind: 'human', text: 'pushing the studio demo today — here’s the mock',
    ts: '09:02', attachments: [{ type: 'image', name: 'studio-mock.png', w: 1200, h: 750,
      url: 'https://images.unsplash.com/photo-1551434678-e076c223a692?w=1000&q=70' }] },
  { id: 13, surfaceId: 1, author: 'shane', kind: 'human', text: 'nice — @Workhorse can you summarize last night’s runs?', ts: '09:03' },
  { id: 14, surfaceId: 1, author: 'Workhorse', kind: 'agent', text: '3 runs completed, 0 failures. Slowest: deploy-check (42s). Report attached.',
    ts: '09:03', attachments: [{ type: 'file', name: 'runs-2026-06-24.csv', size: '12 KB' }] },
  { id: 15, surfaceId: 2, author: 'system', kind: 'system', text: 'Deploy wb-dogfood succeeded (v118)', ts: '08:40' },
  { id: 16, surfaceId: 2, author: 'system', kind: 'system', text: 'Billing: 1.2M tokens used today', ts: '08:55' },
  // direct messages (thread id = surfaceId)
  { id: 40, surfaceId: 'dm-dana', author: 'dana', kind: 'human', text: 'hey — did the deploy-check pass on main?', ts: '13:58' },
  { id: 41, surfaceId: 'dm-dana', author: 'shane', kind: 'human', text: 'held it — 2 capability violations, check r-501', ts: '14:03' },
  { id: 42, surfaceId: 'dm-mira', author: 'mira', kind: 'human', text: 'pushed the new sidebar colors, take a look when you can 🎨', ts: '11:20' },
  // a private group DM (you + dana + mira)
  { id: 43, surfaceId: 'dm-dana-mira', author: 'mira', kind: 'human', text: 'sidebar redesign thread — keeping it off #general for now', ts: '10:02' },
  { id: 44, surfaceId: 'dm-dana-mira', author: 'dana', kind: 'human', text: 'works for me. shane, ship the DM section first?', ts: '10:04' },

  // #audit — the org event feed (append-only, system-authored)
  { id: 50, surfaceId: 50, author: 'system', kind: 'system', text: 'dana set mira → member (was admin)', ts: '08:30' },
  { id: 51, surfaceId: 50, author: 'system', kind: 'system', text: 'Secret WB_S3_KEY rotated by shane', ts: '09:12' },
  { id: 52, surfaceId: 50, author: 'system', kind: 'system', text: 'provisioning: offboarded lia — 3 grants revoked, 4 items reassigned', ts: '13:40' },
  { id: 53, surfaceId: 50, author: 'system', kind: 'system', text: 'Deploy wb-dogfood v118 succeeded', ts: '14:02' },
  // Org Admin agent (id 54) — shows admin-as-automation: chat an instruction, it acts org-wide
  { id: 54, surfaceId: 54, author: 'shane', kind: 'human', text: 'offboard lia and move her docs to dana', ts: '13:39' },
  { id: 55, surfaceId: 54, author: 'Org Admin', kind: 'agent', text: 'Done — disabled lia’s account, revoked 3 capability grants, reassigned 4 docs to dana, and posted the summary to #audit. Want me to schedule a 30-day data purge?', ts: '13:40' }
])

// stock avatars (external, demo-only): humans get a photo face, agents a generated robot.
export function avatarOf(author, kind) {
  if (kind === 'system') return null
  if (kind === 'agent') return `https://api.dicebear.com/9.x/bottts/svg?seed=${encodeURIComponent(author)}&backgroundColor=transparent`
  return `https://i.pravatar.cc/72?u=${encodeURIComponent(author)}`
}

export const mentionCandidates = (wsId) =>
  [...people.map((p) => ({ name: p.name, kind: 'person' })),
   ...surfaces.filter((s) => s.kind === 'agent' && s.workspace === wsId).map((a) => ({ name: a.name, kind: 'agent', icon: a.icon }))]

export const workflowsFor = (wsId) => surfaces.filter((s) => s.kind === 'workflow' && s.workspace === wsId)

// --- workflow runs (the DEFAULT view of a workflow surface = its run history) -------------------
// Each run records status + per-step results, so the runs list can show success/failure and you can
// drill into a card to see what each step did or why it failed. status ∈ queued|running|success|failed.
// each run carries OUTPUTS (the artifacts it produced — the main thing you look at) and STEPS (the
// log). An output has a kind ∈ doc | chat | data | app and a body the right-hand panel renders richly.
export const workflowRuns = $state([
  { id: 'r-501', surfaceId: 5, status: 'blocked', trigger: 'main · requested by dana', when: '14m ago', duration: '38s', bucket: 'today',
    steps: [
      { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 142 files → bundle.work (1.8 MB)' },
      { name: 'If the weave reports violations', status: 'success', detail: 'true — 2 capability violations found', branch: 'true' },
      { name: 'Block the deploy & post to #system', status: 'success', detail: 'Deploy held · posted 2 violations to #system' } ],
    outputs: [
      { kind: 'doc', title: 'Deploy blocked — 2 violations', preview: 'main held · capability check', body: [
        { h: 'Deploy blocked' },
        { p: 'The gate ran successfully and held the deploy: the weave produced a valid bundle, but 2 declared-capability violations must be resolved first.' },
        { h: 'Violations' },
        { li: 'site/lander → calls net.fetch but does not declare it (lib/checkout.work:42)' },
        { li: 'site/lander → reads WB_S3_KEY without a secrets grant (lib/upload.work:7)' },
        { p: 'Fix the grants or remove the calls, then re-run deploy-check on main.' } ] },
      { kind: 'chat', title: 'Posted to #system', preview: '2 messages', messages: [
        { author: 'deploy-check', text: '🚧 Deploy held for main — 2 capability violations found.' },
        { author: 'deploy-check', text: 'Full report in run r-501. cc @dana' } ] } ] },
  { id: 'r-500', surfaceId: 5, status: 'success', trigger: 'main · requested by shane', when: '2h ago', duration: '41s', bucket: 'today',
    steps: [
      { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 140 files → bundle.work (1.7 MB)' },
      { name: 'If the weave reports violations', status: 'success', detail: 'false — no violations', branch: 'false' },
      { name: 'Run check, then verify against artifact', status: 'success', detail: 'check ✓ · verify ✓ (0 drift)' },
      { name: 'Mark deploy ready & notify', status: 'success', detail: 'Notified shane · deploy armed' } ],
    outputs: [
      { kind: 'doc', title: 'Deploy summary', preview: 'main → armed, 0 violations', body: [
        { h: 'Deploy ready' },
        { p: 'main wove cleanly (140 files, 1.7 MB) with no capability violations. check ✓ and verify ✓ against the artifact.' },
        { li: 'Bundle: bundle.work (1.7 MB)' },
        { li: 'Drift vs artifact: 0' },
        { li: 'Armed for: staging' } ] },
      { kind: 'data', title: 'Verification report', preview: '3 gates · all passed',
        cols: ['Gate', 'Result', 'Detail'], rows: [
          ['weave', 'passed', '140 files'], ['check', 'passed', '142 units'], ['verify', 'passed', '0 drift'] ] } ] },
  { id: 'r-499', surfaceId: 5, status: 'success', trigger: 'release/1.8 · requested by mira', when: 'yesterday', duration: '39s', bucket: 'yesterday',
    steps: [
      { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 138 files → bundle.work' },
      { name: 'If the weave reports violations', status: 'success', detail: 'false — no violations', branch: 'false' },
      { name: 'Run check, then verify against artifact', status: 'success', detail: 'check ✓ · verify ✓' },
      { name: 'Mark deploy ready & notify', status: 'success', detail: 'deploy armed' } ],
    outputs: [
      { kind: 'doc', title: 'Deploy summary', preview: 'scheduled deploy armed', body: [
        { h: 'Deploy ready' }, { p: 'Scheduled 09:00 run. No violations; armed for staging.' } ] } ] },
  // morning-digest (id 23)
  { id: 'r-220', surfaceId: 23, status: 'success', trigger: 'Scheduled · 07:00', when: '6h ago', duration: '12s', bucket: 'today',
    steps: [ { name: 'gather', status: 'success', detail: 'Pulled 18 items from 4 sources' },
      { name: 'summarize', status: 'success', detail: 'Wrote digest (320 words) → #general' } ],
    outputs: [
      { kind: 'doc', title: 'Morning digest · Jun 25', preview: '18 items · 4 sources', body: [
        { h: 'Morning digest' },
        { p: '18 items across 4 sources. Top themes: deploys, billing, incidents.' },
        { h: 'Deploys' }, { li: 'wb-dogfood v118 shipped (0 failures)' }, { li: 'deploy-check median 41s' },
        { h: 'Billing' }, { li: '1.2M tokens used today (+8% vs 7-day avg)' } ] },
      { kind: 'chat', title: 'Posted to #general', preview: '1 message', messages: [
        { author: 'morning-digest', text: '☀️ Your morning digest is ready — 18 items. Top: deploys, billing.' } ] } ] },
  { id: 'r-219', surfaceId: 23, status: 'success', trigger: 'Scheduled · 07:00', when: 'yesterday', duration: '11s', bucket: 'yesterday',
    steps: [ { name: 'gather', status: 'success', detail: 'Pulled 14 items' },
      { name: 'summarize', status: 'success', detail: 'Wrote digest (280 words)' } ],
    outputs: [
      { kind: 'doc', title: 'Morning digest · Jun 24', preview: '14 items · 4 sources', body: [
        { h: 'Morning digest' }, { p: '14 items. Quiet day — no deploys, billing steady.' } ] } ] },

  // ── older runs (this week + history; history is lazy-loaded by the feed) ──────────────────────
  { id: 'r-498', surfaceId: 5, status: 'success', trigger: 'main · requested by shane', when: 'Mon', duration: '40s', bucket: 'week',
    steps: [ { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 139 files' },
      { name: 'If the weave reports violations', status: 'success', detail: 'false — no violations', branch: 'false' },
      { name: 'Run check, then verify', status: 'success', detail: 'check ✓ · verify ✓' },
      { name: 'Mark deploy ready & notify', status: 'success', detail: 'armed' } ],
    outputs: [ { kind: 'doc', title: 'Deploy summary', preview: 'main armed', body: [ { h: 'Deploy ready' }, { p: 'Clean weave, armed for staging.' } ] } ] },
  { id: 'r-218', surfaceId: 23, status: 'success', trigger: 'Scheduled · 07:00', when: 'Tue', duration: '13s', bucket: 'week',
    steps: [ { name: 'gather', status: 'success', detail: 'Pulled 21 items' }, { name: 'summarize', status: 'success', detail: 'Wrote digest (340 words)' } ],
    outputs: [ { kind: 'doc', title: 'Morning digest · Jun 23', preview: '21 items · 4 sources', body: [ { h: 'Morning digest' }, { p: '21 items. Incident postmortem + 2 deploys.' } ] } ] },
  { id: 'r-497', surfaceId: 5, status: 'blocked', trigger: 'release/1.7 · requested by dana', when: 'Jun 18', duration: '37s', bucket: 'history',
    steps: [ { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 137 files' },
      { name: 'If the weave reports violations', status: 'success', detail: 'true — 1 violation', branch: 'true' },
      { name: 'Block the deploy & post to #system', status: 'success', detail: 'Deploy held · posted 1 violation' } ],
    outputs: [ { kind: 'doc', title: 'Deploy blocked — 1 violation', preview: 'release/1.7 held', body: [ { h: 'Deploy blocked' }, { p: 'Held release/1.7: 1 undeclared capability.' }, { li: 'site/blog → calls net.fetch undeclared' } ] } ] },
  { id: 'r-217', surfaceId: 23, status: 'success', trigger: 'Scheduled · 07:00', when: 'Jun 17', duration: '12s', bucket: 'history',
    steps: [ { name: 'gather', status: 'success', detail: 'Pulled 12 items' }, { name: 'summarize', status: 'success', detail: 'Wrote digest (240 words)' } ],
    outputs: [ { kind: 'doc', title: 'Morning digest · Jun 17', preview: '12 items · 3 sources', body: [ { h: 'Morning digest' }, { p: '12 items. Slow week start.' } ] } ] },
  { id: 'r-496', surfaceId: 5, status: 'success', trigger: 'main · requested by mira', when: 'Jun 15', duration: '42s', bucket: 'history',
    steps: [ { name: 'Weave the workbook tree', status: 'success', detail: 'Wove 135 files' },
      { name: 'If the weave reports violations', status: 'success', detail: 'false — no violations', branch: 'false' },
      { name: 'Run check, then verify', status: 'success', detail: 'check ✓ · verify ✓' },
      { name: 'Mark deploy ready & notify', status: 'success', detail: 'armed' } ],
    outputs: [ { kind: 'doc', title: 'Deploy summary', preview: 'main armed', body: [ { h: 'Deploy ready' }, { p: 'Clean weave.' } ] } ] }
])
export const runsFor = (surfaceId) => workflowRuns.filter((r) => r.surfaceId === surfaceId)

// a workflow is manually RUNNABLE only if its trigger is invocation-based (not cron / reaction).
// scheduled & reactive flows can still be TEST-run from the editor/feed, but not "Run now".
export const isInvocable = (surf) => (surf?.payload?.triggerKind || 'manual') === 'manual'

// kick off a live run from the supplied trigger inputs: steps tick queued → running → success.
let _run = 600
export function startRun(surfaceId, values = {}) {
  const s = surfaceById(surfaceId)
  const names = s?.payload?.steps || ['run']
  const summary = Object.entries(values)
    .map(([k, v]) => `${k}=${v && v.name ? v.name : v}`).filter((x) => !x.endsWith('=')).join(' · ')
  const run = {
    id: `r-${++_run}`, surfaceId, status: 'running', trigger: summary ? `Manual · ${summary}` : 'Manual run',
    when: 'just now', duration: '…', bucket: 'today', inputs: values, outputs: [],
    steps: names.map((name) => ({ name, status: 'queued', detail: 'Queued' }))
  }
  workflowRuns.unshift(run)
  const live = workflowRuns[0] // $state proxy
  names.forEach((_, i) => {
    setTimeout(() => { live.steps[i].status = 'running'; live.steps[i].detail = 'Running…' }, i * 700 + 150)
    setTimeout(() => {
      live.steps[i].status = 'success'; live.steps[i].detail = 'Done'
      if (i === names.length - 1) {
        live.status = 'success'; live.duration = `${names.length * 7 + 4}s`
        live.outputs = [{ kind: 'doc', title: 'Run output', preview: `${names.length} steps · success`, body: [
          { h: `${s?.name || 'Workflow'} complete` },
          { p: `Ran ${names.length} steps to success with the supplied inputs.` },
          ...Object.entries(values).filter(([, v]) => v).map(([k, v]) => ({ li: `${k}: ${v && v.name ? v.name : v}` })) ] }]
      }
    }, i * 700 + 600)
  })
  return run
}

// dev helper: plausible demo values for trigger inputs (files get a placeholder; we don't fake binaries)
const DEMO_TEXT = { ref: 'main', requested_by: 'dana@team', focus: 'deploys, billing', environment: 'staging' }
export function demoInputValue(inp) {
  switch (inp.type) {
    case 'choice': return inp.options?.[0]
    case 'number': return 42
    case 'date': return '2026-06-25'
    case 'file': return { name: `sample${inp.accept || '.pdf'}`, demo: true }
    default: return DEMO_TEXT[inp.key] || 'demo value'
  }
}

// the active nexus (what the nextile dropdown switches between)
export const nexuses = [
  { id: 'dogfood', name: 'Dogfood', icon: '🌱' },
  { id: 'acme', name: 'Acme Corp', icon: '🅰️' }
]

// rail sections — Studio is the merged apps+studio surface; the rest are the surviving surfaces
// Data is no longer a rail destination — data lives NESTED (database surfaces + per-surface volumes).
export const RAIL_SECS = [
  { id: 'studio', icon: 'spark', label: 'Studio' },
  { id: 'files', icon: 'files', label: 'Files' }
]

// the active selection (signals via runes)
export const ui = $state({
  nexus: 'dogfood',
  section: 'studio',
  workspace: 'cloud',
  surfaceId: 1,
  settingsOpen: false,
  mediaOpen: false,
  nexMenu: false,
  profile: null, // a person's name when their profile card is open over the sidebar
  wsSettings: null, // a workspace id when the settings panel is editing a WORKSPACE (not a surface)
  theme: 'dark'
})

export const surfacesFor = (ws) => surfaces.filter((s) => s.workspace === ws)
export const surfaceById = (id) => surfaces.find((s) => s.id === id)
export const messagesFor = (id) => messages.filter((m) => m.surfaceId === id)

export const KIND_ORDER = ['chat', 'app', 'database', 'agent', 'workflow']
export const KIND_LABEL = { chat: 'Channels', app: 'Apps', database: 'Databases', agent: 'Agents', workflow: 'Workflows' }

// a surface's "contents" for the unified hover popover: app pages + any attached data volumes.
// volumes have a type ∈ table | sqlite | logs — the same drawer exposes agent memory & workflow logs.
export const contentsOf = (s) => ({
  pages: s?.payload?.pages || [],
  volumes: s?.payload?.volumes || (s?.kind === 'database'
    ? (s.payload?.format === 'json'
        ? [{ name: 'documents', format: 'json', rows: (s.payload.documents || []).length }]
        : (s.payload?.tables || []).map((t) => ({ name: t.name, format: s.payload.format || 'sheet', rows: t.rows?.length })))
    : [])
})
export const hasContents = (s) => { const c = contentsOf(s); return c.pages.length || c.volumes.length }

// send a human message (with optional attachments); detect @agent and /workflow to mimic summoning.
export function send(surfaceId, text, attachments = []) {
  text = text.trim()
  if (!text && !attachments.length) return
  const wsId = surfaceById(surfaceId)?.workspace

  // "/<workflow>" as the whole message → run that workflow inline instead of posting text
  if (text.startsWith('/')) {
    const cmd = text.slice(1).split(/\s+/)[0].toLowerCase()
    const wf = workflowsFor(wsId).find((w) => w.name.toLowerCase() === cmd)
    if (wf) { runWorkflow(surfaceId, wf); return }
  }

  messages.push({ id: nextId(), surfaceId, author: 'shane', kind: 'human', text, ts: now(), attachments })

  const mention = text.match(/@(\w+)/)
  if (mention) {
    const agent = surfaces.find((s) => s.kind === 'agent' && s.name.toLowerCase() === mention[1].toLowerCase())
    if (agent) reply(surfaceId, agent.name, `(${agent.payload.model}) on it — working on “${text.replace(/@\w+/, '').trim()}”`)
  }

  // a DM thread → someone on the other end acks, so the conversation feels two-sided
  if (typeof surfaceId === 'string' && surfaceId.startsWith('dm-')) {
    const d = dmById(surfaceId)
    if (d) reply(surfaceId, d.members[0], 'got it 👍', 'human')
  }
}

function reply(surfaceId, author, text, kind = 'agent') {
  setTimeout(() => messages.push({ id: nextId(), surfaceId, author, kind, text, ts: now() }), 450)
}

// run a workflow as a live in-chat run-card: steps tick pending → done over time.
export function runWorkflow(surfaceId, wf) {
  const steps = wf.payload.steps.map((name) => ({ name, status: 'pending' }))
  messages.push({ id: nextId(), surfaceId, author: wf.name, kind: 'workflow-run', ts: now(),
    run: { workflow: wf.name, status: 'running', steps } })
  const live = messages[messages.length - 1] // the $state proxy
  steps.forEach((_, i) => setTimeout(() => {
    live.run.steps[i].status = 'done'
    if (i === steps.length - 1) live.run.status = 'done'
  }, (i + 1) * 800))
}

function now() {
  const d = new Date()
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}
