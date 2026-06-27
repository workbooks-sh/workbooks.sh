// The LOCAL Dock provider — fulfills every capability in the browser, against the in-memory mock tree
// (fs.svelte.js) and pure-JS stand-ins. It is the demo half of the platform's provider model: the SAME
// dock.* contract is later fulfilled by the `runtime` provider over RCP (fs→WASHIE, shell→Nexus.Shell,
// lang→a wasm LSP server). Nothing here leaks past the seam — swapping providers is config, not a rewrite.
import { fileTree } from '../fs.svelte.js'
import { extCompletions } from './ext-host.js'
import { parseSpec, planRequest, renderResponse, specSlug } from './cli-engine.js'
import { secrets } from './secrets.js'
import { PROFILES, nativeList, planNative, renderNative } from './native-cli.js'

// ── path helpers over the reactive tree ───────────────────────────────────────────────────────────
const norm = (p) => '/' + String(p || '').replace(/^\/+|\/+$/g, '')
function nodeAt(path, nodes = fileTree) {
  const want = norm(path)
  for (const n of nodes) {
    if (norm(n.path) === want) return n
    if (n.children) { const f = nodeAt(path, n.children); if (f) return f }
  }
  return null
}
function flatten(nodes = fileTree, acc = []) {
  for (const n of nodes) { acc.push(n); if (n.children) flatten(n.children, acc) }
  return acc
}

// ── fs (→ WASHIE / Nexus.Store later) ─────────────────────────────────────────────────────────────
const fs = {
  async list(dir = '/') {
    const node = dir === '/' ? { children: fileTree } : nodeAt(dir)
    return (node?.children || []).map((n) => ({ name: n.name, path: n.path, type: n.type }))
  },
  async read(path) { const n = nodeAt(path); if (!n || n.type !== 'file') throw new Error('ENOENT ' + path); return n.content ?? '' },
  async write(path, content) { const n = nodeAt(path); if (n) { n.content = content; n.dirty = false } return { ok: true } }
}

// ── shell (→ host_exec into Nexus.Shell wasm later) ───────────────────────────────────────────────
// exec returns a list of output lines {kind,text}; the terminal renders them. The same shape becomes a
// streamed response from the runtime provider (each chunk = one or more lines).
const allWork = () => flatten().filter((n) => n.type === 'file' && n.name.endsWith('.work'))
const shell = {
  async exec(raw, _cwd = '/') {
    const cmd = String(raw || '').trim()
    if (!cmd) return []
    const [verb, ...args] = cmd.split(/\s+/)
    const out = (text, kind = 'out') => ({ kind, text })
    switch (verb) {
      case 'help': return [
        out('shell: ls · tree · cat <file> · run <file> · weave · ext <query> · clear · help'),
        out('native CLIs (tier-1, compiled to wasm): ' + nativeList().map((p) => p.bin).join(' · ') + '  — e.g. `gh repo vercel/next.js`', 'dim'),
        out('  connect <provider> <token>  ·  disconnect <provider>  ·  cli  (list all)', 'dim'),
        out('generated CLIs (tier-2, OpenAPI→CLI engine): ' + cli.list().map((s) => s.slug).join(' · '), 'dim'),
        out('real shell is washy/Nexus.Shell — compiled to one wasm module; this is the demo seam', 'dim')
      ]
      case 'cli': return [
        out('TIER-1 native CLIs (their real binary → wasm; secret injected via Nexus.Secrets):', 'dim'),
        ...nativeList().map((p) => out(`  ${p.bin.padEnd(14)} ${p.connected ? '● connected' : '○ ' + p.secret}   ${p.verbs.join(' ')}`, p.connected ? 'ok' : 'out')),
        out('TIER-2 generated CLIs (one engine, N OpenAPI specs):', 'dim'),
        ...cli.list().map((s) => out(`  ${s.slug.padEnd(14)} ${s.ops} commands (from spec)`)),
        out('try: `gh repo vercel/next.js`  ·  `connect sentry <token>` then `sentry projects`', 'dim')
      ]
      case 'connect': {
        const [prov, token] = args
        const p = Object.values(PROFILES).find((x) => x.provider === prov || x.bin === prov)
        if (!p) return [out(`connect: unknown provider "${prov || ''}" (try: ${nativeList().map((x) => x.provider).join(', ')})`, 'err')]
        if (!token) return [out(`connect: usage: connect ${p.provider} <token>`, 'err')]
        secrets.set(p.secret, token)
        return [out(`✓ connected ${p.provider} — ${p.secret} injected via Nexus.Secrets (not stored in source)`, 'ok')]
      }
      case 'disconnect': {
        const p = Object.values(PROFILES).find((x) => x.provider === args[0] || x.bin === args[0])
        if (!p) return [out(`disconnect: unknown provider "${args[0] || ''}"`, 'err')]
        secrets.clear(p.secret)
        return [out(`✓ disconnected ${p.provider}`, 'dim')]
      }
      case 'ls': return [out(fileTree.map((n) => n.type === 'folder' ? n.name + '/' : n.name).join('   '))]
      case 'tree': return flatten().filter((n) => norm(n.path).split('/').length <= 3)
        .map((n) => out('  '.repeat(norm(n.path).split('/').length - 2) + n.name + (n.type === 'folder' ? '/' : '')))
      case 'cat': {
        const n = nodeAt(args[0]) || flatten().find((x) => x.name === args[0])
        return n?.type === 'file' ? String(n.content || '').split('\n').map((l) => out(l)) : [out('cat: ' + (args[0] || '') + ': no such file', 'err')]
      }
      case 'weave': return [out('weaving workspace …', 'dim'), out('✓ wove ' + allWork().length + ' .work files → out/bundle.work', 'ok')]
      case 'run': {
        const target = args[0]
        if (!target) return [out('run: usage: run <file.work>', 'err')]
        const n = nodeAt(target) || flatten().find((x) => x.name === target)
        if (!n || n.type !== 'file') return [out('run: ' + target + ': no such file', 'err')]
        return [out('running ' + n.name + ' in the wasm sandbox …', 'dim'), out('✓ ' + n.name + ' ran (emulated) — 0 errors', 'ok')]
      }
      case 'ext': {
        try { const r = await ext.search(args.join(' ') || 'svelte'); return [out(`open-vsx: ${r.length} results`, 'dim'), ...r.slice(0, 6).map((e) => out(`  ${e.namespace}.${e.name}  —  ${e.description || ''}`.slice(0, 90)))] }
        catch { return [out('ext: open-vsx unreachable', 'err')] }
      }
      case 'clear': return [{ kind: 'clear' }]
      default: {
        // a TIER-1 native CLI? (gh/sentry/resend/doctl) — resolve secret, plan (pure), host fetch
        const prof = PROFILES[verb]
        if (prof) return nativecli.run(verb, args)
        // a TIER-2 generated CLI? route through the OpenAPI engine (host does the fetch)
        if (cli.list().some((s) => s.slug === verb)) return cli.run(verb, args)
        return [out(verb + ': command not found (try `help`)', 'err')]
      }
    }
  }
}

// ── lang (→ a wasm LSP server behind codemirror-languageserver later) ─────────────────────────────
// A small but REAL language intelligence for .work / Elixir-AST: keyword + kind completion, symbol
// completion scraped from the buffer, balance/kind diagnostics, and hover docs. dock.lang.* is the
// stable shape; the local impl is replaced by an LSP round-trip without touching the editor wiring.
const WORK_KINDS = ['def', 'server', 'client', 'flow', 'sandbox', 'agent', 'resource', 'hook', 'worker', 'check', 'toolkit', 'test', 'design', 'app', 'auth', 'surface', 'deploy', 'workbook', 'secrets', 'task', 'route', 'grant']
const WORK_KEYWORDS = ['do', 'end', 'field', 'step', 'parallel', 'trigger', 'match', 'notify', 'render', 'query', 'state', 'prop', 'tool', 'memory', 'index', 'every', 'after', 'cron', 'at', 'require', 'workspace', 'nexus', 'region', 'scope', 'title', 'purpose', 'source', 'model']
const KIND_DOC = {
  resource: 'A typed table — the one persistent data unit. Rows live in `Nexus.Store` (tenant-partitioned).',
  flow: 'An ordered runnable step pipeline; `parallel do … end` fans steps out on the BEAM.',
  hook: 'Reactive binding — `match` on the event bus → effects. May carry a time `trigger`.',
  agent: 'A brain block: model + tools + memory/index. The agent concept as `.work`.',
  server: 'A server-side unit (native BEAM). Backs surfaces/data/sync.',
  client: 'A browser island — compiled to wasm and rendered client-side.',
  worker: 'A long-lived SUPERVISED stateful process (GenServer as `.work`).',
  surface: 'A mounted page/app; a folder with index.work is a surface at its path.',
  deploy: 'The deploy manifest block — nexus/region + declared workspaces. Read via `Nexus.Config`.'
}

function symbolsIn(text) {
  const out = new Set()
  for (const m of text.matchAll(/^\s*(?:def|server|client|flow|agent|resource|hook|worker|surface)\s+:?(\w+)/gm)) out.add(m[1])
  for (const m of text.matchAll(/:(\w+)/g)) out.add(m[1])
  return [...out]
}

const lang = {
  async complete(path, { text, prefix }) {
    const p = (prefix || '').toLowerCase()
    const kind = (label, type, info) => ({ label, type, info })
    const langId = String(path || '').endsWith('.work') ? 'work' : (path || '').split('.').pop()
    const items = [
      ...WORK_KINDS.map((k) => kind(k, 'keyword', KIND_DOC[k] || `\`${k}\` block`)),
      ...WORK_KEYWORDS.map((k) => kind(k, 'property')),
      ...symbolsIn(text || '').map((s) => kind(s, 'variable', 'symbol in this file')),
      // completions CONTRIBUTED by activated extensions (via the vscode shim → ext-host)
      ...extCompletions(langId, { text, prefix })
    ]
    return items.filter((i) => !p || i.label.toLowerCase().startsWith(p))
  },
  async diagnostics(_path, text) {
    const diags = []
    const lines = (text || '').split('\n')
    let opens = 0
    lines.forEach((line, i) => {
      const code = line.replace(/#.*$/, '')
      // do/end balance (block openers ending in ` do`, vs standalone end)
      if (/\bdo\s*$/.test(code)) opens++
      if (/^\s*end\b/.test(code)) opens--
      // unknown leading kind → a soft warning (helps catch typos like `serer :x do`)
      const m = code.match(/^(\w+)\b.*\bdo\s*$/)
      if (m && !WORK_KINDS.includes(m[1]) && !WORK_KEYWORDS.includes(m[1])) {
        const from = lineOffset(lines, i) + line.indexOf(m[1])
        diags.push({ from, to: from + m[1].length, severity: 'warning', message: `Unknown block kind "${m[1]}" — not a known .work kind.` })
      }
    })
    if (opens > 0) diags.push({ from: Math.max(0, (text || '').length - 1), to: (text || '').length, severity: 'error', message: `${opens} unclosed \`do\` block${opens > 1 ? 's' : ''} — missing \`end\`.` })
    return diags
  },
  async hover(_path, word) {
    if (KIND_DOC[word]) return `**${word}** — ${KIND_DOC[word]}`
    if (WORK_KINDS.includes(word)) return `**${word}** — a \`.work\` block kind.`
    if (WORK_KEYWORDS.includes(word)) return `\`${word}\` — a \`.work\` keyword.`
    return null
  }
}
function lineOffset(lines, idx) { let o = 0; for (let i = 0; i < idx; i++) o += lines[i].length + 1; return o }

// ── vcs (→ git over the runtime later) — powers the status-bar branch ─────────────────────────────
const vcs = { async status() { return { branch: 'wb-d8ac-spine', dirty: flatten().filter((n) => n.dirty).length } } }

// ── ext: the Open VSX registry (open-vsx.org) — REAL public REST API, vendor-neutral marketplace ──
const VSX = 'https://open-vsx.org/api'
const ext = {
  async search(query = '', size = 24) {
    const r = await fetch(`${VSX}/-/search?query=${encodeURIComponent(query)}&size=${size}&sortBy=relevance`)
    if (!r.ok) throw new Error('open-vsx ' + r.status)
    const j = await r.json()
    return (j.extensions || []).map((e) => ({
      namespace: e.namespace, name: e.name, version: e.version,
      displayName: e.displayName || e.name, description: e.description || '',
      downloads: e.downloadCount || 0, rating: e.averageRating || null,
      icon: e.files?.icon || null, timestamp: e.timestamp
    }))
  },
}

// ── cli: the generic OpenAPI -> CLI engine, with the HOST doing the I/O (the engine itself is pure). Ships a
// couple of EMBEDDED real specs so the loop runs end-to-end today: parse spec -> plan request (pure) -> the
// host fetch (here) -> render (pure). A runtime provider would load specs from the registry + fetch via WASHIE.
// REST Countries: no-auth public API, proves a generated CLI returns real data. GitHub: bearer-auth shape. ──
const SPECS_RAW = {
  countries: {
    info: { title: 'restcountries', version: 'v3.1' },
    servers: [{ url: 'https://restcountries.com/v3.1' }],
    paths: {
      '/name/{name}': { get: { operationId: 'name', summary: 'Look up countries by name',
        parameters: [{ name: 'name', in: 'path', required: true }, { name: 'fields', in: 'query' }] } },
      '/alpha/{code}': { get: { operationId: 'code', summary: 'Look up a country by ISO code',
        parameters: [{ name: 'code', in: 'path', required: true }] } }
    }
  },
  github: {
    info: { title: 'github', version: 'v3' },
    servers: [{ url: 'https://api.github.com' }],
    'x-auth': { type: 'bearer', secret: 'GITHUB_TOKEN' },
    paths: {
      '/repos/{owner}/{repo}': { get: { operationId: 'repo', summary: 'Get a repository',
        parameters: [{ name: 'owner', in: 'path', required: true }, { name: 'repo', in: 'path', required: true }] } },
      '/users/{user}': { get: { operationId: 'user', summary: 'Get a user',
        parameters: [{ name: 'user', in: 'path', required: true }] } }
    }
  }
}
const SPECS = Object.fromEntries(Object.entries(SPECS_RAW).map(([k, doc]) => [k, parseSpec(doc)]))

const cli = {
  // list the spec-backed providers available as generated CLIs (slug = the registry key = the command word)
  list() { return Object.entries(SPECS).map(([slug, s]) => ({ slug, name: s.name, ops: s.ops.length })) },
  // run `argv` against the named spec. engine plans the request (pure); WE perform the fetch (host I/O).
  async run(slug, argv) {
    const spec = SPECS[slug] || Object.values(SPECS).find((s) => specSlug(s) === slug)
    if (!spec) return [{ kind: 'err', text: `no generated CLI for "${slug}" (try: ${cli.list().map((s) => s.slug).join(', ')})` }]
    const plan = planRequest(spec, argv, {}) // auth secrets injected by the host in production (Nexus.Secrets)
    if (plan.help) return plan.help.split('\n').map((t) => ({ kind: 'dim', text: t }))
    if (plan.error) return [{ kind: 'err', text: plan.error }]
    try {
      const res = await fetch(plan.url, { method: plan.method, headers: plan.headers })
      const json = await res.json().catch(() => null)
      return renderResponse(plan.op, res.status, json)
    } catch (e) {
      return [{ kind: 'err', text: 'request failed: ' + (e?.message || e) }]
    }
  }
}

// ── nativecli: the host I/O half of the tier-1 harness. planNative is pure (secret in, request out); WE inject
// the secret (via the secrets seam = Nexus.Secrets) and perform the fetch. Mirrors the compiled binary's effect.
const nativecli = {
  list() { return nativeList() },
  async run(bin, argv) {
    const p = PROFILES[bin]
    if (!p) return [{ kind: 'err', text: `no native CLI "${bin}"` }]
    const token = secrets.get(p.secret)
    const plan = planNative(p, argv, token)
    if (plan.help) return plan.help.split('\n').map((t) => ({ kind: 'dim', text: t }))
    if (plan.error) return [{ kind: 'err', text: plan.error }]
    if (plan.needsAuth) return [{ kind: 'err', text: `${bin}: not connected — run \`connect ${p.provider} <token>\` to inject ${plan.needsAuth}` }]
    try {
      const res = await fetch(plan.url, { method: plan.method, headers: plan.headers })
      const json = await res.json().catch(() => null)
      return renderNative(plan.label, res.status, json, plan.authed)
    } catch (e) {
      return [{ kind: 'err', text: 'request failed: ' + (e?.message || e) }]
    }
  }
}

export const local = { name: 'local', fs, shell, lang, vcs, ext, cli, secrets, nativecli }
