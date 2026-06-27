// The LOCAL Dock provider — fulfills every capability in the browser, against the in-memory mock tree
// (fs.svelte.js) and pure-JS stand-ins. It is the demo half of the platform's provider model: the SAME
// dock.* contract is later fulfilled by the `runtime` provider over RCP (fs→WASHIE, shell→Nexus.Shell,
// lang→a wasm LSP server). Nothing here leaks past the seam — swapping providers is config, not a rewrite.
import { fileTree } from '../fs.svelte.js'
import { extCompletions } from './ext-host.js'

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
        out('commands: ls · tree · cat <file> · run <file> · weave · ext <query> · clear · help'),
        out('real shell is washy/Nexus.Shell — compiled to one wasm module; this is the demo seam', 'dim')
      ]
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
      default: return [out(verb + ': command not found (try `help`)', 'err')]
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

export const local = { name: 'local', fs, shell, lang, vcs, ext }
