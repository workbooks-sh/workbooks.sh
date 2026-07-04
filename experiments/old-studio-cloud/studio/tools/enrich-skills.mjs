// Skills enrichment — the authenticated pass that builds the skills corpus cache.
//
//   gh auth login   (once)
//   node tools/enrich-skills.mjs
//
// skills.sh has no open API (its /api/v1 is gated behind a Vercel OIDC token), so we can't pull its
// approval/like counts. Instead we use GitHub stars on the owning repo as the popularity signal, over two
// license-clean spines:
//   • anthropics/skills            (Apache-2.0) — SKILL.md bundles, name/description from frontmatter
//   • VoltAgent/awesome-agent-skills (MIT)      — a curated list; each row → a GitHub repo + description
// Facts only (name · description · repo · stars · license); files are not vendored. Vendored as the
// build-artifact cache tools/data/skills.json, which gen-registry.mjs ingests (its hot path never hits the API).

import { writeFileSync, mkdirSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const token = execSync('gh auth token', { encoding: 'utf8' }).trim()
if (!token) { console.error('No gh token — run `gh auth login`'); process.exit(1) }

const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]/g, '')
const titleCase = (s) => s.replace(/[-_/]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()).trim()
const ghRepo = (url) => { const m = (url || '').match(/github\.com\/([^/]+)\/([^/#?]+)/i); return m ? `${m[1]}/${m[2].replace(/\.git$/, '')}` : null }

// ── repo facts, memoised (many skills share one repo) ─────────────────────────────────────────────
const repoCache = new Map()
async function repoFacts(repo) {
  if (repoCache.has(repo)) return repoCache.get(repo)
  const p = (async () => {
    try {
      const r = await fetch(`https://api.github.com/repos/${repo}`, { headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json' } })
      if (!r.ok) return null
      const j = await r.json()
      if (j.archived) return null
      return { stars: j.stargazers_count || 0, license: j.license?.spdx_id || null }
    } catch { return null }
  })()
  repoCache.set(repo, p)
  return p
}

// ── spine 1: anthropics/skills — SKILL.md frontmatter ─────────────────────────────────────────────
function walkSkillDirs(node, prefix, out) {
  for (const f of node.files || []) {
    const p = prefix ? prefix + '/' + f.name : f.name
    if (f.type === 'directory') walkSkillDirs(f, p, out)
    else if (f.name === 'SKILL.md') out.push(prefix)
  }
  return out
}
function frontmatter(md) {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/); const o = {}
  if (m) for (const line of m[1].split('\n')) { const i = line.indexOf(':'); if (i > 0) o[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^['"]|['"]$/g, '') }
  return o
}
async function anthropicSkills() {
  const repo = 'anthropics/skills'
  const tree = await (await fetch('https://data.jsdelivr.com/v1/packages/gh/' + repo + '@main')).json()
  const dirs = walkSkillDirs(tree, '', []).filter(Boolean)
  const facts = await repoFacts(repo)
  const out = []
  for (let i = 0; i < dirs.length; i += 20) await Promise.all(dirs.slice(i, i + 20).map(async (dir) => {
    try {
      const md = await (await fetch('https://cdn.jsdelivr.net/gh/' + repo + '@main/' + dir + '/SKILL.md')).text()
      const fm = frontmatter(md); const slug = dir.split('/').pop()
      out.push({ id: 'skill-' + norm(dir), name: fm.name ? titleCase(fm.name) : titleCase(slug),
        summary: (fm.description || titleCase(slug) + ' skill').split('. ')[0].slice(0, 150),
        repo, stars: facts?.stars || 0, license: facts?.license || 'Apache-2.0', source: 'anthropics' })
    } catch {}
  }))
  return out
}

// ── spine 2: VoltAgent/awesome-agent-skills — list rows ───────────────────────────────────────────
async function voltSkills() {
  const md = await (await fetch('https://cdn.jsdelivr.net/gh/VoltAgent/awesome-agent-skills@main/README.md')).text()
  const re = /^[-*]\s+\*{0,2}\[([^\]]+)\]\((https?:\/\/github\.com\/[^)]+)\)\*{0,2}\s*[-–—:]\s*(.+?)\s*$/gm
  const seen = new Set(); const rows = []; let m
  while ((m = re.exec(md))) {
    const repo = ghRepo(m[2]); if (!repo) continue
    const label = m[1].trim(); const slug = label.includes('/') ? label.split('/').pop() : label
    const id = 'skill-' + norm(repo.split('/')[1] + '-' + slug)
    if (seen.has(id)) continue; seen.add(id)
    rows.push({ id, name: titleCase(slug), summary: m[3].replace(/\s+/g, ' ').slice(0, 150), repo })
  }
  const out = []
  for (let i = 0; i < rows.length; i += 16) await Promise.all(rows.slice(i, i + 16).map(async (r) => {
    const f = await repoFacts(r.repo); if (!f || !f.license) return // require an active, licensed repo
    out.push({ ...r, stars: f.stars, license: f.license, source: 'voltagent' })
    process.stdout.write(out.length % 25 === 0 ? `\r  enriched ${out.length}…   ` : '')
  }))
  return out
}

// ── run ──────────────────────────────────────────────────────────────────────────────────────────
const [anthropic, volt] = [await anthropicSkills(), await voltSkills()]
process.stdout.write('\n')
const byId = new Map()
for (const s of [...anthropic, ...volt].sort((a, b) => b.stars - a.stars)) if (!byId.has(s.id)) byId.set(s.id, s)
const final = [...byId.values()].sort((a, b) => b.stars - a.stars)

mkdirSync(join(ROOT, 'tools', 'data'), { recursive: true })
writeFileSync(join(ROOT, 'tools', 'data', 'skills.json'), JSON.stringify(final, null, 0) + '\n')
console.log(`✓ ${final.length} skills (anthropics:${anthropic.length} + voltagent:${volt.length}, deduped)`)
console.log(`  unique repos: ${repoCache.size} · top: ${final.slice(0, 4).map((s) => s.name + '★' + s.stars).join(', ')}`)
console.log(`  → tools/data/skills.json (build-artifact cache; gen-registry.mjs ingests it)`)
