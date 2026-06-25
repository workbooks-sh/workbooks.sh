// Every icon in the app comes from the FULL Iconoir set (1682 glyphs) — no hand-rolled SVGs.
// Loaded as Iconify data (name → currentColor body); render any by name, picker lists them all.
import { icons as ICONOIR } from '@iconify-json/iconoir'
// Colorful file-type glyphs for the Files IDE (Svelte/Rust/Elixir/JS/…). These ship their OWN fills
// (not currentColor), so they render in-color like a VS Code icon theme — same vibe as the real app.
import { icons as VSCODE } from '@iconify-json/vscode-icons'

const VSET = VSCODE.icons, VW = VSCODE.width || 32, VH = VSCODE.height || 32
// render a vscode-icons glyph as-is (keeps its built-in colors)
export function vsIcon(name, size = 16) {
  const ic = VSET[name]
  if (!ic) return ''
  const w = ic.width || VW, h = ic.height || VH
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg">${ic.body}</svg>`
}
// extension/filename → vscode-icons name. .work is handled specially (branded) by the caller.
const FILE_ICON = {
  svelte: 'file-type-svelte', rs: 'file-type-rust', ex: 'file-type-elixir', exs: 'file-type-elixir',
  js: 'file-type-js', mjs: 'file-type-js', cjs: 'file-type-js', jsx: 'file-type-reactjs',
  ts: 'file-type-typescript', tsx: 'file-type-reactjs', json: 'file-type-json', md: 'file-type-markdown',
  css: 'file-type-css', html: 'file-type-html', toml: 'file-type-toml', yaml: 'file-type-yaml', yml: 'file-type-yaml',
  go: 'file-type-go', zig: 'file-type-zig', lua: 'file-type-lua', txt: 'file-type-text', lock: 'file-type-yaml',
  svg: 'file-type-svg', csv: 'file-type-text'
}
export const fileIconName = (filename) => FILE_ICON[(filename.split('.').pop() || '').toLowerCase()] || 'default-file'
export const isWorkFile = (filename) => filename.toLowerCase().endsWith('.work')

const DEF_W = ICONOIR.width || 24
const DEF_H = ICONOIR.height || 24
const SET = ICONOIR.icons

export const ALL_ICON_NAMES = Object.keys(SET)
export const hasIcon = (name) => !!SET[name]

// render any Iconoir icon by name → inline <svg> string (uses currentColor; CSS sizes it)
export function iconSvgByName(name, size = 18) {
  const ic = SET[name]
  if (!ic) return ''
  const w = ic.width || DEF_W
  const h = ic.height || DEF_H
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg">${ic.body}</svg>`
}

// app-role → Iconoir name. Keeps existing `{@html ICO.x}` call sites working, now from the real set.
const ROLE = {
  search: 'search', plus: 'plus', gear: 'settings', settings: 'settings',
  tree: 'multiple-pages', chev: 'nav-arrow-right', caret: 'nav-arrow-right',
  spark: 'sparks', grid: 'view-grid', files: 'folder', sheet: 'table',
  toolbox: 'tools', admin: 'shield', upload: 'upload', download: 'download',
  page: 'empty-page', attachment: 'attachment', xmark: 'xmark', bell: 'bell',
  chat: 'chat-bubble', agent: 'cpu', appWindow: 'app-window', flow: 'git-fork',
  audit: 'light-bulb', play: 'play', pause: 'pause', sound: 'sound-high'
}
export const ICO = Object.fromEntries(Object.entries(ROLE).map(([k, n]) => [k, iconSvgByName(n, 20)]))

// kind → pastel accent color (mint is our green; there is no purple). Color carries the kind.
// data FORMATS — classified by the shape you work with (engine is a secondary detail). Each has its
// own ICON, but ALL data shares ONE color (fuchsia) so "this is a data source" reads at a glance.
export const DATA_COLOR = 'var(--color-mint)'
export const DB_FORMAT = {
  sheet:    { icon: 'table', color: DATA_COLOR, label: 'Sheet' },
  sqlite:   { icon: 'database', color: DATA_COLOR, label: 'SQLite' },
  postgres: { icon: 'database', color: DATA_COLOR, label: 'Postgres' },
  json:     { icon: 'code-brackets', color: DATA_COLOR, label: 'JSON' },
  logs:     { icon: 'list', color: DATA_COLOR, label: 'Log' },
  vector:   { icon: 'network', color: DATA_COLOR, label: 'Vector' }
}
export const dbFormat = (f) => DB_FORMAT[f] || DB_FORMAT.sheet

export const KIND_COLOR = {
  chat: 'var(--color-dim)',
  app: 'var(--color-sky)',
  database: 'var(--color-mint)',
  agent: 'var(--color-fuchsia)',
  workflow: 'var(--color-peach)',
  dm: 'var(--color-dim)'
}

// surface/workspace icons store an Iconoir name; resolve with a per-kind default if unset/unknown
const KIND_DEFAULT = { chat: 'chat-bubble', app: 'app-window', agent: 'cpu', workflow: 'git-fork' }
export function iconSvg(name, kind, size = 16) {
  const resolved = SET[name] ? name : (KIND_DEFAULT[kind] || 'square')
  return iconSvgByName(resolved, size)
}
