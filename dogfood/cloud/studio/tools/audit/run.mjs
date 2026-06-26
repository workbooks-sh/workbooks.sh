// Toolkit audit pipeline — TRIAL runner (see registry/audit-pipeline.work for the full design).
//
//   OPENROUTER_API_KEY=sk-... node tools/audit/run.mjs [id1 id2 …]
//
// Implements the enrichment lane (acquire → profile → grade) + a consolidation demo, over a small sample.
// The heavy reasoning (risk · strengths/weaknesses · sandbox fit · TARGET resolution) is done by a cheap model
// (z-ai/glm-5.2 via OpenRouter), not us. SkillSpector is a stage in the design; for this trial the model does a
// lighter context/safety grade in its place. Results are printed only — NOT committed, NOT folded into the
// registry. We're just seeing how the cheap model does on a few.

import { generated } from '../../src/lib/toolkits.generated.js'

const KEY = process.env.OPENROUTER_API_KEY
if (!KEY) { console.error('Set OPENROUTER_API_KEY'); process.exit(1) }
const MODEL = process.env.AUDIT_MODEL || 'z-ai/glm-5.2'

// default sample: the GitHub cluster (integration + tool + skill), the author≠subject trap, a no-target tool,
// and a second integration for variety.
const SAMPLE = process.argv.slice(2).length ? process.argv.slice(2) : [
  'github',                                                          // integration (host api.github.com)
  'cli-froggit',                                                     // tool — Git TUI w/ GitHub CLI → should resolve to github
  'skill-devagentskillsdevagentskills',                             // skill — git/github workflows → github
  'skill-anthropiccybersecurityskillsanthropiccybersecurityskills', // skill — author=Anthropic, SUBJECT=cybersecurity (must NOT → Anthropic)
  'ripgrep',                                                         // tool — no third-party target → stays a tool
  'Notion'                                                           // integration (host api.notion.com)
]

const byId = new Map(generated.map((t) => [t.id, t]))
const item = (k) => byId.get(k) || generated.find((t) => t.name === k) || generated.find((t) => t.id === k.toLowerCase())

// ── Stage 0 — acquire ─────────────────────────────────────────────────────────────────────────────
// Fetch the real content (repo README + manifests, a SKILL.md if present) so the grade is grounded in the
// artifact, not just our one-line summary. Facts kept, files discarded — same stance as the registry.
const MANIFESTS = ['package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'requirements.txt', 'setup.py', 'deno.json']
const cdn = (repo, path, ver = 'HEAD') => `https://cdn.jsdelivr.net/gh/${repo}@${ver}/${path}`
async function txt(url) { try { const r = await fetch(url); return r.ok ? await r.text() : null } catch { return null } }

async function acquire(t) {
  if (!t.repo) {
    // an integration / curated entry: content is the facts we already hold
    const facts = [t.summary, t.loginCmd && `login: ${t.loginCmd}`, t.hosts?.length && `hosts: ${t.hosts.join(', ')}`,
      t.secrets?.length && `secrets: ${t.secrets.join(', ')}`, t.tools?.length && `commands: ${t.tools.join(', ')}`].filter(Boolean).join('\n')
    return { readme: facts, manifests: {}, files: [] }
  }
  let files = []
  try {
    const tree = await (await fetch(`https://data.jsdelivr.com/v1/packages/gh/${t.repo}@HEAD`)).json()
    files = (tree.files || []).map((f) => f.name)
  } catch {}
  const readmeName = files.find((f) => /^readme(\.md)?$/i.test(f)) || 'README.md'
  const readme = (await txt(cdn(t.repo, readmeName))) || t.summary
  const manifests = {}
  for (const m of MANIFESTS) if (files.includes(m)) { const c = await txt(cdn(t.repo, m)); if (c) manifests[m] = c }
  return { readme: (readme || '').slice(0, 6000), manifests, files }
}

// ── Stage 1 — static profile (deps · hosts · runtime requirements) ──────────────────────────────────
function parseDeps(manifests) {
  const deps = []
  if (manifests['package.json']) { try { const j = JSON.parse(manifests['package.json']); for (const k of ['dependencies', 'devDependencies']) deps.push(...Object.keys(j[k] || {}).map((n) => ({ name: n, ecosystem: 'npm' }))) } catch {} }
  if (manifests['Cargo.toml']) { const m = manifests['Cargo.toml'].split(/\[dependencies\]/)[1]; if (m) for (const l of m.split('\n')) { const n = l.match(/^([A-Za-z0-9_-]+)\s*=/); if (n) deps.push({ name: n[1], ecosystem: 'cargo' }); if (/^\[/.test(l.trim())) break } }
  if (manifests['go.mod']) for (const l of manifests['go.mod'].split('\n')) { const n = l.match(/^\s+([\w.\-/]+)\s+v/); if (n) deps.push({ name: n[1], ecosystem: 'go' }) }
  for (const f of ['requirements.txt']) if (manifests[f]) for (const l of manifests[f].split('\n')) { const n = l.match(/^([A-Za-z0-9_.\-]+)/); if (n && !l.startsWith('#')) deps.push({ name: n[1], ecosystem: 'pip' }) }
  return deps
}
const NOISE_HOST = /(github\.com|githubusercontent|shields\.io|jsdelivr|npmjs|crates\.io|pkg\.go\.dev|badge|w3\.org|example\.com|localhost|schema)/i
function extractHosts(content, seed = []) {
  const hosts = new Set(seed)
  for (const m of content.matchAll(/https?:\/\/([a-z0-9.-]+\.[a-z]{2,})/gi)) if (!NOISE_HOST.test(m[1])) hosts.add(m[1].toLowerCase())
  return [...hosts].slice(0, 12)
}
function runtimeReqs(content) {
  const r = []
  if (/\b(cuda|nvidia-smi|gpu|tensorrt|torch|tensorflow|cudnn)\b/i.test(content)) r.push('gpu')
  if (/\b(\.so\b|libc|gcc|cmake|make\b|native|ffi|cgo)\b/i.test(content)) r.push('native_lib')
  if (/\b(subprocess|exec|fork|spawn|child_process)\b/i.test(content)) r.push('subprocess')
  return r
}

// ── Stage 2/3/4 — grade via the cheap model (safety · strengths · wasm fit · TARGET) ────────────────
const SYS = `You are an auditor for a catalogue of agent toolkits (skills, CLI tools, API integrations) that all run
EMULATED inside a WebAssembly sandbox. Judge ONLY from the provided content + facts. Return STRICT JSON, no prose.

Resolve "target_entity" = the real-world service/domain the item OPERATES ON (acts upon), which is DIFFERENT from
who authored it. Example: a skill named "Anthropic Cybersecurity Skills" is authored by/about cybersecurity — its
target is "cybersecurity" (general, no vendor domain), NOT the Anthropic API. Use egress hosts/SDKs as the signal.
If it operates on no specific third-party service, set target_entity to a short generic noun and target_domain null.

JSON shape:
{"how_it_works": "1-2 sentences",
 "risk_score": 0-100, "severity": "info|low|medium|high|critical",
 "findings": [{"category":"", "severity":"", "note":""}],
 "strengths": ["",""], "weaknesses": ["",""],
 "verdict": "allow|review|block",
 "wasm_fit": "ready|portable|incompatible", "wasm_reason": "",
 "target_entity": "", "target_domain": "host or null", "target_confidence": 0.0-1.0}`

function extractJSON(s) { const a = s.indexOf('{'), b = s.lastIndexOf('}'); if (a < 0 || b < 0) return null; try { return JSON.parse(s.slice(a, b + 1)) } catch { return null } }
async function grade(t, prof) {
  const user = `KIND: ${t.kind}
NAME: ${t.name}
SUMMARY: ${t.summary}
REPO: ${t.repo || '(none — curated/integration)'}
DECLARED HOSTS: ${(t.hosts || []).join(', ') || '(none)'}
RESOLVED HOSTS: ${prof.hosts.join(', ') || '(none)'}
DEPENDENCIES (${prof.deps.length}): ${prof.deps.slice(0, 40).map((d) => d.name).join(', ') || '(none parsed)'}
RUNTIME SIGNALS: ${prof.runtime_reqs.join(', ') || '(none)'}
CONTENT:
${prof.content}`
  const res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST', headers: { authorization: `Bearer ${KEY}`, 'content-type': 'application/json', 'X-Title': 'workbooks-audit-trial' },
    body: JSON.stringify({ model: MODEL, temperature: 0, messages: [{ role: 'system', content: SYS }, { role: 'user', content: user }] })
  })
  if (!res.ok) return { error: `${res.status} ${(await res.text()).slice(0, 200)}` }
  const j = await res.json()
  const out = extractJSON(j.choices?.[0]?.message?.content || '')
  return out || { error: 'unparseable', raw: (j.choices?.[0]?.message?.content || '').slice(0, 200) }
}

// ── enrichment lane (per item) ──────────────────────────────────────────────────────────────────────
async function enrich(t) {
  const got = await acquire(t)
  const content = [got.readme, ...Object.entries(got.manifests).map(([k, v]) => `--- ${k} ---\n${v.slice(0, 800)}`)].join('\n').slice(0, 7000)
  const prof = { deps: parseDeps(got.manifests), hosts: extractHosts(content, t.hosts || []), runtime_reqs: runtimeReqs(content), content }
  const g = await grade(t, prof)
  return { id: t.id, kind: t.kind, name: t.name, repo: t.repo || null, prof: { deps: prof.deps.length, hosts: prof.hosts, runtime_reqs: prof.runtime_reqs }, grade: g }
}

// ── consolidation demo — seed entities from integrations, cluster by resolved target, promote ─────────
const LAYER_RANK = { integration: 3, tool: 2, skill: 1 }
const normEnt = (s) => (s || '').toLowerCase().replace(/[^a-z0-9]/g, '')
function consolidate(rows) {
  // seed canonical entities from the integration items in the sample (brand + domain)
  const entities = new Map()
  for (const r of rows) if (r.kind === 'integration' && !r.grade.error) {
    const dom = (r.grade.target_domain || (item(r.id)?.hosts || [])[0] || '').replace(/^api\./, '')
    entities.set(normEnt(r.name), { key: normEnt(r.name), brand: r.name, domain: dom, rows: [] })
  }
  // assign every row to an entity: prefer a domain match, else the resolved target_entity string
  const standalone = []
  for (const r of rows) {
    if (r.grade.error) { standalone.push(r); continue }
    const dom = (r.grade.target_domain || '').replace(/^api\./, '')
    let ent = null
    for (const e of entities.values()) if (e.domain && dom && (dom.includes(e.domain) || e.domain.includes(dom.split('.')[0]))) ent = e
    if (!ent) { // try brand/name match against seeded integration entities (conservative — needs the resolved target to name it)
      const tgt = normEnt(r.grade.target_entity)
      for (const e of entities.values()) if (tgt && (tgt.includes(e.key) || e.key.includes(tgt)) && (r.grade.target_confidence ?? 0) >= 0.55) ent = e
    }
    if (ent) ent.rows.push(r); else standalone.push(r)
  }
  return { clusters: [...entities.values()].filter((e) => e.rows.length), standalone }
}

// ── run ───────────────────────────────────────────────────────────────────────────────────────────
const items = SAMPLE.map(item).filter(Boolean)
console.log(`\n▶ auditing ${items.length} items with ${MODEL}\n`)
const rows = []
for (const t of items) { process.stdout.write(`  · ${t.name} … `); const r = await enrich(t); rows.push(r); console.log(r.grade.error ? `ERR ${r.grade.error}` : `${r.grade.verdict} · ${r.grade.wasm_fit} · target=${r.grade.target_entity}`) }

console.log('\n══════════ ENRICHMENT ══════════')
for (const r of rows) {
  const g = r.grade
  console.log(`\n● ${r.name}  [${r.kind}]  ${r.repo || ''}`)
  if (g.error) { console.log('  ⚠ ' + g.error); continue }
  console.log(`  how: ${g.how_it_works}`)
  console.log(`  risk: ${g.risk_score}/${g.severity}  verdict: ${g.verdict}  wasm: ${g.wasm_fit} (${g.wasm_reason})`)
  console.log(`  deps: ${r.prof.deps}  hosts: ${r.prof.hosts.join(', ') || '—'}  runtime: ${r.prof.runtime_reqs.join(', ') || '—'}`)
  console.log(`  target: ${g.target_entity} [${g.target_domain || 'no domain'}] conf=${g.target_confidence}`)
  if (g.strengths?.length) console.log(`  + ${g.strengths.join(' / ')}`)
  if (g.weaknesses?.length) console.log(`  - ${g.weaknesses.join(' / ')}`)
}

console.log('\n══════════ CONSOLIDATION ══════════')
const { clusters, standalone } = consolidate(rows)
for (const c of clusters) {
  const primary = c.rows.slice().sort((a, b) => LAYER_RANK[b.kind] - LAYER_RANK[a.kind])[0]
  console.log(`\n◆ ${c.brand} [${c.domain || 'no domain'}] → primary layer: ${primary.kind} (${primary.name})`)
  for (const r of c.rows) if (r !== primary) console.log(`    ↳ ${r.kind}: ${r.name}  (enable under ${primary.name})`)
}
console.log('\n◇ standalone (no shared target / stay in own layer):')
for (const r of standalone) console.log(`    ${r.kind}: ${r.name}`)
console.log('')
