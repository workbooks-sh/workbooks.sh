// file-icons.js — colorful VS Code file-type glyphs for the Files IDE (Svelte/Rust/Elixir/JS/…). Split out
// of icons.js on purpose: the @iconify-json/vscode-icons set is ~3.6MB, and it's used ONLY by the Code
// page (FileTree + FileEditor). Importing it here — reached only through the lazy-loaded Code page — keeps
// those 3.6MB out of the app's main bundle.
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
