// Every icon in the app comes from the FULL Iconoir set (1682 glyphs) — no hand-rolled SVGs.
// Loaded as Iconify data (name → currentColor body); render any by name, picker lists them all.
import { icons as ICONOIR } from '@iconify-json/iconoir'

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
  chat: 'chat-bubble', agent: 'cpu', appWindow: 'app-window', flow: 'git-fork'
}
export const ICO = Object.fromEntries(Object.entries(ROLE).map(([k, n]) => [k, iconSvgByName(n, 20)]))

// kind → pastel accent color (mint is our green; there is no purple). Color carries the kind.
export const KIND_COLOR = {
  chat: 'var(--color-dim)',
  app: 'var(--color-sky)',
  agent: 'var(--color-mint)',
  workflow: 'var(--color-peach)'
}

// surface/workspace icons store an Iconoir name; resolve with a per-kind default if unset/unknown
const KIND_DEFAULT = { chat: 'chat-bubble', app: 'app-window', agent: 'cpu', workflow: 'git-fork' }
export function iconSvg(name, kind, size = 16) {
  const resolved = SET[name] ? name : (KIND_DEFAULT[kind] || 'square')
  return iconSvgByName(resolved, size)
}
