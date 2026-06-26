// The Files IDE shows a REAL Nexus user deploy — the `dogfood/` monorepo, i.e. the USER's .work
// files, not the Nexus source. The ROOT index.work is the manifest: it declares which subtrees are
// WORKSPACES (id == folder path) and the deploy config. Every folder with its own index.work is a
// SURFACE mounted at its path. The tree mirrors the Studio sidebar (cloud / lander / docs / marketing
// / admin / security). `.work` is literate Elixir-AST, so it gets Elixir highlighting in the editor.

const ROOT = `# dogfood/index.work — the deploy MANIFEST (root). Not served; it defines the TREE: which
# subtrees are workspaces, plus deploy config. Config lives here as .work — no JSON, no env vars.
# (Secrets are the exception: never here — see admin/secrets.work.)

deploy :dogfood do
  nexus  "wb-dogfood"
  region "iad"

  # A WORKSPACE is a DECLARED subtree: the id IS the on-disk folder path, so it never drifts
  # from git (/git/<id>.git) or the dashboard tree. Folders are NOT workspaces until declared here.
  workspace "cloud",       name: "Cloud",     icon: "cloud"
  workspace "site/lander", name: "Lander",    icon: "triangle-flag"
  workspace "docs",        name: "Docs",      icon: "book"
  workspace "marketing",   name: "Marketing", icon: "megaphone", scope: :private
  workspace "admin",       name: "Admin",     icon: "settings",  scope: :admin
  workspace "security",    name: "Security",  icon: "lock",      scope: :admin
end`

const README = `# wb-dogfood

The **dogfood** deploy — Workbooks serving *itself* on a nexus through the DeployKit, exactly
like a customer would.

The root \`index.work\` is the **manifest**: it declares which subtrees are **workspaces** and the
deploy config. Each folder with its own \`index.work\` is a **surface**, mounted at its path
(\`site/lander\` → \`/site/lander\`, URL = folder path, WYSIWYG).

- \`.work\` files are **literate**: prose narrates, \`do … end\` blocks run.
- Everything untrusted compiles to **WebAssembly** and runs emulated.
- Config is \`.work\`; secrets come from \`Nexus.Secrets\`; nothing sensitive is committed.`

const CLOUD_INDEX = `# cloud/index.work — a folder with an index.work is a SURFACE, mounted at /cloud.
surface :cloud do
  title   "Cloud"
  purpose "Team-wide ops, deploys & data"
end`

const GENERAL = `# A channel is a surface you talk in. Prose renders; #event tags ride the bus.
surface :general do
  purpose "Team-wide chatter"
end`

const SYSTEM = `# A system feed: a hook turns bus events into posts — no human authors here.
hook :system do
  match event: [:deploy, :billing, :failure]
  notify channel: :system, with: &summarize/1
end`

const WORKHORSE = `agent :workhorse do
  model   "claude-opus-4-8"
  purpose "General coding agent"

  memory sqlite: "memory",     rows: 1840
  index  vector: "embeddings", rows: 9200

  tool :run_tests, "mix test"
  tool :grep,      "rg --json"
end`

const DEPLOY_CHECK = `flow :deploy_check do
  trigger manual: "git ref"

  step :weave, run: "work weave . out/bundle.work"
  step :check, run: "work check out/bundle.work"

  parallel do
    step :verify, run: "work verify"
    step :audit,  run: "work why --caps"
  end

  step :gate, after: :check do
    if violations?(), do: block!("held deploy"), else: arm!(:staging)
  end
end`

const CRM = `# A resource is a typed table — the one persistent data unit (rows in Nexus.Store).
resource :customers do
  field :name,  :string
  field :email, :string
  field :plan,  :enum, values: [:free, :pro, :team]
  field :mrr,   :money
end

resource :invoices do
  field :customer, :ref, to: :customers
  field :amount,   :money
  field :status,   :enum, values: [:open, :paid]
end`

const DASH_INDEX = `# A nested folder with index.work is a nested SURFACE (an app), mounted at /cloud/dashboard.
app :dashboard do
  title   "Dashboard"
  surface "/",      to: :overview
  surface "/usage", to: :usage_chart
end

server :overview do
  metrics = Nexus.Store.all(:metrics)
  render summary(metrics)
end`

const USAGE = `client :usage_chart do
  state range: "7d"

  query series, from: :metrics, where: [range: range]

  chart :area, data: series do
    x :day
    y :tokens
  end
end`

const LANDER_INDEX = `# site/lander → mounted at /site/lander (folder path = URL, WYSIWYG, no remap layer).
surface :lander do
  title "Lander"
  theme "assets/theme.css"

  hero "Build software the way you write." do
    cta "Get started", to: "/site/lander/pricing"
  end
end`

const THEME_CSS = `:root {
  --paper: #f7f6f1;
  --ink:   #1a1b1e;
  --accent: #aee5c2;
}

.hero {
  background: var(--paper);
  color: var(--ink);
  padding: 96px 24px;
  text-align: center;
}
.hero .cta { background: var(--accent); border-radius: 12px; padding: 10px 18px; }`

const LOGO_SVG = `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">
  <rect width="48" height="48" rx="12" fill="#aee5c2"/>
  <path d="M24 12c-6 4-8 10-4 16 4-2 8-6 8-12" fill="none" stroke="#149157" stroke-width="2.5"/>
  <path d="M24 30c4-1 7-4 9-8" fill="none" stroke="#149157" stroke-width="2.5"/>
</svg>`

const DOCS_INDEX = `surface :docs do
  title   "Docs"
  purpose "How to build on Workbooks"
end`

const PUBLISH = `flow :publish do
  trigger cron: "0 9 * * 1"   # Mondays 09:00

  step :weave,  run: "work weave docs out/docs.work"
  step :deploy, run: "work deploy"
end`

const MKT_INDEX = `surface :marketing do
  title "Marketing"
  scope :private   # a private TEAM workspace — not org-wide
end`

const NEWSLETTER = `flow :newsletter do
  trigger "<2026-06-25 09:00 +1w>"   # org-style timestamp, repeats weekly

  step :draft,  run: "agent:writer compose"
  step :review, after: "1h", run: "agent:editor"
  step :send,   run: "deliver(audience())"
end`

const ADMIN_INDEX = `# Declared as an ADMIN-scope workspace in the root manifest → ROOT permissions org-wide.
surface :admin do
  title "Admin"
  scope :admin
end`

const MEMBERS = `resource :members do
  field :name,   :string
  field :role,   :enum, values: [:member, :admin]
  field :status, :enum, values: [:active, :away, :offline]
end`

const SECRETS = `# Secrets are NEVER stored in .work. This block only NAMES them; the VALUES come from
# Nexus.Secrets (injected at deploy from the encrypted org store). Safe to commit to a public repo.
secrets :org do
  require :OPENROUTER_API_KEY
  require :WB_S3_KEY
  require :WB_DATABASE_URL
end`

const PROVISIONING = `flow :provisioning do
  trigger manual: "person + action"

  step :account, run: "onboard? && create() || disable()"
  step :access,  run: "sync_workspaces()"
  step :grants,  run: "grant_or_revoke()"
  step :audit,   run: "emit(:audit, summary())"
end`

const SEC_INDEX = `surface :security do
  title "Security"
  scope :admin
end`

const ACCESS_LOGS = `resource :access_log do
  field :who,      :string
  field :action,   :enum, values: [:login, :grant, :revoke]
  field :resource, :string
  field :at,       :datetime
end`

// The IDE shows the CONTENTS of the dogfood deploy root (no wrapping folder) — index.work + README
// + the workspace subtrees sit at the top level, exactly as you'd see inside the repo's dogfood/.
export const fileTree = $state([
    { type: 'file', name: 'index.work', content: ROOT },
    { type: 'file', name: 'README.md', content: README },
    { type: 'folder', name: 'cloud', open: true, children: [
      { type: 'file', name: 'index.work', content: CLOUD_INDEX },
      { type: 'file', name: 'general.work', content: GENERAL },
      { type: 'file', name: 'system.work', content: SYSTEM },
      { type: 'file', name: 'workhorse.work', content: WORKHORSE },
      { type: 'file', name: 'deploy-check.work', content: DEPLOY_CHECK },
      { type: 'file', name: 'crm.work', content: CRM },
      { type: 'folder', name: 'dashboard', open: false, children: [
        { type: 'file', name: 'index.work', content: DASH_INDEX },
        { type: 'file', name: 'usage.work', content: USAGE }
      ]}
    ]},
    { type: 'folder', name: 'site', open: false, children: [
      { type: 'folder', name: 'lander', open: true, children: [
        { type: 'file', name: 'index.work', content: LANDER_INDEX },
        { type: 'folder', name: 'assets', open: false, children: [
          { type: 'file', name: 'theme.css', content: THEME_CSS },
          { type: 'file', name: 'logo.svg', content: LOGO_SVG }
        ]}
      ]}
    ]},
    { type: 'folder', name: 'docs', open: false, children: [
      { type: 'file', name: 'index.work', content: DOCS_INDEX },
      { type: 'file', name: 'publish.work', content: PUBLISH }
    ]},
    { type: 'folder', name: 'marketing', open: false, children: [
      { type: 'file', name: 'index.work', content: MKT_INDEX },
      { type: 'file', name: 'newsletter.work', content: NEWSLETTER }
    ]},
    { type: 'folder', name: 'admin', open: false, children: [
      { type: 'file', name: 'index.work', content: ADMIN_INDEX },
      { type: 'file', name: 'members.work', content: MEMBERS },
      { type: 'file', name: 'secrets.work', content: SECRETS },
      { type: 'file', name: 'provisioning.work', content: PROVISIONING }
    ]},
    { type: 'folder', name: 'security', open: false, children: [
      { type: 'file', name: 'index.work', content: SEC_INDEX },
      { type: 'file', name: 'access-logs.work', content: ACCESS_LOGS }
    ]}
])

// assign a stable id + path to every node (depth-first)
let _n = 0
function walk(nodes, prefix) {
  for (const node of nodes) {
    node.id = `f${++_n}`
    node.path = `${prefix}/${node.name}`
    if (node.children) walk(node.children, node.path)
  }
}
walk(fileTree, '')

export function firstFile(nodes = fileTree) {
  for (const n of nodes) {
    if (n.type === 'file') return n
    if (n.children) { const f = firstFile(n.children); if (f) return f }
  }
  return null
}

// shared editor state, so the file tree and the editor pane (separate grid cells) stay in sync.
export const fsUi = $state({ active: firstFile(), tabs: [] })
fsUi.tabs = fsUi.active ? [fsUi.active] : []

export function openFile(node) {
  fsUi.active = node
  if (!fsUi.tabs.includes(node)) fsUi.tabs.push(node)
}
export function closeFile(node) {
  const i = fsUi.tabs.indexOf(node)
  if (i < 0) return
  fsUi.tabs.splice(i, 1)
  if (fsUi.active === node) fsUi.active = fsUi.tabs[Math.min(i, fsUi.tabs.length - 1)] || null
}

// ── import: bring a directory in as a workspace subtree of the monorepo ──────────────────────────
// Both paths land a new top-level folder node = a declared workspace (id == folder path == git remote
// /git/<id>.git). The packaging/clone is mocked in the demo; the real backend reuses Nexus.Migrate
// (wrap-vs-rewrite analysis) + the git-tenant model. `git:true` marks two-way sync is armed.

// safe id/folder slug — what becomes the on-disk path AND the git remote name (kept identical).
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'imported'

// build a nested folder tree from a flat FileList (webkitRelativePath), dropping the picked root and
// any .git internals (we record that git EXISTS, but don't import its object store as files).
export function importLocalDirectory(root, files, hasGit) {
  const id = slug(root)
  const node = { type: 'folder', name: id, open: true, imported: true, git: !!hasGit, children: [] }
  let fileCount = 0

  for (const f of files) {
    const rel = (f.webkitRelativePath || f.name).split('/').slice(1) // drop the picked root segment
    if (!rel.length || rel.some((p) => p === '.git')) continue
    let dir = node
    for (let i = 0; i < rel.length - 1; i++) {
      const name = rel[i]
      let next = dir.children.find((c) => c.type === 'folder' && c.name === name)
      if (!next) { next = { type: 'folder', name, open: false, children: [] }; dir.children.push(next) }
      dir = next
    }
    dir.children.push({ type: 'file', name: rel[rel.length - 1], content: '' })
    fileCount++
  }

  fileTree.push(node)
  return { id, fileCount }
}

// track a GitHub repo as a workspace subtree. Accepts a full URL or `owner/repo`.
export function importGithubRepo(url) {
  const m = String(url).trim().match(/(?:github\.com[/:])?([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/)
  if (!m) return { ok: false }
  const id = slug(m[2])
  fileTree.push({
    type: 'folder', name: id, open: true, imported: true, git: true, github: `${m[1]}/${m[2]}`,
    children: [{ type: 'file', name: 'README.md', content: `# ${m[2]}\n\nSynced from github.com/${m[1]}/${m[2]} as a workspace subtree.\n` }]
  })
  return { ok: true, id }
}
