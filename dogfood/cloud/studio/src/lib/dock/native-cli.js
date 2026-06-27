// TIER-1 native-CLI harness — the counterpart to cli-engine.js (tier-2 spec-based). These 98 providers ship
// an OFFICIAL CLI; we integrate by compiling the REAL binary to wasm and running it in the sandbox. The host
// supplies the network (fetch to the provider's API host), the SECRET (injected via Nexus.Secrets — secrets.js,
// never in the guest image), and a virtual FS for config/token files. (registry/native-cli-integration.work.)
//
// In THIS demo we model each CLI's real verb surface + auth wiring and call the API directly — cause-and-effect
// matches the binary (e.g. `gh repo vercel/next.js` shows the repo) while the binary itself is emulated. The
// REUSABLE, REAL part is the harness: secret resolution -> authed request plan (pure) -> host fetch -> render.
import { secrets } from './secrets.js'

// Tier-A profiles (wasm-ready Go/Rust + headless token auth — port-first). `secret` is the env var the host
// injects via Nexus.Secrets; `optional` means the API allows unauthenticated reads (so the demo runs green).
export const PROFILES = {
  gh: {
    provider: 'github', bin: 'gh', lang: 'go', secret: 'GITHUB_TOKEN', optional: true,
    host: 'https://api.github.com', auth: { type: 'bearer' },
    verbs: {
      repo: { method: 'GET', path: '/repos/{slug}', arg: 'slug', summary: 'view a repo (owner/name)' },
      user: { method: 'GET', path: '/users/{user}', arg: 'user', summary: 'view a user' },
      api: { method: 'GET', path: '/{path}', arg: 'path', summary: 'raw API GET' }
    }
  },
  sentry: {
    provider: 'sentry', bin: 'sentry-cli', lang: 'rust', secret: 'SENTRY_AUTH_TOKEN',
    host: 'https://sentry.io', auth: { type: 'bearer' },
    verbs: {
      projects: { method: 'GET', path: '/api/0/projects/', summary: 'list projects' },
      orgs: { method: 'GET', path: '/api/0/organizations/', summary: 'list organizations' }
    }
  },
  resend: {
    provider: 'resend', bin: 'resend', lang: 'go', secret: 'RESEND_API_KEY',
    host: 'https://api.resend.com', auth: { type: 'bearer' },
    verbs: {
      domains: { method: 'GET', path: '/domains', summary: 'list verified domains' },
      apikeys: { method: 'GET', path: '/api-keys', summary: 'list API keys' }
    }
  },
  doctl: {
    provider: 'digitalocean', bin: 'doctl', lang: 'go', secret: 'DIGITALOCEAN_ACCESS_TOKEN',
    host: 'https://api.digitalocean.com', auth: { type: 'bearer' },
    verbs: {
      account: { method: 'GET', path: '/v2/account', summary: 'show account info' },
      droplets: { method: 'GET', path: '/v2/droplets', summary: 'list droplets' }
    }
  }
}

export function nativeList() {
  return Object.values(PROFILES).map((p) => ({ bin: p.bin, provider: p.provider, lang: p.lang, secret: p.secret, connected: secrets.has(p.secret), verbs: Object.keys(p.verbs) }))
}

// PURE: (profile, argv, token) -> a described request, or {help}/{error}/{needsAuth}
export function planNative(p, argv, token) {
  const [verb, ...rest] = argv
  if (!verb || verb === 'help') return { help: helpFor(p) }
  const spec = p.verbs[verb]
  if (!spec) return { error: `${p.bin}: unknown command "${verb}" — try \`${p.bin} help\`` }
  if (!token && !p.optional) return { needsAuth: p.secret }

  let path = spec.path
  if (spec.arg) {
    const v = rest.find((t) => !t.startsWith('--'))
    if (!v) return { error: `${p.bin} ${verb}: missing <${spec.arg}>` }
    path = path.replace(`{${spec.arg}}`, v.replace(/^\//, ''))
  }
  const headers = { accept: 'application/json' }
  if (token) headers.authorization = (p.auth.type === 'bearer' ? 'Bearer ' : '') + token
  return { method: spec.method, url: p.host + path, headers, label: `${p.bin} ${verb}`, authed: !!token }
}

export function helpFor(p) {
  const rows = Object.entries(p.verbs).map(([v, s]) => `  ${p.bin} ${v}`.padEnd(22) + s.summary)
  const conn = secrets.has(p.secret) ? 'connected' : `not connected — \`connect ${p.provider} <token>\` sets ${p.secret}`
  return [`${p.bin} (${p.provider}) — native CLI · ${conn}`, '', ...rows].join('\n')
}

// render an API response into terminal lines (compact)
export function renderNative(label, status, json, authed) {
  const tag = authed ? '' : '  (unauthenticated)'
  const lines = [{ kind: status < 300 ? 'ok' : 'err', text: `${label} → ${status}${tag}` }]
  if (json == null) return lines
  const arr = Array.isArray(json) ? json : (json.data && Array.isArray(json.data) ? json.data : [json])
  for (const item of arr.slice(0, 8)) {
    if (item && typeof item === 'object') {
      lines.push({ kind: 'out', text: '  ' + Object.entries(item).slice(0, 4).map(([k, v]) => `${k}=${fmt(v)}`).join('  ') })
    } else lines.push({ kind: 'out', text: '  ' + String(item) })
  }
  if (Array.isArray(arr) && arr.length > 8) lines.push({ kind: 'dim', text: `  … ${arr.length - 8} more` })
  return lines
}
const fmt = (v) => Array.isArray(v) ? `[${v.length}]` : (v && typeof v === 'object') ? '{…}' : JSON.stringify(v)
