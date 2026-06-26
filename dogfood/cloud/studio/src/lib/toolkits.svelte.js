// The toolkit registry — the catalog of CLIs the runtime can expose to agents & flows. A TOOLKIT is a
// CLI compiled to WASM (→ eventually BEAM ASM) shipped WITH its context/skills — like a CLI bundled
// with its Claude-style SKILL.md. Two facets, one schema:
//   • tool        — a pure-capability CLI, no auth (ripgrep, ffmpeg, pandoc)
//   • integration — an API-backed CLI that needs a connection (gh, stripe, supabase)
// Seeded here as a ~dozen real entries to iterate on; the production registry is generated into .work
// (facts from Nango + CLI-Anything + a dev-CLI seed). Icons resolve through OUR glyphs toolkit.
//
// Language → WASM readiness: Rust + Go compile cleanly to wasm32 today (wasmStatus 'ready'); Node is
// next ('wip'); C/Haskell/Python are 'planned'. The status drives the porting board.

// capability tier — the blast-radius vocabulary the rest of the app already uses
export const TIER_COLOR = { read: 'var(--color-mint)', network: 'var(--color-sky)', write: 'var(--color-peach)', execute: 'var(--color-fuchsia)' }
export const LANG_META = {
  rust: { label: 'Rust', tint: 'var(--color-peach)' },
  go: { label: 'Go', tint: 'var(--color-sky)' },
  node: { label: 'Node', tint: 'var(--color-mint)' },
  python: { label: 'Python', tint: 'var(--color-violet)' },
  c: { label: 'C', tint: 'var(--color-dim)' },
  haskell: { label: 'Haskell', tint: 'var(--color-dim)' }
}
export const WASM_STATUS = {
  ready: { label: 'WASM-ready', tint: 'var(--color-mint)' },
  wip: { label: 'porting', tint: 'var(--color-peach)' },
  planned: { label: 'planned', tint: 'var(--color-dim)' }
}
export const AUTH_META = {
  none: { label: 'No auth' },
  api_key: { label: 'API key' },
  oauth: { label: 'OAuth' }
}

// id, name, summary, glyph (our glyphs ref) + fallback iconoir glyph, category, kind, lang, tier,
// wasmStatus, auth, tools (the subcommands it advertises), enabled (live in sandboxes), connected (auth done).
export const toolkits = $state([
  // ── tool CLIs (no auth) ──────────────────────────────────────────────────────────────────────
  { id: 'ripgrep', name: 'ripgrep', summary: 'Blazing-fast recursive search across the workspace', glyph: 'brand:rust', fallback: 'search', category: 'Search & files', kind: 'tool', lang: 'rust', tier: 'read', wasmStatus: 'ready', auth: 'none', tools: ['search', 'glob', 'count'], enabled: true },
  { id: 'fd', name: 'fd', summary: 'A simple, fast alternative to find', glyph: 'brand:rust', fallback: 'folder', category: 'Search & files', kind: 'tool', lang: 'rust', tier: 'read', wasmStatus: 'ready', auth: 'none', tools: ['find', 'glob'], enabled: true },
  { id: 'bat', name: 'bat', summary: 'A cat clone with syntax highlighting', glyph: 'brand:rust', fallback: 'page', category: 'Search & files', kind: 'tool', lang: 'rust', tier: 'read', wasmStatus: 'ready', auth: 'none', tools: ['print', 'pager'], enabled: false },
  { id: 'hugo', name: 'hugo', summary: 'Static-site generator — build & render content', glyph: 'brand:hugo', fallback: 'flash', category: 'Docs', kind: 'tool', lang: 'go', tier: 'execute', wasmStatus: 'ready', auth: 'none', tools: ['build', 'new', 'serve'], enabled: false },
  { id: 'ffmpeg', name: 'ffmpeg', summary: 'Decode, transcode & filter audio/video', glyph: 'brand:ffmpeg', fallback: 'media-video', category: 'Media', kind: 'tool', lang: 'c', tier: 'execute', wasmStatus: 'planned', auth: 'none', tools: ['transcode', 'trim', 'probe'], enabled: false },
  { id: 'pandoc', name: 'pandoc', summary: 'Convert documents between markup formats', glyph: 'brand:markdown', fallback: 'journal-page', category: 'Docs', kind: 'tool', lang: 'haskell', tier: 'execute', wasmStatus: 'planned', auth: 'none', tools: ['convert'], enabled: false },

  // ── integration CLIs (need a connection) ─────────────────────────────────────────────────────
  { id: 'gh', name: 'GitHub', summary: 'Issues, PRs, repos & Actions from the GitHub CLI', glyph: 'brand:github', fallback: 'github', category: 'Dev & deploy', kind: 'integration', lang: 'go', tier: 'write', wasmStatus: 'ready', auth: 'oauth', tools: ['pr', 'issue', 'repo', 'run'], enabled: true, connected: true },
  { id: 'stripe', name: 'Stripe', summary: 'Payments, customers & webhooks from the Stripe CLI', glyph: 'brand:stripe', fallback: 'credit-card', category: 'Payments', kind: 'integration', lang: 'go', tier: 'write', wasmStatus: 'ready', auth: 'api_key', tools: ['charges', 'customers', 'listen'], enabled: false, connected: false },
  { id: 'supabase', name: 'Supabase', summary: 'Postgres, auth & storage from the Supabase CLI', glyph: 'brand:supabase', fallback: 'database', category: 'Data', kind: 'integration', lang: 'go', tier: 'write', wasmStatus: 'ready', auth: 'oauth', tools: ['db', 'migration', 'functions'], enabled: false, connected: false },
  { id: 'railway', name: 'Railway', summary: 'Deploy & manage services from the Railway CLI', glyph: 'brand:railway', fallback: 'cloud-upload', category: 'Dev & deploy', kind: 'integration', lang: 'rust', tier: 'execute', wasmStatus: 'ready', auth: 'oauth', tools: ['up', 'logs', 'vars'], enabled: false, connected: false },
  { id: 'vercel', name: 'Vercel', summary: 'Deploy frontends & functions from the Vercel CLI', glyph: 'brand:vercel', fallback: 'triangle-flag', category: 'Dev & deploy', kind: 'integration', lang: 'node', tier: 'execute', wasmStatus: 'wip', auth: 'oauth', tools: ['deploy', 'env', 'logs'], enabled: false, connected: false },
  { id: 'aws', name: 'AWS', summary: 'The AWS CLI — S3, Lambda & the rest', glyph: 'brand:aws', fallback: 'cloud', category: 'Dev & deploy', kind: 'integration', lang: 'python', tier: 'execute', wasmStatus: 'planned', auth: 'api_key', tools: ['s3', 'lambda', 'ec2'], enabled: false, connected: false }
])

export const CATEGORIES = [...new Set(toolkits.map((t) => t.category))]
export const enabledToolkits = () => toolkits.filter((t) => t.enabled)
export const toolkitsInCategory = (c) => toolkits.filter((t) => t.category === c)
