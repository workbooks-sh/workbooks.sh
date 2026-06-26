// The toolkit registry — the catalog of CLIs the runtime can expose to agents & flows. A TOOLKIT is a
// CLI compiled to WASM (→ eventually BEAM ASM) shipped WITH its context/skills — like a CLI bundled
// with its Claude-style SKILL.md. Two facets, one schema:
//   • tool        — a pure-capability CLI, no auth (ripgrep, ffmpeg, pandoc)
//   • integration — an API-backed CLI that needs a connection (gh, stripe, supabase)
// Seeded here as a ~dozen real entries to iterate on; the production registry is generated into .work
// (facts from Nango + CLI-Anything + a dev-CLI seed). Icons resolve through OUR glyphs toolkit.

import { generated } from './toolkits.generated.js'

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
  cpp: { label: 'C++', tint: 'var(--color-sky)' },
  zig: { label: 'Zig', tint: 'var(--color-peach)' },
  haskell: { label: 'Haskell', tint: 'var(--color-dim)' }
}
// How a toolkit gets its access. `none` shows no badge. `env` = credentials stored as env-var secrets on the
// machine (an API key or several). `oauth` = the CLI's own interactive login — we DON'T broker OAuth; we drop
// the user into a terminal and they run the CLI's `login` to authenticate THEIR machine, exactly as they would
// locally (and as their own users will when they vendor this). badge = the top tag; verb = the card's action.
export const AUTH_META = {
  none: null,
  env: { badge: 'env', verb: 'Add credentials', icon: 'key' },
  oauth: { badge: 'oauth', verb: 'Authenticate', icon: 'terminal' }
}

// secret scope — who the stored credentials apply to. Seeds the policy structure we'll formalise later.
export const SCOPES = [
  { id: 'personal', label: 'Just me', detail: 'Only your sessions use these credentials.' },
  { id: 'org', label: 'Organisation', detail: 'Everyone in the org shares this connection.' },
  { id: 'admin', label: 'Admin-locked', detail: 'Set by an admin; members can use but not change it.' }
]

// the in-memory secret vault for the demo: toolkitId -> { scope, values: { KEY: 'value' } }. In production
// these are written to the org-scoped encrypted env store (Nexus.Secrets), never to source/.work.
export const secretVault = $state({})

// connection state for an enabled toolkit. none ⇒ nothing to do. env ⇒ satisfied once every required secret has
// a value. oauth ⇒ satisfied once the CLI login completed (t.connected). Returns what the card should render.
export function connState(t) {
  const a = t.auth
  if (a === 'none' || !AUTH_META[a]) return { needs: false }
  if (t.connected) return { ok: true, label: 'Connected' }
  return { needs: true, kind: a, label: AUTH_META[a].verb, icon: AUTH_META[a].icon }
}

// The registry is GENERATED (tools/gen-registry.mjs → toolkits.generated.js): our curated CLIs + ~870 Nango
// integration candidates. Canonical form lives in registry/toolkits.work. Each entry:
//   id, name, summary, icon, color, fallback, category, kind, lang, caps[], auth, tools, wasm, enabled, connected
//   + optional secrets[] (env), loginCmd (oauth), hosts[], fileTypes[], candidate (true ⇒ not yet CLI-verified)
export const toolkits = $state(generated)

// the language a CLI is written in → its simple-icon slug, used as the fallback mark when a toolkit has no
// brand icon of its own (ripgrep/fd → the Rust mark). Tinted with the language's tint.
export const LANG_ICON = { rust: 'rust', go: 'go', node: 'nodedotjs', python: 'python', c: 'c', cpp: 'cplusplus', zig: 'zig', haskell: 'haskell' }

// resolve a toolkit to { ref, color } for <Glyph>: prefer the brand icon (vendored sync, else simple-icons via
// CDN, tinted by its hand-assigned colour or theme ink); if it has none, fall back to the language icon tinted
// with the lang colour; failing that, Glyph renders the iconoir `fallback`.
// `ink` = recolour the mark to `color` (computed luminance-aware in the generator): true for monochrome
// simple-icons/language marks and for logos that are too dark to read; false for full-colour logos (as-is).
export function markFor(t) {
  if (t.logo) return { ref: `logo:${t.id}`, color: t.color || 'var(--color-ink)', ink: !!t.ink }
  if (t.icon) return { ref: `icon:${t.icon}`, color: t.color || 'var(--color-ink)', ink: true }
  const slug = LANG_ICON[t.lang]
  return { ref: slug ? `icon:${slug}` : '', color: (LANG_META[t.lang] || {}).tint || 'var(--color-ink)', ink: true }
}

export const enabledToolkits = () => toolkits.filter((t) => t.enabled)

// ── providers ─────────────────────────────────────────────────────────────────────────────────
// One provider groups all its connections (variants) — the generator tags each toolkit with `provider`.
// The catalogue shows ONE card per provider; multi-connection providers open a detail drawer where each
// connection is toggled. The variant objects are live refs into the `toolkits` $state, so toggles stay reactive.
const _byProvider = new Map()
for (const t of toolkits) { if (!_byProvider.has(t.provider)) _byProvider.set(t.provider, []); _byProvider.get(t.provider).push(t) }
export const providers = [..._byProvider].map(([id, variants]) => {
  const rep = variants.slice().sort((a, b) => (b.logo ? 1 : 0) - (a.logo ? 1 : 0) || (b.icon ? 1 : 0) - (a.icon ? 1 : 0) || a.name.length - b.name.length)[0]
  const caps = CAP_ORDER.filter((c) => variants.some((v) => (v.caps || []).includes(c)))
  return { id, name: rep.providerName || rep.name, category: rep.category, kind: rep.kind, rep, variants, caps }
})

// ── layers ────────────────────────────────────────────────────────────────────────────────────
// The catalogue divides into three layers by `kind`, switched at the top of the sidebar so the ~870
// auth integrations never drown the curated tools/skills:
//   • skill       — a pure context bundle (SKILL.md), no executable, no auth
//   • tool        — a CLI compiled to WASM, ships skills, touches no third party (no auth)
//   • integration — a CLI + skills that needs a connection (env secret / the CLI's own oauth login)
export const LAYERS = [
  { id: 'skill', label: 'Skills', icon: 'sparks', blurb: 'Context packs (SKILL.md) — no executable, no auth' },
  { id: 'tool', label: 'Tools', icon: 'tools', blurb: 'CLIs compiled to WASM that touch no third party — no auth' },
  { id: 'integration', label: 'Integrations', icon: 'cloud', blurb: 'CLIs that need a connection — an env secret or the CLI’s own login' }
]
export const providersInLayer = (layer) => providers.filter((p) => p.kind === layer)
export const providerCount = (layer) => providersInLayer(layer).length
export const categoriesInLayer = (layer) => [...new Set(providersInLayer(layer).map((p) => p.category))].sort((a, b) => a.localeCompare(b))
export const providersInLayerCategory = (layer, c) => providers.filter((p) => p.kind === layer && p.category === c)
// the connection's label within its provider — the parenthetical, or "Default" for the bare one
export const variantType = (v, providerName) => {
  const extra = v.name.replace(providerName, '').replace(/^[\s(]+|[)\s]+$/g, '').trim()
  return extra || 'Default'
}
export const providerById = (id) => providers.find((p) => p.id === id)
export const connectedProviders = () => providers.filter((p) => p.variants.some((v) => v.enabled))
export const providersInCategory = (c) => providers.filter((p) => p.category === c)

export const CATEGORIES = [...new Set(providers.map((p) => p.category))].sort((a, b) => a.localeCompare(b))
export const toolkitsInCategory = (c) => toolkits.filter((t) => t.category === c)
