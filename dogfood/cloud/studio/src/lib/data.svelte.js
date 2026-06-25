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
export const workspaces = [
  { id: 'cloud', name: 'Cloud', icon: 'cloud' },
  { id: 'lander', name: 'Lander', icon: 'triangle-flag' },
  { id: 'docs', name: 'Docs', icon: 'book' }
]

// --- surfaces (one entity, kind facet) -----------------------------------------------------------
// payload carries kind-specific data; settings (name/icon/purpose/workspace/private) are shared.
// icon = a key into the icon LIBRARY (custom-pickable in Settings); COLOR comes from the kind.
export const surfaces = $state([
  // cloud
  { id: 1, kind: 'chat', workspace: 'cloud', name: 'general', icon: 'chat-bubble', purpose: 'Team-wide chatter', unread: 2, payload: {} },
  { id: 2, kind: 'chat', workspace: 'cloud', name: 'system', icon: 'bell', purpose: 'Deploys, billing, failures', unread: 5, payload: { system: true } },
  { id: 3, kind: 'agent', workspace: 'cloud', name: 'Workhorse', icon: 'cpu', purpose: 'General coding agent', unread: 0, payload: { model: 'claude-opus-4-8' } },
  { id: 4, kind: 'agent', workspace: 'cloud', name: 'Scout', icon: 'search', purpose: 'Read-only researcher', unread: 0, private: true, payload: { model: 'claude-haiku-4-5' } },
  { id: 5, kind: 'workflow', workspace: 'cloud', name: 'deploy-check', icon: 'git-fork', purpose: 'Pre-deploy gate', unread: 0, payload: { steps: ['weave', 'check', 'verify'] } },
  { id: 6, kind: 'app', workspace: 'cloud', name: 'Dashboard', icon: 'graph-up', purpose: 'Ops dashboard', unread: 0, payload: {
      pages: [ { label: 'Overview', path: '/' }, { label: 'Usage', path: '/usage' }, { label: 'Team', path: '/team' } ] } },
  // lander
  { id: 7, kind: 'chat', workspace: 'lander', name: 'general', icon: 'chat-bubble', purpose: 'Marketing site chat', unread: 0, payload: {} },
  { id: 8, kind: 'app', workspace: 'lander', name: 'Landing', icon: 'app-window', purpose: 'Public landing page', unread: 0, payload: {
      pages: [ { label: 'Home', path: '/' }, { label: 'Pricing', path: '/pricing' }, { label: 'Blog', path: '/blog' } ] } },
  // docs
  { id: 9, kind: 'chat', workspace: 'docs', name: 'general', icon: 'chat-bubble', purpose: 'Docs discussion', unread: 0, payload: {} },
  { id: 10, kind: 'workflow', workspace: 'docs', name: 'publish', icon: 'upload', purpose: 'Build + ship docs', unread: 0, payload: { steps: ['weave', 'deploy'] } }
])

// people in the org (mention candidates alongside agents)
export const people = [{ name: 'shane' }, { name: 'dana' }, { name: 'mira' }]

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
  { id: 16, surfaceId: 2, author: 'system', kind: 'system', text: 'Billing: 1.2M tokens used today', ts: '08:55' }
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

// the active nexus (what the nextile dropdown switches between)
export const nexuses = [
  { id: 'dogfood', name: 'Dogfood', icon: '🌱' },
  { id: 'acme', name: 'Acme Corp', icon: '🅰️' }
]

// rail sections — Studio is the merged apps+studio surface; the rest are the surviving surfaces
export const RAIL_SECS = [
  { id: 'studio', icon: 'spark', label: 'Studio' },
  { id: 'files', icon: 'files', label: 'Files' },
  { id: 'data', icon: 'sheet', label: 'Data' }
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
  theme: 'dark'
})

export const surfacesFor = (ws) => surfaces.filter((s) => s.workspace === ws)
export const surfaceById = (id) => surfaces.find((s) => s.id === id)
export const messagesFor = (id) => messages.filter((m) => m.surfaceId === id)

export const KIND_ORDER = ['chat', 'app', 'agent', 'workflow']
export const KIND_LABEL = { chat: 'Channels', app: 'Apps', agent: 'Agents', workflow: 'Workflows' }

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
