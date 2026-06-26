// you.js — the data + crypto + heatmap logic behind the "You" page. Framework-free (no runes); You.svelte
// holds the $state and calls these. Ports the legacy views/profile.js verbatim in behaviour:
//   • profile (resource Profile)         GET/POST /cloud/profile
//   • CLI tokens (PATs)                   GET /api/platform/tokens · POST …/mint · DELETE …/{id}
//   • author device keys (Ed25519)       GET/POST /cloud/keys · POST /cloud/keys/revoke
// Two modes, like the rest of the app: live (a runtime answers) vs demo (auth.offline → fixtures). The
// SAME page renders both — offline simply swaps the network calls for a believable in-memory fixture.
import { api } from './api.js'

export const ACCENTS = ['peach', 'blue', 'mint', 'sky', 'violet', 'cream', 'sage']

// surface → a friendly label, icon and accent for the device-key rows (replaces the raw emoji + DID dump)
export const SURFACE_META = {
  browser: { label: 'Browser', icon: 'globe', tint: 'var(--color-sky)' },
  cli: { label: 'CLI', icon: 'terminal', tint: 'var(--color-mint)' },
  editor: { label: 'Editor', icon: 'code', tint: 'var(--color-violet)' },
  agent: { label: 'Agent', icon: 'cpu', tint: 'var(--color-peach)' }
}
// A did:key is long and noisy. Show a readable fingerprint: drop the prefix + the XXXX demo padding,
// keep the first 8 and last 4 of the multibase body → "z6MkBrow…WXYZ".
export function shortDid(did) {
  const body = String(did || '').replace(/^did:key:/, '').replace(/X+/g, '')
  return body.length > 16 ? body.slice(0, 8) + '…' + body.slice(-4) : body
}

// ── heatmap math (ported from the legacy GitHub-style contribution calendar) ──────────────────────
export const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
export const METRICS = [
  { key: 'tokens', label: 'Tokens used', acc: 'var(--color-violet)', noun: 'tokens', sum: true },
  { key: 'runs', label: 'Runs launched', acc: 'var(--color-mint)', noun: 'runs', sum: false },
  { key: 'shipped', label: 'Contributions shipped', acc: 'var(--color-peach)', noun: 'shipped', sum: false },
  { key: 'agents', label: 'Agents driven', acc: 'var(--color-sky)', noun: 'agent-days', sum: false }
]
export const isoDay = (d) => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')

export function calDays() {
  const end = new Date(); end.setHours(0, 0, 0, 0)
  const start = new Date(end); start.setDate(start.getDate() - 363)
  start.setDate(start.getDate() - start.getDay()) // back up to Sunday → aligned week columns
  const days = []; const d = new Date(start)
  while (d <= end) { days.push(new Date(d)); d.setDate(d.getDate() + 1) }
  return days
}
export const levelOf = (v, max) => { if (!v) return 0; const q = Math.ceil((v / max) * 4); return Math.max(1, Math.min(4, q)) }
export const cellColor = (level, acc) => level ? `color-mix(in srgb, ${acc} ${[35, 60, 82, 100][level - 1]}%, transparent)` : 'var(--you-empty)'

// ── parsing helpers ───────────────────────────────────────────────────────────────────────────────
export function parseLinks(s) {
  return String(s || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    const i = l.indexOf('|'); return i < 0 ? { label: l, url: l } : { label: l.slice(0, i).trim(), url: l.slice(i + 1).trim() }
  })
}
export const fmtNum = (n) => { n = n || 0; return n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'k' : String(n) }
export function timeAgo(us) {
  if (!us) return ''; const sec = Math.floor(Date.now() / 1000) - Math.floor(us / 1e6)
  if (sec < 60) return 'just now'; if (sec < 3600) return Math.floor(sec / 60) + 'm ago'
  if (sec < 86400) return Math.floor(sec / 3600) + 'h ago'; return Math.floor(sec / 86400) + 'd ago'
}

// ── demo fixture — a believable year of activity so the standalone demo looks alive ──────────────
function demoActivity() {
  const out = { tokens: {}, runs: {}, shipped: {}, agents: {}, verified: { runs: {}, tokens: {} } }
  let seed = 1337
  const rng = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff
  for (const d of calDays()) {
    const k = isoDay(d), dow = d.getDay()
    const active = rng() > (dow === 0 || dow === 6 ? 0.78 : 0.42)
    if (!active) continue
    const runs = 1 + Math.floor(rng() * 6)
    out.runs[k] = runs
    out.tokens[k] = runs * (800 + Math.floor(rng() * 4200))
    if (rng() > 0.55) out.shipped[k] = 1 + Math.floor(rng() * 3)
    out.agents[k] = 1 + Math.floor(rng() * 3)
    out.verified.runs[k] = Math.max(0, runs - Math.floor(rng() * 2))
    out.verified.tokens[k] = Math.floor(out.tokens[k] * (0.7 + rng() * 0.3))
  }
  return out
}
function sumSeries(s) { return Object.values(s || {}).reduce((a, b) => a + b, 0) }

function demoYou() {
  const activity = demoActivity()
  return {
    profile: { display: 'Shane Murphy', tagline: 'Building the chat-native agent runtime', bio: 'Founder. I build the thing we run ourselves first.', location: 'San Francisco', links: 'GitHub|https://github.com/shinyobjectz\nSite|https://workbooks.sh', avatar: '', accent: 'peach' },
    stats: { tokens: sumSeries(activity.tokens), runs: sumSeries(activity.runs), runs_ok: Math.floor(sumSeries(activity.runs) * 0.94), agents: 4, shipped: sumSeries(activity.shipped), open: 3, first_run: Math.floor(Date.now() / 1000) - 86400 * 280, verified_runs: sumSeries(activity.verified.runs), verified_tokens: sumSeries(activity.verified.tokens) },
    activity,
    contributions: [
      { title: 'Live-shapes sync layer over WebSocket', kind: 'task', agent: 'workhorse', status: 'done', updated: (Date.now() - 2 * 3600e3) * 1000 },
      { title: 'Threads + reactions + read cursors', kind: 'task', agent: 'workhorse', status: 'done', updated: (Date.now() - 26 * 3600e3) * 1000 },
      { title: 'Unified Surface/kind model', kind: 'task', status: 'in_progress', updated: (Date.now() - 3 * 3600e3) * 1000 },
      { title: 'Files import — local dir or GitHub repo', kind: 'issue', status: 'open', updated: (Date.now() - 50 * 3600e3) * 1000 }
    ],
    runtime_did: 'did:key:z6MkdemoRuntimeCounterSignerXXXXXXXXXXXXXXXXXX',
    keys: [
      { did: 'did:key:z6MkBrowserDemoKeyXXXXXXXXXXXXXXXXXXXXXXXXXX', label: 'MacIntel', surface: 'browser', registered: Math.floor(Date.now() / 1000) - 86400 * 12, revoked: 0 },
      { did: 'did:key:z6MkCliDemoKeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', label: 'work CLI', surface: 'cli', registered: Math.floor(Date.now() / 1000) - 86400 * 40, revoked: 0 }
    ],
    tokens: [{ id: 'wbk_demo_1a2b', name: 'my-laptop' }]
  }
}

// ── load / save ───────────────────────────────────────────────────────────────────────────────────
export async function loadYou(uid, offline) {
  if (offline) return demoYou()
  const out = { profile: {}, stats: {}, activity: { tokens: {}, runs: {}, shipped: {}, agents: {}, verified: {} }, contributions: [], runtime_did: null, keys: [], tokens: [] }
  try {
    const r = await api.get('/cloud/profile?u=' + encodeURIComponent(uid))
    Object.assign(out, { profile: r.profile || {}, stats: r.stats || {}, contributions: r.contributions || [], runtime_did: r.runtime_did || null, keys: r.keys || [] })
    if (r.activity) out.activity = Object.assign(out.activity, r.activity)
  } catch (_) {}
  try { const t = await api.plat('/tokens'); out.tokens = t.tokens || t || [] } catch (_) { out.tokens = [] }
  return out
}

export async function saveProfile(uid, draft, offline) {
  if (offline) return { ...draft }
  const r = await api.post('/cloud/profile', { u: uid, ...draft })
  return (r && r.profile) || draft
}

// ── CLI tokens ────────────────────────────────────────────────────────────────────────────────────
export async function mintToken(name, offline) {
  if (offline) return { token: 'wbk_demo_' + Math.random().toString(36).slice(2, 14), id: 'wbk_demo_' + Math.random().toString(36).slice(2, 6), name }
  return api.plat('/tokens/mint', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name }) })
}
export async function listTokens(offline) { if (offline) return []; try { const t = await api.plat('/tokens'); return t.tokens || t || [] } catch (_) { return [] } }
export async function revokeToken(id, offline) { if (offline) return; await api.plat('/tokens/' + encodeURIComponent(id), { method: 'DELETE' }) }

// ── author device keys (Ed25519 in WebCrypto + IndexedDB; proof-of-possession registration) ────────
const B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
function base58(bytes) {
  let zeros = 0; while (zeros < bytes.length && bytes[zeros] === 0) zeros++
  const digits = [0]
  for (let i = zeros; i < bytes.length; i++) {
    let carry = bytes[i]
    for (let j = 0; j < digits.length; j++) { carry += digits[j] << 8; digits[j] = carry % 58; carry = (carry / 58) | 0 }
    while (carry) { digits.push(carry % 58); carry = (carry / 58) | 0 }
  }
  let out = '1'.repeat(zeros)
  for (let k = digits.length - 1; k >= 0; k--) out += B58[digits[k]]
  return out
}
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')
function idbOpen() {
  return new Promise((res, rej) => { const r = indexedDB.open('wb-keys', 1)
    r.onupgradeneeded = () => r.result.createObjectStore('k'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error) })
}
async function idbGet(key) { const db = await idbOpen(); return new Promise((res, rej) => { const t = db.transaction('k').objectStore('k').get(key); t.onsuccess = () => res(t.result); t.onerror = () => rej(t.error) }) }
async function idbSet(key, val) { const db = await idbOpen(); return new Promise((res, rej) => { const t = db.transaction('k', 'readwrite'); t.objectStore('k').put(val, key); t.oncomplete = () => res(); t.onerror = () => rej(t.error) }) }

async function ensureDeviceKey(uid) {
  if (!(window.crypto && crypto.subtle && window.indexedDB)) return null
  try {
    const slot = 'dev:' + uid
    let rec = await idbGet(slot)
    if (!rec || !rec.priv) {
      const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify'])
      const rawPub = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey))
      const pkcs8 = await crypto.subtle.exportKey('pkcs8', kp.privateKey)
      const priv = await crypto.subtle.importKey('pkcs8', pkcs8, { name: 'Ed25519' }, false, ['sign'])
      const did = 'did:key:z' + base58(Uint8Array.from([0xed, 0x01, ...rawPub]))
      rec = { did, priv }
      await idbSet(slot, rec)
    }
    return rec
  } catch (_) { return null }
}

// Register this browser as a device under the user's identity. Returns {did, keys?} or null. Offline = no-op.
export async function registerThisDevice(uid, knownKeys, offline) {
  if (offline) return null
  const rec = await ensureDeviceKey(uid)
  if (!rec) return null
  if ((knownKeys || []).some((k) => k.did === rec.did && !k.revoked)) return { did: rec.did }
  try {
    const msg = 'wb-author-key\nuid=' + uid + '\ndid=' + rec.did
    const sig = await crypto.subtle.sign({ name: 'Ed25519' }, rec.priv, new TextEncoder().encode(msg))
    await api.rt('/cloud/keys', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ u: uid, did: rec.did, sig: hex(sig), label: (navigator.platform || 'Browser'), surface: 'browser' }) })
    const r = await api.get('/cloud/keys?u=' + encodeURIComponent(uid))
    return { did: rec.did, keys: r.keys }
  } catch (_) { return { did: rec.did } }
}

export async function revokeKey(uid, did, offline) {
  if (offline) return null
  await api.rt('/cloud/keys/revoke', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ u: uid, did }) })
  try { const r = await api.get('/cloud/keys?u=' + encodeURIComponent(uid)); return r.keys } catch (_) { return null }
}
