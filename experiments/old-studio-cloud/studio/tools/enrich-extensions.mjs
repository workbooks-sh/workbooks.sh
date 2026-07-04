// Extension ENRICH + CLASSIFY — pares the 14,985-extension registry down to a curated, classified set.
// We don't need all 15k; we need the redistributable, sandbox-capable, repurposable ones, grouped by domain.
// Pipeline: (1) pull the top N by downloadCount (search sortBy), (2) fetch each one's DETAIL (license,
// categories, tags), (3) classify MECHANICALLY from the structured fields. Writes tools/data/extensions-
// classified.json + prints the distribution. Run: node tools/enrich-extensions.mjs [N]
import { writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const API = 'https://open-vsx.org/api'
const N = Number(process.argv[2] || 1000)

// ── license tiers: permissive = OK to ship as a shared capability; copyleft = review; none/unknown = exclude
const PERMISSIVE = new Set(['mit', 'apache-2.0', 'apache 2.0', 'bsd-2-clause', 'bsd-3-clause', 'isc', '0bsd', 'mpl-2.0', 'unlicense', 'cc0-1.0', 'wtfpl', 'zlib'])
const COPYLEFT = new Set(['gpl-2.0', 'gpl-3.0', 'agpl-3.0', 'lgpl-2.1', 'lgpl-3.0', 'gpl-3.0-only', 'gpl-3.0-or-later'])
function licenseTier(lic) {
  if (!lic) return 'none'
  const l = String(lic).toLowerCase()
  if (PERMISSIVE.has(l)) return 'permissive'
  if (COPYLEFT.has(l) || l.includes('gpl')) return 'copyleft'
  return 'other'
}

// ── repurposability: map the VS Code category to whether the contribution is usable BEYOND the editor (as an
// agent tool / app capability), an editor-only tool, or pure cosmetic chrome. Highest-value category wins.
const CAPABILITY = ['Formatters', 'Linters', 'Programming Languages', 'SCM Providers', 'Testing', 'Data Science', 'Machine Learning', 'Visualization', 'Notebooks']
const EDITOR_TOOL = ['Snippets', 'Debuggers', 'Other', 'Education', 'Extension Packs', 'AI', 'Chat']
const COSMETIC = ['Themes', 'Color Themes', 'Icon Themes', 'Product Icon Themes', 'Keymaps', 'Language Packs']
function repurpose(categories = []) {
  if (categories.some((c) => CAPABILITY.includes(c))) return 'app-capability'
  if (categories.some((c) => EDITOR_TOOL.includes(c))) return 'editor-tool'
  if (categories.some((c) => COSMETIC.includes(c))) return 'cosmetic'
  return 'editor-tool'
}

// ── domain + toolchain from tags + name/description keywords (longest-intent first)
const DOMAIN_RULES = [
  ['ai', /\b(copilot|\bai\b|llm|gpt|openai|anthropic|claude|codeium|tabnine|genai|chatbot)\b/],
  ['data', /\b(sql|postgres|mysql|sqlite|mongo|redis|prisma|database|\bdb\b|bigquery|snowflake|duckdb|parquet)\b/],
  ['devops', /\b(docker|kubernetes|k8s|terraform|helm|ansible|aws|azure|gcp|cloud|devops|ci\/cd|pulumi|serverless)\b/],
  ['web', /\b(react|vue|angular|svelte|tailwind|css|html|next\.?js|nuxt|astro|frontend|webpack|vite)\b/],
  ['testing', /\b(test|jest|vitest|cypress|playwright|coverage|mocha|pytest|junit)\b/],
  ['security', /\b(security|vulnerab|\bcve\b|secret|vault|sast|snyk|sonar)\b/],
  ['docs', /\b(markdown|latex|asciidoc|restructuredtext|mdx|docs|documentation)\b/],
  ['lang', /\b(python|rust|golang|\bgo\b|java|kotlin|c\+\+|cpp|c#|csharp|ruby|php|swift|scala|elixir|haskell|dart|lua|zig)\b/],
  ['scm', /\b(git|github|gitlab|bitbucket|version control|gitlens)\b/],
  ['editor', /\b(theme|icon|keymap|font|color|cursor)\b/]
]
function domainOf(text) {
  const t = (text || '').toLowerCase()
  for (const [dom, re] of DOMAIN_RULES) if (re.test(t)) return dom
  return 'other'
}
// toolchain = the most specific named ecosystem in the tags
const TOOLCHAINS = ['docker', 'kubernetes', 'terraform', 'graphql', 'prisma', 'tailwindcss', 'tailwind', 'eslint', 'prettier', 'jest', 'pytest', 'react', 'vue', 'angular', 'svelte', 'rust', 'python', 'golang', 'aws', 'azure', 'gcp', 'postgres', 'mongodb', 'redis', 'kafka', 'grpc', 'protobuf', 'helm', 'ansible']
function toolchainOf(tags = [], name = '') {
  const hay = (tags.join(' ') + ' ' + name).toLowerCase()
  for (const tc of TOOLCHAINS) if (hay.includes(tc)) return tc
  return null
}

async function jget(url) { const r = await fetch(url); if (!r.ok) throw new Error(r.status + ' ' + url); return r.json() }

// 1) top N by downloads
console.log(`fetching top ${N} by downloads …`)
const top = []
for (let off = 0; off < N; off += 100) {
  const j = await jget(`${API}/-/search?size=100&offset=${off}&sortBy=downloadCount&sortOrder=desc`)
  for (const e of j.extensions || []) top.push({ ns: e.namespace, name: e.name, id: `${e.namespace}.${e.name}`, displayName: e.displayName || e.name, description: e.description || '', downloads: e.downloadCount || 0 })
  if (!(j.extensions || []).length) break
}
console.log(`got ${top.length}; enriching with detail (license/categories/tags) …`)

// 2) enrich with detail, in bounded-concurrency batches
const out = []
const BATCH = 16
for (let i = 0; i < top.length; i += BATCH) {
  const slice = top.slice(i, i + BATCH)
  const got = await Promise.all(slice.map(async (e) => {
    try {
      const d = await jget(`${API}/${e.ns}/${e.name}`)
      const tags = d.tags || []
      const categories = d.categories || []
      return {
        ...e, license: d.license || null, categories, repo: d.repository || null,
        web: tags.includes('__web_extension'),
        fileTypes: tags.filter((t) => t.startsWith('__ext_')).map((t) => t.slice(6)).slice(0, 8),
        // 3) mechanical classification
        licenseTier: licenseTier(d.license),
        repurpose: repurpose(categories),
        domain: domainOf(`${e.displayName} ${e.description} ${categories.join(' ')} ${tags.filter((t) => !t.startsWith('__')).join(' ')}`),
        toolchain: toolchainOf(tags, e.id)
      }
    } catch { return { ...e, license: null, licenseTier: 'none', categories: [], repurpose: 'editor-tool', domain: domainOf(e.displayName + ' ' + e.description), toolchain: null, web: false, fileTypes: [] } }
  }))
  out.push(...got)
  process.stdout.write(`\r  enriched ${out.length}/${top.length}`)
}
console.log('')

mkdirSync(join(ROOT, 'tools', 'data'), { recursive: true })
writeFileSync(join(ROOT, 'tools', 'data', 'extensions-classified.json'), JSON.stringify(out))

// distribution report
const tally = (key) => out.reduce((m, e) => ((m[e[key]] = (m[e[key]] || 0) + 1), m), {})
const shippable = out.filter((e) => e.licenseTier === 'permissive')
const capability = shippable.filter((e) => e.repurpose === 'app-capability')
console.log('\n── distribution (top ' + out.length + ') ──')
console.log('licenseTier:', JSON.stringify(tally('licenseTier')))
console.log('repurpose:  ', JSON.stringify(tally('repurpose')))
console.log('domain:     ', JSON.stringify(tally('domain')))
console.log('web-capable:', out.filter((e) => e.web).length)
console.log('\nSHIPPABLE (permissive):', shippable.length, '| APP-CAPABILITY + permissive:', capability.length, '| + web:', capability.filter((e) => e.web).length)
console.log('→ tools/data/extensions-classified.json')
