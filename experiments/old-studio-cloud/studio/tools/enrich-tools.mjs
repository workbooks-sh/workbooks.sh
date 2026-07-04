// CLI-tools enrichment — the ONE-TIME, authenticated pass that builds the tools corpus cache.
//
//   gh auth login   (once)
//   node tools/enrich-tools.mjs
//
// Source spine: toolleeo/awesome-cli-apps-in-a-csv (data/apps.csv, ~2230 CLIs). That CSV is a POINTER INDEX
// only (category,name,homepage,git,description) — no license, so we never redistribute it; we read the facts
// and resolve each GitHub repo through the API for the facts the catalogue needs: language, stars, license,
// archived. We then keep only the wasm-portable languages above a quality bar and vendor the result as a
// build-artifact cache (tools/data/cli-tools.json) — exactly like glyphs/toolkit-logos.json. gen-registry.mjs
// ingests that cache; it never hits the GitHub API itself (its hot path stays unauthenticated + fast).
//
// Re-run occasionally to refresh stars / pick up new tools. Needs `gh auth token`.

import { writeFileSync, mkdirSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const CSV = 'https://cdn.jsdelivr.net/gh/toolleeo/awesome-cli-apps-in-a-csv@master/data/apps.csv'

// languages that compile to wasm32 cleanly today (the porting lane). C/C++ via clang, Rust, Go (tinygo/yaegi),
// Zig, AssemblyScript. Everything else is parked until its toolchain lands.
const WASM_LANGS = new Set(['Rust', 'Go', 'Zig', 'C', 'C++', 'AssemblyScript'])
const MIN_STARS = 100

const token = execSync('gh auth token', { encoding: 'utf8' }).trim()
if (!token) { console.error('No gh token — run `gh auth login`'); process.exit(1) }

// ── minimal CSV parser (quoted fields, embedded commas, doubled "" escapes) ──────────────────────
function parseCSV(text) {
  const rows = []; let row = [], cell = '', q = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (q) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++ } else q = false } else cell += c }
    else if (c === '"') q = true
    else if (c === ',') { row.push(cell); cell = '' }
    else if (c === '\n') { row.push(cell); rows.push(row); row = []; cell = '' }
    else if (c !== '\r') cell += c
  }
  if (cell || row.length) { row.push(cell); rows.push(row) }
  return rows
}

const ghRepo = (url) => { const m = (url || '').match(/github\.com\/([^/]+)\/([^/#?]+)/i); return m ? `${m[1]}/${m[2].replace(/\.git$/, '')}` : null }
const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, '')
const titleCase = (s) => s.replace(/[-_]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())

// ── run ──────────────────────────────────────────────────────────────────────────────────────────
const csv = await (await fetch(CSV)).text()
const rows = parseCSV(csv)
const head = rows[0]
const ci = (k) => head.indexOf(k)
const recs = rows.slice(1).filter((r) => r.length >= 5).map((r) => ({
  category: r[ci('category')], name: r[ci('name')], git: r[ci('git')], description: r[ci('description')]
})).filter((r) => ghRepo(r.git))

// dedup by repo (some tools appear under multiple categories — keep first)
const seen = new Set(); const queue = []
for (const r of recs) { const repo = ghRepo(r.git); if (!seen.has(repo)) { seen.add(repo); queue.push({ ...r, repo }) } }
console.log(`spine: ${rows.length - 1} rows · ${queue.length} unique GitHub repos → enriching…`)

async function ghJSON(repo) {
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}`, { headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json' } })
    if (!res.ok) return null
    return await res.json()
  } catch { return null }
}

// bounded-concurrency pool
const out = []; let done = 0, kept = 0
const POOL = 12
let idx = 0
async function worker() {
  while (idx < queue.length) {
    const r = queue[idx++]
    const j = await ghJSON(r.repo)
    done++
    if (done % 100 === 0) process.stdout.write(`\r  ${done}/${queue.length} · kept ${kept}   `)
    if (!j || j.archived || !j.license) continue
    if (!WASM_LANGS.has(j.language) || (j.stargazers_count || 0) < MIN_STARS) continue
    kept++
    out.push({
      id: 'cli-' + norm(r.repo.split('/')[1]),
      name: r.name.trim(),
      summary: (r.description || '').trim().replace(/\s+/g, ' ').split('. ')[0].slice(0, 150),
      category: titleCase(r.category || 'tools'),
      lang: j.language.toLowerCase().replace('++', 'pp'),
      stars: j.stargazers_count,
      license: j.license.spdx_id,
      repo: r.repo,
      homepage: j.homepage || null
    })
  }
}
await Promise.all(Array.from({ length: POOL }, worker))
process.stdout.write('\n')

// dedup ids (different repos can normalise to the same slug) — keep the higher-starred
const byId = new Map()
for (const t of out.sort((a, b) => b.stars - a.stars)) if (!byId.has(t.id)) byId.set(t.id, t)
const final = [...byId.values()].sort((a, b) => b.stars - a.stars)

const byLang = final.reduce((m, t) => ((m[t.lang] = (m[t.lang] || 0) + 1), m), {})
mkdirSync(join(ROOT, 'tools', 'data'), { recursive: true })
writeFileSync(join(ROOT, 'tools', 'data', 'cli-tools.json'), JSON.stringify(final, null, 0) + '\n')
console.log(`✓ ${final.length} wasm-portable CLIs (≥${MIN_STARS}★, licensed, active)`)
console.log(`  langs: ${JSON.stringify(byLang)}`)
console.log(`  categories: ${new Set(final.map((t) => t.category)).size}`)
console.log(`  → tools/data/cli-tools.json (build-artifact cache; gen-registry.mjs ingests it)`)
