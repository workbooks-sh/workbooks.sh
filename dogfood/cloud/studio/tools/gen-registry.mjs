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

import { writeFileSync, mkdirSync, readFileSync } from 'node:fs'
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

// ── TOOLS overlay — standalone CLIs that touch NO third party (no auth). They compile to WASM and ship their
// skills; pure local utilities. Curated from the awesome-cli / rust-command-line-utilities research, filtered to
// wasm-friendly languages (rust/go/zig/c). kind:'tool'. These are what keeps the "no-auth" layer real. ──────
const TOOLS = [
  { id: 'jq', name: 'jq', summary: 'Command-line JSON processor — slice, filter & transform', icon: 'jquery', color: null, fallback: 'code-brackets', category: 'Data', kind: 'tool', lang: 'c', caps: ['read'], auth: 'none', tools: ['filter', 'select', 'map', 'keys', 'length', 'flatten', 'group', 'sort'], fileTypes: ['json'], wasm: 'ready' },
  { id: 'yq', name: 'yq', summary: 'Like jq, but for YAML / TOML / XML', icon: null, color: null, fallback: 'code-brackets', category: 'Data', kind: 'tool', lang: 'go', caps: ['read'], auth: 'none', tools: ['eval', 'merge', 'select', 'convert'], fileTypes: ['yaml', 'toml', 'xml', 'json'], wasm: 'ready' },
  { id: 'fzf', name: 'fzf', summary: 'A general-purpose fuzzy finder', icon: null, color: null, fallback: 'search', category: 'Search & files', kind: 'tool', lang: 'go', caps: ['read'], auth: 'none', tools: ['filter', 'select', 'preview'], fileTypes: ['any'], wasm: 'ready' },
  { id: 'sd', name: 'sd', summary: 'Intuitive find & replace (a saner sed)', icon: null, color: null, fallback: 'edit-pencil', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read', 'write'], auth: 'none', tools: ['replace', 'preview'], fileTypes: ['any text'], wasm: 'ready' },
  { id: 'eza', name: 'eza', summary: 'A modern replacement for ls', icon: null, color: null, fallback: 'list', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['list', 'tree', 'long'], fileTypes: ['any'], wasm: 'ready' },
  { id: 'delta', name: 'delta', summary: 'A syntax-highlighting pager for git & diff output', icon: null, color: null, fallback: 'git-compare', category: 'Dev Tools', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['diff', 'blame'], fileTypes: ['diff', 'source'], wasm: 'ready' },
  { id: 'tokei', name: 'tokei', summary: 'Count code, comments & blanks across a project, fast', icon: null, color: null, fallback: 'reports', category: 'Dev Tools', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['count', 'languages', 'sort'], fileTypes: ['source'], wasm: 'ready' },
  { id: 'hyperfine', name: 'hyperfine', summary: 'A command-line benchmarking tool', icon: null, color: null, fallback: 'timer', category: 'Dev Tools', kind: 'tool', lang: 'rust', caps: ['read', 'spawn'], auth: 'none', tools: ['benchmark', 'warmup', 'export'], fileTypes: ['any'], wasm: 'planned' },
  { id: 'dust', name: 'dust', summary: 'A more intuitive du — disk usage by directory', icon: null, color: null, fallback: 'reports', category: 'Search & files', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['size', 'tree'], fileTypes: ['any'], wasm: 'ready' },
  { id: 'qsv', name: 'qsv', summary: 'A fast CSV data-wrangling toolkit', icon: null, color: null, fallback: 'table', category: 'Data', kind: 'tool', lang: 'rust', caps: ['read', 'write'], auth: 'none', tools: ['select', 'search', 'join', 'stats', 'frequency', 'sort', 'dedup', 'slice'], fileTypes: ['csv', 'tsv'], wasm: 'ready' },
  { id: 'glow', name: 'glow', summary: 'Render markdown on the CLI, with style', icon: null, color: null, fallback: 'journal-page', category: 'Docs', kind: 'tool', lang: 'go', caps: ['read'], auth: 'none', tools: ['render', 'page'], fileTypes: ['md'], wasm: 'ready' },
  { id: 'ast-grep', name: 'ast-grep', summary: 'Structural search & rewrite by syntax tree', icon: null, color: null, fallback: 'search', category: 'Dev Tools', kind: 'tool', lang: 'rust', caps: ['read', 'write'], auth: 'none', tools: ['run', 'scan', 'rewrite', 'test'], fileTypes: ['source'], wasm: 'ready' },
  { id: 'difftastic', name: 'difftastic', summary: 'A structural diff that understands syntax', icon: null, color: null, fallback: 'git-compare', category: 'Dev Tools', kind: 'tool', lang: 'rust', caps: ['read'], auth: 'none', tools: ['diff'], fileTypes: ['source'], wasm: 'ready' },
  { id: 'imagemagick', name: 'ImageMagick', summary: 'Create, convert & edit raster images', icon: 'imagemagick', color: null, fallback: 'media-image', category: 'Media', kind: 'tool', lang: 'c', caps: ['read', 'write'], auth: 'none', tools: ['convert', 'resize', 'crop', 'composite', 'montage', 'identify'], fileTypes: ['png', 'jpg', 'gif', 'webp', 'tiff'], wasm: 'planned' },
  { id: 'graphviz', name: 'Graphviz', summary: 'Render graphs from DOT descriptions', icon: 'graphviz', color: null, fallback: 'network', category: 'Media', kind: 'tool', lang: 'c', caps: ['read', 'write'], auth: 'none', tools: ['dot', 'neato', 'render'], fileTypes: ['dot', 'svg', 'png'], wasm: 'ready' },
  { id: 'sqlite', name: 'SQLite', summary: 'A self-contained SQL database engine', icon: 'sqlite', color: '#003B57', fallback: 'database', category: 'Data', kind: 'tool', lang: 'c', caps: ['read', 'write'], auth: 'none', tools: ['query', 'import', 'export', 'schema', 'dump'], fileTypes: ['sqlite', 'db', 'sql', 'csv'], wasm: 'ready' }
]

// ── TOOLS corpus — the long tail of wasm-portable CLIs enriched by tools/enrich-tools.mjs into
// tools/data/cli-tools.json (toolleeo spine → GitHub facts → wasm-friendly langs ≥100★). Honest CANDIDATES:
// lang/category/stars known, but commands + exact caps land only when the CLI is actually ported (wasm:planned).
// The 79 raw CSV categories are bucketed into a tight set so the sidebar stays navigable. ──────────────────
const TOOL_CAT = {
  'Networking': 'Networking', 'Transfer': 'Networking', 'Torrent': 'Networking', 'Online': 'Networking', 'Email': 'Networking', 'Chat': 'Networking', 'Browser': 'Networking', 'Rss': 'Networking',
  'Git': 'Dev Tools', 'Programming': 'Dev Tools', 'Terminal': 'Dev Tools', 'Editors': 'Dev Tools', 'Launcher': 'Dev Tools', 'Webdev': 'Dev Tools', 'Shells': 'Dev Tools', 'Package Manager': 'Dev Tools', 'Utility': 'Dev Tools', 'Option Picker': 'Dev Tools', 'Programming Boilerplate': 'Dev Tools', 'Diff': 'Dev Tools', 'History': 'Dev Tools', 'Versioning': 'Dev Tools',
  'Devops': 'DevOps & cloud', 'Vm': 'DevOps & cloud',
  'Monitor': 'System & security', 'Monitor Top': 'System & security', 'System': 'System & security', 'Security': 'System & security', 'Password Manager': 'System & security', 'Backup': 'System & security',
  'Data Management Json': 'Data', 'Data Management Tabular': 'Data', 'Data Management': 'Data', 'Calc': 'Data', 'Science': 'Data', 'Conversion': 'Data',
  'Viewers': 'Search & files', 'File Manager': 'Search & files', 'Text Search': 'Search & files', 'Text Search Replace': 'Search & files', 'Disk Analyzer': 'Search & files', 'File Handling': 'Search & files', 'Ls': 'Search & files', 'Cd': 'Search & files', 'Rm': 'Search & files', 'Find': 'Search & files', 'File Watch': 'Search & files', 'File Explorer': 'Search & files', 'File Dir Cleanup': 'Search & files', 'File Renamer': 'Search & files', 'File System': 'Search & files',
  'Graphics': 'Media', 'Animation': 'Media', 'Music': 'Media', 'Video': 'Media', 'Screen Recorder': 'Media', 'Screensaver': 'Media', 'Font': 'Media',
  'Text Processing': 'Docs', 'Markdown': 'Docs', 'Writing': 'Docs', 'Note Taking': 'Docs', 'Office': 'Docs', 'Cheatsheet': 'Docs',
  'Todo Manager': 'Productivity', 'Time Tracker': 'Productivity', 'Financial': 'Productivity', 'Copy Paste': 'Productivity', 'Organizers': 'Productivity', 'Flashcard': 'Productivity', 'Learning': 'Productivity', 'Productivity': 'Productivity',
  'Games': 'Games & fun', 'Funny': 'Games & fun', 'Typing': 'Games & fun',
  'Ai': 'AI', 'Copilot': 'AI', 'Prompt': 'AI', 'Ai Cli Commands': 'AI'
}
function loadToolsCorpus() {
  let recs = []
  try { recs = JSON.parse(readFileSync(join(ROOT, 'tools', 'data', 'cli-tools.json'), 'utf8')) } catch { return [] }
  return recs.map((r) => ({
    id: r.id, name: r.name, summary: r.summary || `${r.name} — command-line tool`,
    icon: null, color: null, fallback: 'terminal', category: TOOL_CAT[r.category] || 'Dev Tools',
    kind: 'tool', lang: r.lang, caps: ['read'], auth: 'none', tools: [],
    stars: r.stars, license: r.license, repo: r.repo, wasm: 'planned', enabled: false, connected: false, candidate: true
  }))
}

// ── SKILLS overlay — pure context bundles (a SKILL.md prompt pack), NO executable & NO auth: kind:'skill'.
// Ingested from anthropics/skills (Apache-2.0) via jsDelivr's tree API (no GitHub ratelimit). We read each
// skill's name/description from its frontmatter; facts only, the files are not vendored. ───────────────────
const SKILLS_REPO = 'anthropics/skills@main'
function walkSkillDirs(node, prefix, out) {
  for (const f of node.files || []) {
    const p = prefix ? prefix + '/' + f.name : f.name
    if (f.type === 'directory') walkSkillDirs(f, p, out)
    else if (f.name === 'SKILL.md') out.push(prefix)
  }
  return out
}
function frontmatter(md) {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/)
  const o = {}
  if (m) for (const line of m[1].split('\n')) { const i = line.indexOf(':'); if (i > 0) o[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^['"]|['"]$/g, '') }
  return o
}
async function loadSkills() {
  try {
    const tree = await (await fetch('https://data.jsdelivr.com/v1/packages/gh/' + SKILLS_REPO)).json()
    const dirs = walkSkillDirs(tree, '', []).filter(Boolean)
    const out = []
    for (let i = 0; i < dirs.length; i += 20) {
      await Promise.all(dirs.slice(i, i + 20).map(async (dir) => {
        try {
          const md = await (await fetch('https://cdn.jsdelivr.net/gh/' + SKILLS_REPO + '/' + dir + '/SKILL.md')).text()
          const fm = frontmatter(md)
          const seg = dir.split('/'); const slug = seg[seg.length - 1]
          out.push({
            id: 'skill-' + norm(dir), name: fm.name ? titleCase(fm.name) : titleCase(slug),
            summary: fm.description ? fm.description.split('. ')[0].slice(0, 140) : titleCase(slug) + ' skill',
            icon: null, color: null, fallback: 'journal-page', category: titleCase(seg[0].replace(/-skills?$/, '')) || 'Skills',
            kind: 'skill', lang: null, caps: [], auth: 'none', tools: [], wasm: 'ready', enabled: false, connected: false, candidate: false
          })
        } catch {}
      }))
      process.stdout.write('s')
    }
    return out
  } catch { return [] }
}

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
const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, '')
const yaml = await (await fetch(NANGO)).text()
const providers = parseNango(yaml)
const overlay = [...CURATED, ...TOOLS] // hand-authored entries (tools + integrations) shadow Nango candidates
const curatedIds = new Set(overlay.map((c) => c.id))
const curatedNames = new Set(overlay.map((c) => norm(c.name))) // dedup the corpus against hand-curated tools
const skills = await loadSkills()
process.stdout.write('\n')

// the long-tail tools corpus, minus anything we already curated by hand (ripgrep, jq, …)
const corpus = loadToolsCorpus().filter((t) => !curatedIds.has(t.id) && !curatedNames.has(norm(t.name)))
// candidates (Nango, minus anything we've curated) merged after the curated, sorted enabled-first then name
const cands = providers.filter((p) => p.id && p.name && !curatedIds.has(p.id)).map(candidate)
const all = [...overlay.map((c) => ({ candidate: false, connected: false, ...c })), ...skills, ...corpus, ...cands]
all.sort((a, b) => (b.enabled - a.enabled) || a.name.localeCompare(b.name))

// ── icon enrichment ─────────────────────────────────────────────────────────────────────────────
// Nango ships a full-colour logo per provider, keyed 1:1 by id (template-logos/<id>.svg) — the primary
// source. simple-icons gives the official brand hex for tinting mono marks / the long tail. We vendor the
// Nango logos locally (download once, keep them) and tag every entry with a brand colour where we can find
// one. Curated entries keep their hand-set icon/colour.
const NANGO_LOGO = 'https://cdn.jsdelivr.net/gh/NangoHQ/nango@master/packages/webapp/public/images/template-logos/'
const siData = await (await fetch('https://cdn.jsdelivr.net/npm/simple-icons@latest/data/simple-icons.json')).json()
const siHex = {}
for (const s of siData) { const h = '#' + s.hex; siHex[s.slug] = h; siHex[norm(s.title)] = h }

const logos = {}
const grab = async (id) => { try { const r = await fetch(NANGO_LOGO + id + '.svg'); if (!r.ok) return; const s = (await r.text()).trim(); if (s.startsWith('<svg')) logos[id] = s } catch {} }
const ids = all.filter((t) => t.candidate && !t.id.startsWith('cli-')).map((t) => t.id) // Nango candidates only have template logos
for (let i = 0; i < ids.length; i += 30) { await Promise.all(ids.slice(i, i + 30).map(grab)); process.stdout.write('.') }
process.stdout.write('\n')

// ── luminance-aware icon colour decision ────────────────────────────────────────────────────────
// A brand logo is left AS-IS when it has an element bright enough to read on a dark tile (a light part, or a
// vivid-enough colour). When the WHOLE mark is dark/neutral (black, grey, dark blue) it would vanish, so we
// INK it: rewrite its fills to a single visible colour — the brand colour if that's bright enough, else theme
// ink (currentColor, theme-aware). This also kills the "white circle" blob (dark-bg + light-fg logos now read
// as as-is: the dark bg melts into the tile and the light glyph shows).
const NAMED = { white: [255, 255, 255], black: [0, 0, 0], red: [255, 0, 0], green: [0, 128, 0], blue: [0, 0, 255], yellow: [255, 255, 0], orange: [255, 165, 0], purple: [128, 0, 128], gray: [128, 128, 128], grey: [128, 128, 128], silver: [192, 192, 192], navy: [0, 0, 128], teal: [0, 128, 128], cyan: [0, 255, 255], magenta: [255, 0, 255], pink: [255, 192, 203], lime: [0, 255, 0], maroon: [128, 0, 0], olive: [128, 128, 0], aqua: [0, 255, 255], fuchsia: [255, 0, 255] }
const parseColor = (c) => {
  c = c.toLowerCase().trim()
  if (c[0] === '#') { let h = c.slice(1); if (h.length === 3) h = h.split('').map((x) => x + x).join(''); if (h.length < 6) return null; return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)] }
  if (c.startsWith('rgb')) { const n = (c.match(/[\d.]+/g) || []).map(Number); return n.length >= 3 ? [n[0], n[1], n[2]] : null }
  return NAMED[c] || null
}
const lum = ([r, g, b]) => (0.299 * r + 0.587 * g + 0.114 * b) / 255
const sat = ([r, g, b]) => Math.max(r, g, b) - Math.min(r, g, b)
const usable = (hex) => { const c = parseColor(hex); return c ? (lum(c) >= 0.3 && lum(c) <= 0.86) : false }
function fillsOf(svg) {
  const out = []; const re = /(?:fill|stop-color)\s*[:=]\s*["']?\s*(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|[a-zA-Z]{3,20})/g; let m
  while ((m = re.exec(svg))) { const c = parseColor(m[1]); if (c) out.push(c) } // parseColor returns null for none/url/currentColor
  return out
}
function analyzeLogo(svg) {
  // embedded raster (PNG/JPEG <image>) or a pattern/gradient fill (url(#…)) ⇒ full-colour by construction;
  // render as-is (inking would overwrite the url() reference and leave a blank box).
  if (/<image\b/i.test(svg) || /fill\s*=\s*["']?\s*url\(/i.test(svg)) return { ink: false }
  const fills = fillsOf(svg)
  if (!fills.length) return { ink: true } // no fills ⇒ defaults to black ⇒ ink
  const maxAll = Math.max(...fills.map(lum))
  const chromas = fills.filter((c) => sat(c) > 24)
  const maxChroma = chromas.length ? Math.max(...chromas.map(lum)) : 0
  if (maxAll >= 0.7) return { ink: false } // a light element exists → reads on dark as-is
  if (chromas.length && maxChroma >= 0.3) return { ink: false } // colourful enough
  return { ink: true } // uniformly dark / neutral → recolour
}
function brandColorFor(name, icon, svg) {
  let c = siHex[norm(name)] || siHex[icon || ''] || null
  if (c && usable(c)) return c
  // else extract the most-saturated mid-bright fill from the logo as the brand colour
  let best = null, bestSat = -1
  for (const f of fillsOf(svg || '')) { const s = sat(f), l = lum(f); if (s > bestSat && l >= 0.3 && l <= 0.86) { bestSat = s; best = f } }
  return best ? '#' + best.map((x) => x.toString(16).padStart(2, '0')).join('') : null
}

for (const t of all) {
  if (t.candidate && logos[t.id]) { t.logo = true; t.icon = null } // full Nango brand logo
  if (t.logo) {
    const a = analyzeLogo(logos[t.id])
    t.ink = a.ink
    t.color = a.ink ? brandColorFor(t.name, t.icon, logos[t.id]) : null
  } else {
    t.ink = true // simple-icon / language marks are monochrome → tinted
    const c = brandColorFor(t.name, t.icon, '')
    t.color = c && usable(c) ? c : (t.color && usable(t.color) ? t.color : null)
  }
}
mkdirSync(join(ROOT, 'src', 'lib', 'glyphs'), { recursive: true })
writeFileSync(join(ROOT, 'src', 'lib', 'glyphs', 'toolkit-logos.json'), JSON.stringify(logos))
const withMark = all.filter((t) => t.logo || t.icon).length

// ── provider grouping ───────────────────────────────────────────────────────────────────────────
// A provider can expose several connections (Notion · Notion MCP · Notion SCIM; 1Password Events · SCIM).
// Group them under one provider so the catalogue shows ONE card per provider. Mechanical v1: group by the base
// name (everything before the first " ("). Host-domain merging + manual family passes (Apple, Google…) next.
// PROVIDER_OVERRIDE lets us hand-assign the stragglers later: { toolkitId: 'provider-id' }.
const PROVIDER_OVERRIDE = {}
const baseName = (name) => name.split(' (')[0].trim()
for (const t of all) {
  const pid = PROVIDER_OVERRIDE[t.id] || norm(baseName(t.name))
  t.provider = pid
}
// representative display name per provider = the shortest member name (the base), preferring one with a logo
const groups = {}
for (const t of all) (groups[t.provider] ||= []).push(t)
for (const members of Object.values(groups)) {
  const rep = members.slice().sort((a, b) => (b.logo ? 1 : 0) - (a.logo ? 1 : 0) || a.name.length - b.name.length)[0]
  for (const t of members) t.providerName = baseName(rep.name)
}
const multi = Object.values(groups).filter((m) => m.length > 1)

mkdirSync(join(ROOT, 'registry'), { recursive: true })

const byKind = all.reduce((m, t) => ((m[t.kind] = (m[t.kind] || 0) + 1), m), {})
const header = `# Toolkit registry — GENERATED by tools/gen-registry.mjs. Do not edit by hand.
# ${all.length} toolkits across three layers — skill:${byKind.skill || 0} · tool:${byKind.tool || 0} · integration:${byKind.integration || 0}.
# Skills from anthropics/skills (Apache-2.0); tools curated wasm-friendly CLIs; integration facts (auth · host ·
# category · credential keys) from NangoHQ/nango (ELv2: facts reused, file not redistributed). Candidates have
# lang:null / wasm:planned until CLI detection fills them in.\n\n`
writeFileSync(join(ROOT, 'registry', 'toolkits.work'), header + all.map(toWork).join('\n\n') + '\n')

const js = `// GENERATED by tools/gen-registry.mjs — do not edit by hand. See registry/toolkits.work for the canonical
// form. ${all.length} toolkits — skill:${byKind.skill || 0} · tool:${byKind.tool || 0} · integration:${byKind.integration || 0}.
export const generated = ${JSON.stringify(all, null, 0)}
`
writeFileSync(join(ROOT, 'src', 'lib', 'toolkits.generated.js'), js)

const byAuth = all.reduce((m, t) => ((m[t.auth] = (m[t.auth] || 0) + 1), m), {})
console.log(`✓ ${all.length} toolkits — skill:${byKind.skill || 0} · tool:${byKind.tool || 0} · integration:${byKind.integration || 0}`)
console.log(`  auth: ${JSON.stringify(byAuth)}`)
console.log(`  categories: ${new Set(all.map((t) => t.category)).size}`)
console.log(`  icons: ${Object.keys(logos).length} Nango logos vendored · ${all.filter((t) => t.color).length} with brand colour · ${withMark}/${all.length} marked`)
console.log(`  providers: ${Object.keys(groups).length} (${multi.length} multi-connection, e.g. ${multi.sort((a, b) => b.length - a.length).slice(0, 5).map((m) => m[0].providerName + '×' + m.length).join(', ')})`)
console.log(`  → registry/toolkits.work + src/lib/toolkits.generated.js + glyphs/toolkit-logos.json`)
