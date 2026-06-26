// The toolkit registry — the catalog of CLIs the runtime can expose to agents & flows. A TOOLKIT is a
// CLI compiled to WASM (→ eventually BEAM ASM) shipped WITH its context/skills — like a CLI bundled
// with its Claude-style SKILL.md. Two facets, one schema:
//   • tool        — a pure-capability CLI, no auth (ripgrep, ffmpeg, pandoc)
//   • integration — an API-backed CLI that needs a connection (gh, stripe, supabase)
// Seeded here as a ~dozen real entries to iterate on; the production registry is generated into .work
// (facts from Nango + CLI-Anything + a dev-CLI seed). Icons resolve through OUR glyphs toolkit.

import { iconSlugs } from './glyphs/index.js'

// Capabilities = the sandbox grant. A toolkit is a CLI compiled to WASM; it can only touch what the sandbox
// permits, and that set is inspectable from the module's WASI imports (fd_read, path_open, sock_*, proc_*).
// We render the GRANTED SET (cumulative, plain language), not a single tier. Hand-declared here for the
// demo; derived from the compiled wasm's imports in production.
export const CAP_META = {
  read: { label: 'read', color: 'var(--color-mint)', wasi: 'fd_read · path_open(read)', detail: 'Reads files inside the sandbox view.' },
  network: { label: 'network', color: 'var(--color-sky)', wasi: 'sock_open · sock_send/recv', detail: 'Opens sockets — outbound HTTP / WebSocket to the hosts below.' },
  write: { label: 'write', color: 'var(--color-peach)', wasi: 'fd_write · path_open(write)', detail: 'Writes into the virtual filesystem.' },
  spawn: { label: 'spawn', color: 'var(--color-fuchsia)', wasi: 'host_exec', detail: 'Can host-invoke another program’s wasm module.' }
}
const CAP_ORDER = ['read', 'network', 'write', 'spawn']
export const capsOf = (t) => CAP_ORDER.filter((c) => (t.caps || []).includes(c))

// risk read out of the granted capabilities — honest, derived, not a separate guess.
export function risksOf(t) {
  const c = t.caps || []
  const out = []
  if (c.includes('network')) out.push('Can reach the network — could send workspace data outbound.')
  if (c.includes('write')) out.push('Can modify files in the workspace view.')
  if (c.includes('spawn')) out.push('Can run other programs inside the sandbox.')
  if (!out.length) out.push('Low — read-only and fully sandboxed.')
  return out
}

export const LANG_META = {
  rust: { label: 'Rust', tint: 'var(--color-peach)' },
  go: { label: 'Go', tint: 'var(--color-sky)' },
  node: { label: 'Node', tint: 'var(--color-mint)' },
  python: { label: 'Python', tint: 'var(--color-violet)' },
  c: { label: 'C', tint: 'var(--color-dim)' },
  haskell: { label: 'Haskell', tint: 'var(--color-dim)' }
}
export const AUTH_META = {
  none: { label: 'No auth' },
  api_key: { label: 'API key' },
  oauth: { label: 'OAuth' }
}

// Marks are simple-icons tinted by a hand-assigned brand `color` (cleaner than full-colour wordmarks).
// `icon` = simple-icon slug (null ⇒ no brand mark → fall back to the CLI's language icon). `color` = brand
// hex (null ⇒ theme ink, for neutral marks like GitHub/Vercel). `fallback` = iconoir name for the total miss.
//   id, name, summary, icon, color, fallback, category, kind, lang, caps[], auth, tools, enabled, connected
export const toolkits = $state([
  // ── tool CLIs (no auth) ──────────────────────────────────────────────────────────────────────
  { id: 'ripgrep', name: 'ripgrep', summary: 'Blazing-fast recursive search across the workspace', icon: null, color: null, fallback: 'search', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['search', 'glob', 'count', 'replace', 'json', 'files'], fileTypes: ['any text'], enabled: true },
  { id: 'fd', name: 'fd', summary: 'A simple, fast alternative to find', icon: null, color: null, fallback: 'folder', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['find', 'glob'], fileTypes: ['any'], enabled: true },
  { id: 'bat', name: 'bat', summary: 'A cat clone with syntax highlighting', icon: 'bat', color: null, fallback: 'page', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['print', 'pager'], fileTypes: ['source', 'text', 'md'], enabled: false },
  { id: 'hugo', name: 'hugo', summary: 'Static-site generator — build & render content', icon: 'hugo', color: '#FF4088', fallback: 'flash', category: 'Docs', kind: 'tool', lang: 'go', caps: ['read', 'write'], auth: 'none', tools: ['build', 'new', 'serve', 'mod', 'convert', 'list'], fileTypes: ['md', 'html', 'toml', 'yaml'], enabled: false },
  { id: 'ffmpeg', name: 'ffmpeg', summary: 'Decode, transcode & filter audio/video', icon: 'ffmpeg', color: '#5CB85C', fallback: 'media-video', category: 'Media', kind: 'tool', lang: 'c', caps: ['read', 'write'], auth: 'none', tools: ['transcode', 'trim', 'probe', 'concat', 'scale', 'extract', 'thumbnail'], fileTypes: ['mp4', 'mov', 'mkv', 'wav', 'mp3', 'webm'], enabled: false },
  { id: 'pandoc', name: 'pandoc', summary: 'Convert documents between markup formats', icon: 'pandoc', color: null, fallback: 'journal-page', category: 'Docs', kind: 'tool', lang: 'haskell', caps: ['read', 'write'], auth: 'none', tools: ['convert'], fileTypes: ['md', 'docx', 'html', 'pdf', 'tex', 'epub'], enabled: false },

  // ── integration CLIs (need a connection) ─────────────────────────────────────────────────────
  { id: 'gh', name: 'GitHub', summary: 'Issues, PRs, repos & Actions from the GitHub CLI', icon: 'github', color: null, fallback: 'github', category: 'Dev & deploy', kind: 'integration', lang: 'go', caps: ['read', 'network', 'write'], auth: 'oauth', tools: ['pr', 'issue', 'repo', 'run', 'release', 'gist', 'workflow', 'auth', 'browse', 'api'], hosts: ['api.github.com'], enabled: true, connected: true },
  { id: 'stripe', name: 'Stripe', summary: 'Payments, customers & webhooks from the Stripe CLI', icon: 'stripe', color: '#635BFF', fallback: 'credit-card', category: 'Payments', kind: 'integration', lang: 'go', caps: ['read', 'network'], auth: 'api_key', tools: ['charges', 'customers', 'listen', 'products', 'prices', 'invoices', 'subscriptions', 'refunds', 'payouts', 'webhooks', 'logs'], hosts: ['api.stripe.com'], enabled: false, connected: false },
  { id: 'supabase', name: 'Supabase', summary: 'Postgres, auth & storage from the Supabase CLI', icon: 'supabase', color: '#3FCF8E', fallback: 'database', category: 'Data', kind: 'integration', lang: 'go', caps: ['read', 'network', 'write'], auth: 'oauth', tools: ['db', 'migration', 'functions', 'gen', 'secrets', 'storage', 'link', 'start', 'stop'], hosts: ['*.supabase.co'], enabled: false, connected: false },
  { id: 'railway', name: 'Railway', summary: 'Deploy & manage services from the Railway CLI', icon: 'railway', color: null, fallback: 'cloud-upload', category: 'Dev & deploy', kind: 'integration', lang: 'rust', caps: ['read', 'network'], auth: 'oauth', tools: ['up', 'logs', 'vars', 'run', 'status', 'link', 'domain', 'service'], hosts: ['backboard.railway.app'], enabled: false, connected: false },
  { id: 'vercel', name: 'Vercel', summary: 'Deploy frontends & functions from the Vercel CLI', icon: 'vercel', color: null, fallback: 'triangle-flag', category: 'Dev & deploy', kind: 'integration', lang: 'node', caps: ['read', 'network'], auth: 'oauth', tools: ['deploy', 'env', 'logs', 'dev', 'domains', 'alias', 'pull', 'rollback'], hosts: ['api.vercel.com'], enabled: false, connected: false },
  { id: 'aws', name: 'AWS', summary: 'The AWS CLI — S3, Lambda & the rest', icon: 'amazonwebservices', color: '#FF9900', fallback: 'cloud', category: 'Dev & deploy', kind: 'integration', lang: 'python', caps: ['read', 'network', 'write'], auth: 'api_key', tools: ['s3', 'lambda', 'ec2', 'iam', 'dynamodb', 'cloudformation', 'logs', 'sts', 'ecs'], hosts: ['*.amazonaws.com'], enabled: false, connected: false }
])

// the language a CLI is written in → its simple-icon slug, used as the fallback mark when a toolkit has no
// brand icon of its own (ripgrep/fd → the Rust mark). Tinted with the language's tint.
export const LANG_ICON = { rust: 'rust', go: 'go', node: 'nodedotjs', python: 'python', c: 'c', haskell: 'haskell' }

// resolve a toolkit to { ref, color } for <Glyph>: prefer the brand icon (tinted by its hand-assigned colour,
// or theme ink for neutral marks); if it has none, fall back to the language icon tinted with the lang colour.
export function markFor(t) {
  if (t.icon && iconSlugs.has(t.icon)) return { ref: `icon:${t.icon}`, color: t.color || 'var(--color-ink)' }
  const slug = LANG_ICON[t.lang]
  return { ref: slug ? `icon:${slug}` : '', color: (LANG_META[t.lang] || {}).tint || 'var(--color-ink)' }
}

export const CATEGORIES = [...new Set(toolkits.map((t) => t.category))]
export const enabledToolkits = () => toolkits.filter((t) => t.enabled)
export const toolkitsInCategory = (c) => toolkits.filter((t) => t.category === c)
