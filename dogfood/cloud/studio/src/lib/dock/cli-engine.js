// The generic OpenAPI -> CLI ENGINE (prototype). This is the tier-2 integration lever: one engine turns ANY
// OpenAPI spec into a working CLI — `provider op --flag value` — so onboarding a provider is "add a spec", not
// "write code". (See registry/integration-cli-strategy.work: 253 of the no-CLI providers are auto-gen viable.)
//
// THESIS-CRITICAL SHAPE: this module does ZERO I/O. It is two pure functions —
//   planRequest(spec, argv) -> a DESCRIBED http request  (or {help}/{error})
//   renderResponse(op, status, json) -> output lines
// The actual network call is performed by the HOST (dock.cli in local.js / the runtime fetch capability),
// never here. No sockets, no TLS, no syscalls: trivially wasm-safe and deterministic. In production this same
// pure core is the Zig/AssemblyScript module compiled to wasm; the host fetch is the only privileged step.

// parse a (minimal) OpenAPI doc into a flat op list — enough for the prototype: paths × methods, params split
// by `in` (path/query/header). A real impl also resolves $ref, requestBody schemas, and security schemes.
export function parseSpec(doc) {
  const ops = []
  const base = (doc.servers && doc.servers[0] && doc.servers[0].url) || ''
  for (const [path, item] of Object.entries(doc.paths || {})) {
    for (const method of ['get', 'post', 'put', 'patch', 'delete']) {
      const op = item[method]
      if (!op) continue
      const params = (op.parameters || []).map((p) => ({ name: p.name, in: p.in, required: !!p.required, desc: p.description || '' }))
      ops.push({
        id: op.operationId || (method + ':' + path),
        cmd: cmdName(op, method, path),
        method: method.toUpperCase(),
        path, base,
        params,
        summary: op.summary || op.description || ''
      })
    }
  }
  return { name: doc.info?.title || 'api', version: doc.info?.version || '', base, auth: doc['x-auth'] || null, ops }
}

// a short subcommand name: prefer operationId, else last path segment + verb hint
function cmdName(op, method, path) {
  if (op.operationId) return op.operationId
  const seg = path.split('/').filter((s) => s && !s.startsWith('{')).pop() || 'root'
  return method === 'get' ? seg : `${method}-${seg}`
}

// argv -> { method, url, headers, query } ; or { help } ; or { error }
// argv = [cmd, --flag, value, --flag2, value2, ...]. Flags fill path/query/header params by name.
export function planRequest(spec, argv, auth = {}) {
  const [cmd, ...rest] = argv
  if (!cmd || cmd === 'help' || cmd === '--help') return { help: helpText(spec) }
  const op = spec.ops.find((o) => o.cmd === cmd || o.id === cmd)
  if (!op) return { error: `unknown command "${cmd}" — try \`${specSlug(spec)} help\`` }

  const flags = parseFlags(rest)
  // substitute path params
  let path = op.path
  const missing = []
  for (const p of op.params.filter((p) => p.in === 'path')) {
    if (flags[p.name] == null) { if (p.required) missing.push(p.name); continue }
    path = path.replace(`{${p.name}}`, encodeURIComponent(flags[p.name]))
  }
  if (missing.length) return { error: `missing required: ${missing.map((m) => '--' + m).join(', ')}` }

  // query + header params
  const query = {}
  const headers = { accept: 'application/json' }
  for (const p of op.params) {
    if (flags[p.name] == null) continue
    if (p.in === 'query') query[p.name] = flags[p.name]
    else if (p.in === 'header') headers[p.name] = flags[p.name]
  }
  // auth injection (host supplies the secret value; engine only knows WHERE it goes)
  if (spec.auth) applyAuth(spec.auth, auth, headers, query)

  const qs = Object.keys(query).length ? '?' + new URLSearchParams(query).toString() : ''
  return { op, method: op.method, url: op.base + path + qs, headers }
}

function applyAuth(authSpec, auth, headers, query) {
  const val = auth[authSpec.secret]
  if (!val) return
  if (authSpec.type === 'bearer') headers.authorization = 'Bearer ' + val
  else if (authSpec.type === 'header') headers[authSpec.name] = val
  else if (authSpec.type === 'query') query[authSpec.name] = val
}

function parseFlags(rest) {
  const out = {}
  for (let i = 0; i < rest.length; i++) {
    const t = rest[i]
    if (t.startsWith('--')) {
      const key = t.slice(2)
      const next = rest[i + 1]
      if (next == null || next.startsWith('--')) out[key] = true
      else { out[key] = next; i++ }
    }
  }
  return out
}

// render a response into terminal lines (compact: show top-level keys / array summary)
export function renderResponse(op, status, json) {
  const lines = [{ kind: status < 300 ? 'ok' : 'err', text: `${op.method} ${op.path} → ${status}` }]
  if (json == null) return lines
  const body = Array.isArray(json) ? json : [json]
  for (const item of body.slice(0, 8)) {
    if (item && typeof item === 'object') {
      const summary = Object.entries(item).slice(0, 4)
        .map(([k, v]) => `${k}=${fmtVal(v)}`).join('  ')
      lines.push({ kind: 'out', text: '  ' + summary })
    } else {
      lines.push({ kind: 'out', text: '  ' + String(item) })
    }
  }
  if (Array.isArray(json) && json.length > 8) lines.push({ kind: 'dim', text: `  … ${json.length - 8} more` })
  return lines
}
const fmtVal = (v) => Array.isArray(v) ? `[${v.length}]` : (v && typeof v === 'object') ? '{…}' : JSON.stringify(v)

function helpText(spec) {
  const slug = specSlug(spec)
  const rows = spec.ops.map((o) => `  ${slug} ${o.cmd}`.padEnd(34) + (o.summary || '').slice(0, 44))
  return [`${spec.name} ${spec.version} — generated from OpenAPI`, '', ...rows].join('\n')
}
export function specSlug(spec) { return (spec.name || 'api').toLowerCase().replace(/[^a-z0-9]+/g, '') }
