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
export const workspaces = [
  { id: 'cloud', name: 'Cloud', icon: '☁️' },
  { id: 'lander', name: 'Lander', icon: '🪧' },
  { id: 'docs', name: 'Docs', icon: '📖' }
]

// --- surfaces (one entity, kind facet) -----------------------------------------------------------
// payload carries kind-specific data; settings (name/icon/purpose/workspace/private) are shared.
export const surfaces = $state([
  // cloud
  { id: 1, kind: 'chat', workspace: 'cloud', name: 'general', icon: '#', purpose: 'Team-wide chatter', unread: 2, payload: {} },
  { id: 2, kind: 'chat', workspace: 'cloud', name: 'system', icon: '🛎️', purpose: 'Deploys, billing, failures', unread: 5, payload: { system: true } },
  { id: 3, kind: 'agent', workspace: 'cloud', name: 'Workhorse', icon: '🐴', purpose: 'General coding agent', unread: 0, payload: { model: 'claude-opus-4-8' } },
  { id: 4, kind: 'agent', workspace: 'cloud', name: 'Scout', icon: '🔭', purpose: 'Read-only researcher', unread: 0, private: true, payload: { model: 'claude-haiku-4-5' } },
  { id: 5, kind: 'workflow', workspace: 'cloud', name: 'deploy-check', icon: '🚦', purpose: 'Pre-deploy gate', unread: 0, payload: { steps: ['weave', 'check', 'verify'] } },
  { id: 6, kind: 'app', workspace: 'cloud', name: 'Dashboard', icon: '📊', purpose: 'Ops dashboard', unread: 0, payload: {
      pages: [ { label: 'Overview', path: '/' }, { label: 'Usage', path: '/usage' }, { label: 'Team', path: '/team' } ] } },
  // lander
  { id: 7, kind: 'chat', workspace: 'lander', name: 'general', icon: '#', purpose: 'Marketing site chat', unread: 0, payload: {} },
  { id: 8, kind: 'app', workspace: 'lander', name: 'Landing', icon: '🪧', purpose: 'Public landing page', unread: 0, payload: {
      pages: [ { label: 'Home', path: '/' }, { label: 'Pricing', path: '/pricing' }, { label: 'Blog', path: '/blog' } ] } },
  // docs
  { id: 9, kind: 'chat', workspace: 'docs', name: 'general', icon: '#', purpose: 'Docs discussion', unread: 0, payload: {} },
  { id: 10, kind: 'workflow', workspace: 'docs', name: 'publish', icon: '📤', purpose: 'Build + ship docs', unread: 0, payload: { steps: ['weave', 'deploy'] } }
])

// --- messages (same store model; a channel = surfaceId) ------------------------------------------
export const messages = $state([
  { id: 11, surfaceId: 1, author: 'shane', kind: 'human', text: 'morning team', ts: '09:01' },
  { id: 12, surfaceId: 1, author: 'dana', kind: 'human', text: 'pushing the studio demo today', ts: '09:02' },
  { id: 13, surfaceId: 1, author: 'shane', kind: 'human', text: 'nice — @Workhorse can you summarize last night’s runs?', ts: '09:03' },
  { id: 14, surfaceId: 1, author: 'Workhorse', kind: 'agent', text: '3 runs completed, 0 failures. Slowest: deploy-check (42s).', ts: '09:03' },
  { id: 15, surfaceId: 2, author: 'system', kind: 'system', text: 'Deploy wb-dogfood succeeded (v118)', ts: '08:40' },
  { id: 16, surfaceId: 2, author: 'system', kind: 'system', text: 'Billing: 1.2M tokens used today', ts: '08:55' }
])

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
  nexMenu: false,
  theme: 'dark'
})

export const surfacesFor = (ws) => surfaces.filter((s) => s.workspace === ws)
export const surfaceById = (id) => surfaces.find((s) => s.id === id)
export const messagesFor = (id) => messages.filter((m) => m.surfaceId === id)

export const KIND_ORDER = ['chat', 'app', 'agent', 'workflow']
export const KIND_LABEL = { chat: 'Channels', app: 'Apps', agent: 'Agents', workflow: 'Workflows' }

// send a human message; detect @agent and /workflow to mimic the real summon path
export function send(surfaceId, text) {
  text = text.trim()
  if (!text) return
  messages.push({ id: nextId(), surfaceId, author: 'shane', kind: 'human', text, ts: now() })

  const mention = text.match(/@(\w+)/)
  if (mention) {
    const agent = surfaces.find((s) => s.kind === 'agent' && s.name.toLowerCase() === mention[1].toLowerCase())
    if (agent) reply(surfaceId, agent.name, `(${agent.payload.model}) on it — working on “${text.replace(/@\w+/, '').trim()}”`)
  }
  if (text.startsWith('/')) {
    const wf = surfaces.find((s) => s.kind === 'workflow' && text.slice(1).startsWith(s.name))
    if (wf) reply(surfaceId, 'system', `▶ running workflow ${wf.name}: ${wf.payload.steps.join(' → ')}`, 'system')
  }
}

function reply(surfaceId, author, text, kind = 'agent') {
  setTimeout(() => messages.push({ id: nextId(), surfaceId, author, kind, text, ts: now() }), 450)
}

function now() {
  const d = new Date()
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}
