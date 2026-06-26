// Toolkit registry generator — turns external provider facts into our registry, mechanically.
//
//   node tools/gen-registry.mjs
//
// Source: NangoHQ/nango providers.yaml (~870 integrations) — we use only the FACTS (auth mode, network host,
// category, credential field names), never their code. ELv2: facts are reusable, the file is not redistributed
// (we fetch it at generate-time, never vendor it). On top of the Nango universe we layer a CURATED overlay:
// the CLIs we've actually identified + ported (language, capabilities, login command, brand icon/colour).
//
// Emits two artifacts:
//   • registry/toolkits.work        — the CANONICAL output (one `toolkit :id do … end` block each). Dogfood.
//   • src/lib/toolkits.generated.js  — the same data as a JS array the demo catalogue renders.
//
// Everything not in the curated overlay is an HONEST CANDIDATE: auth/hosts/category known from Nango, but
// language/CLI/port status unknown → lang:null, wasm:'planned'. The next stage (CLI detection + skill
// extraction) fills those in; until then the catalogue shows them tiered, never pretends they're ready.

import { writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const NANGO = 'https://cdn.jsdelivr.net/gh/NangoHQ/nango@master/packages/providers/providers.yaml'

// ── auth mode → our two real paths ──────────────────────────────────────────────────────────────
// oauth  → the CLI's own interactive login (terminal). env → credentials stored as env secrets.
const OAUTH = new Set(['OAUTH2', 'OAUTH1', 'OAUTH2_CC', 'MCP_OAUTH2', 'MCP_OAUTH2_GENERIC', 'APP', 'APP_STORE', 'TBA', 'INSTALL_PLUGIN', 'CUSTOM'])
const authOf = (m) => (m === 'NONE' ? 'none' : OAUTH.has(m) ? 'oauth' : 'env')

const titleCase = (s) => s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
const camelSplit = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1_$2')
const envKey = (id, field) => `${id}_${camelSplit(field)}`.toUpperCase().replace(/[^A-Z0-9]+/g, '_')

// host out of a Nango proxy base_url; null when it's a templated/dynamic domain (${connectionConfig.…})
function hostOf(url) {
  if (!url) return null
  let h = url.replace(/^https?:\/\//, '').split('/')[0]
  return h && !h.includes('${') ? h : null
}

// ── minimal targeted parser for providers.yaml (4-space indent, flat enough we don't need a YAML dep) ──
function parseNango(text) {
  const out = []
  let cur = null, section = null
  for (const raw of text.split('\n')) {
    if (!raw.trim() || raw.trimStart().startsWith('#')) continue
    const indent = raw.length - raw.trimStart().length
    const line = raw.trim()
    const val = () => line.slice(line.indexOf(':') + 1).trim().replace(/^['"]|['"]$/g, '')
    if (indent === 0 && line.endsWith(':')) {
      cur = { id: line.slice(0, -1), name: '', cats: [], auth: '', host: null, creds: [] }
      out.push(cur); section = null
    } else if (cur && indent === 4) {
      section = null
      if (line.startsWith('display_name:')) cur.name = val()
      else if (line.startsWith('auth_mode:')) cur.auth = val()
      else if (line === 'categories:') section = 'cats'
      else if (line === 'proxy:') section = 'proxy'
      else if (line === 'credentials:') section = 'creds'
    } else if (cur && indent === 8) {
      if (section === 'cats' && line.startsWith('- ')) cur.cats.push(line.slice(2).trim())
      else if (section === 'proxy' && line.startsWith('base_url:')) cur.host = hostOf(val())
      else if (section === 'creds' && line.endsWith(':')) cur.creds.push(line.slice(0, -1))
    }
  }
  return out
}

// a Nango provider → our registry candidate
function candidate(p) {
  const auth = authOf(p.auth)
  const e = {
    id: p.id,
    name: p.name || titleCase(p.id),
    summary: `${p.name || titleCase(p.id)} integration`,
    icon: p.id.replace(/[-_].*$/, ''), // best-effort simple-icon slug; resolves via CDN or falls back
    color: null, // monochrome → theme ink (curated entries override with a brand colour)
    fallback: 'cloud',
    category: p.cats[0] ? titleCase(p.cats[0]) : 'Other',
    kind: 'integration',
    lang: null, // unknown until CLI detection
    caps: auth === 'none' ? ['read'] : ['read', 'network'],
    auth,
    tools: [],
    wasm: 'planned',
    enabled: false,
    connected: false,
    candidate: true
  }
  if (auth === 'env' && p.creds.length) e.secrets = p.creds.map((f) => envKey(p.id, f))
  if (p.host) e.hosts = [p.host]
  return e
}

// ── CURATED overlay — the CLIs we've actually identified/ported. Keyed by id; merged over the candidate ──
// (these are the entries the demo started with — rich icon/colour/caps/commands/login + tool CLIs not in Nango)
const CURATED = [
  { id: 'ripgrep', name: 'ripgrep', summary: 'Blazing-fast recursive search across the workspace', icon: null, color: null, fallback: 'search', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['search', 'glob', 'count', 'replace', 'json', 'files'], fileTypes: ['any text'], wasm: 'ready', enabled: true },
  { id: 'fd', name: 'fd', summary: 'A simple, fast alternative to find', icon: null, color: null, fallback: 'folder', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['find', 'glob'], fileTypes: ['any'], wasm: 'ready', enabled: true },
  { id: 'bat', name: 'bat', summary: 'A cat clone with syntax highlighting', icon: 'bat', color: null, fallback: 'page', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['print', 'pager'], fileTypes: ['source', 'text', 'md'], wasm: 'ready', enabled: false },
  { id: 'hugo', name: 'hugo', summary: 'Static-site generator — build & render content', icon: 'hugo', color: '#FF4088', fallback: 'flash', category: 'Docs', kind: 'tool', lang: 'go', caps: ['read', 'write'], auth: 'none', tools: ['build', 'new', 'serve', 'mod', 'convert', 'list'], fileTypes: ['md', 'html', 'toml', 'yaml'], wasm: 'ready', enabled: false },
  { id: 'ffmpeg', name: 'ffmpeg', summary: 'Decode, transcode & filter audio/video', icon: 'ffmpeg', color: '#5CB85C', fallback: 'media-video', category: 'Media', kind: 'tool', lang: 'c', caps: ['read', 'write'], auth: 'none', tools: ['transcode', 'trim', 'probe', 'concat', 'scale', 'extract', 'thumbnail'], fileTypes: ['mp4', 'mov', 'mkv', 'wav', 'mp3', 'webm'], wasm: 'planned', enabled: false },
  { id: 'pandoc', name: 'pandoc', summary: 'Convert documents between markup formats', icon: 'pandoc', color: null, fallback: 'journal-page', category: 'Docs', kind: 'tool', lang: 'haskell', caps: ['read', 'write'], auth: 'none', tools: ['convert'], fileTypes: ['md', 'docx', 'html', 'pdf', 'tex', 'epub'], wasm: 'planned', enabled: false },
  { id: 'github', name: 'GitHub', summary: 'Issues, PRs, repos & Actions from the GitHub CLI', icon: 'github', color: null, fallback: 'github', category: 'Dev & deploy', kind: 'integration', lang: 'go', caps: ['read', 'network', 'write'], auth: 'oauth', loginCmd: 'gh auth login', tools: ['pr', 'issue', 'repo', 'run', 'release', 'gist', 'workflow', 'auth', 'browse', 'api'], hosts: ['api.github.com'], wasm: 'ready', enabled: true, connected: true },
  { id: 'stripe', name: 'Stripe', summary: 'Payments, customers & webhooks from the Stripe CLI', icon: 'stripe', color: '#635BFF', fallback: 'credit-card', category: 'Payments', kind: 'integration', lang: 'go', caps: ['read', 'network'], auth: 'env', secrets: ['STRIPE_API_KEY'], tools: ['charges', 'customers', 'listen', 'products', 'prices', 'invoices', 'subscriptions', 'refunds', 'payouts', 'webhooks', 'logs'], hosts: ['api.stripe.com'], wasm: 'ready', enabled: false },
  { id: 'supabase', name: 'Supabase', summary: 'Postgres, auth & storage from the Supabase CLI', icon: 'supabase', color: '#3FCF8E', fallback: 'database', category: 'Data', kind: 'integration', lang: 'go', caps: ['read', 'network', 'write'], auth: 'oauth', loginCmd: 'supabase login', tools: ['db', 'migration', 'functions', 'gen', 'secrets', 'storage', 'link', 'start', 'stop'], hosts: ['*.supabase.co'], wasm: 'ready', enabled: false },
  { id: 'railway', name: 'Railway', summary: 'Deploy & manage services from the Railway CLI', icon: 'railway', color: null, fallback: 'cloud-upload', category: 'Dev & deploy', kind: 'integration', lang: 'rust', caps: ['read', 'network'], auth: 'oauth', loginCmd: 'railway login', tools: ['up', 'logs', 'vars', 'run', 'status', 'link', 'domain', 'service'], hosts: ['backboard.railway.app'], wasm: 'ready', enabled: false },
  { id: 'vercel', name: 'Vercel', summary: 'Deploy frontends & functions from the Vercel CLI', icon: 'vercel', color: null, fallback: 'triangle-flag', category: 'Dev & deploy', kind: 'integration', lang: 'node', caps: ['read', 'network'], auth: 'oauth', loginCmd: 'vercel login', tools: ['deploy', 'env', 'logs', 'dev', 'domains', 'alias', 'pull', 'rollback'], hosts: ['api.vercel.com'], wasm: 'wip', enabled: false },
  { id: 'aws', name: 'AWS', summary: 'The AWS CLI — S3, Lambda & the rest', icon: 'amazonwebservices', color: '#FF9900', fallback: 'cloud', category: 'Dev & deploy', kind: 'integration', lang: 'python', caps: ['read', 'network', 'write'], auth: 'env', secrets: ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_DEFAULT_REGION'], tools: ['s3', 'lambda', 'ec2', 'iam', 'dynamodb', 'cloudformation', 'logs', 'sts', 'ecs'], hosts: ['*.amazonaws.com'], wasm: 'planned', enabled: false }
]

// ── serialise one entry as a .work `toolkit` block ──────────────────────────────────────────────
function toWork(t) {
  const L = [`toolkit :${t.id} do`]
  L.push(`  name ${JSON.stringify(t.name)}`)
  L.push(`  category ${JSON.stringify(t.category)}`)
  L.push(`  kind :${t.kind}`)
  if (t.lang) L.push(`  lang :${t.lang}`)
  L.push(`  auth :${t.auth}`)
  ;(t.secrets || []).forEach((s) => L.push(`  secret ${JSON.stringify(s)}`))
  if (t.loginCmd) L.push(`  login ${JSON.stringify(t.loginCmd)}`)
  ;(t.hosts || []).forEach((h) => L.push(`  host ${JSON.stringify(h)}`))
  t.caps.forEach((c) => L.push(`  cap :${c}`))
  ;(t.tools || []).forEach((c) => L.push(`  command ${JSON.stringify(c)}`))
  L.push(`  wasm :${t.wasm}`)
  L.push('end')
  return L.join('\n')
}

// ── run ─────────────────────────────────────────────────────────────────────────────────────────
const yaml = await (await fetch(NANGO)).text()
const providers = parseNango(yaml)
const curatedIds = new Set(CURATED.map((c) => c.id))

// candidates (Nango, minus anything we've curated) merged after the curated, sorted enabled-first then name
const cands = providers.filter((p) => p.id && p.name && !curatedIds.has(p.id)).map(candidate)
const all = [...CURATED.map((c) => ({ candidate: false, connected: false, ...c })), ...cands]
all.sort((a, b) => (b.enabled - a.enabled) || a.name.localeCompare(b.name))

mkdirSync(join(ROOT, 'registry'), { recursive: true })

const header = `# Toolkit registry — GENERATED by tools/gen-registry.mjs. Do not edit by hand.
# ${CURATED.length} curated CLIs + ${cands.length} Nango-sourced integration candidates = ${all.length} toolkits.
# Facts (auth · host · category · credential keys) derived from NangoHQ/nango provider data (ELv2: facts reused,
# file not redistributed). Candidates have lang:null / wasm:planned until CLI detection fills them in.\n\n`
writeFileSync(join(ROOT, 'registry', 'toolkits.work'), header + all.map(toWork).join('\n\n') + '\n')

const js = `// GENERATED by tools/gen-registry.mjs — do not edit by hand. See registry/toolkits.work for the canonical
// form. ${CURATED.length} curated CLIs + ${cands.length} Nango integration candidates.
export const generated = ${JSON.stringify(all, null, 0)}
`
writeFileSync(join(ROOT, 'src', 'lib', 'toolkits.generated.js'), js)

const byAuth = all.reduce((m, t) => ((m[t.auth] = (m[t.auth] || 0) + 1), m), {})
console.log(`✓ ${all.length} toolkits (${CURATED.length} curated + ${cands.length} candidates)`)
console.log(`  auth: ${JSON.stringify(byAuth)}`)
console.log(`  categories: ${new Set(all.map((t) => t.category)).size}`)
console.log(`  → registry/toolkits.work + src/lib/toolkits.generated.js`)
