// On-brand build (Step 4 / B4) — a `.work` CUSTOM EDITOR PANE registered into the workbench via the editor
// registration point (A3: registerEditorPane + registerEditor). It renders a literate VIEW of a .work file
// (prose narrates; `do … end` blocks are cards with a kind pill) — the workbook-native editor the whole
// thesis points at, vs a plain text buffer. Registered as an OPTION (Reopen With → Workbooks Literate), so
// text editing is preserved. A full WYSIWYG over Nexus.Literate is the next layer; this proves the seam.
import { registerEditorPane, registerEditor, SimpleEditorPane, SimpleEditorInput, RegisteredEditorPriority } from '@codingame/monaco-vscode-views-service-override'
import { fileTree } from '../fs.svelte.js'

const TYPE = 'workbooks.literate'

// resource path (file:///workspace/<rel>) -> the mock file content
function contentForPath(path) {
  const rel = (path || '').replace(/^\/workspace/, '')
  let found = null
  const walk = (nodes) => { for (const n of nodes) { if (n.type === 'file' && n.path === rel) found = n.content; else if (n.children) walk(n.children) } }
  walk(fileTree)
  return found
}

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
const KIND_COLOR = { server: 'sky', client: 'fuchsia', def: 'mint', flow: 'violet', resource: 'peach', hook: 'amber', worker: 'sage', agent: 'bloom', surface: 'sky', deploy: 'peach', app: 'mint', secrets: 'bad' }

// render .work as a literate document: # headings, prose paragraphs, and do…end blocks as kind-pilled cards
function renderLiterate(src) {
  const lines = src.split('\n')
  let html = '', block = null
  const flush = () => { if (block) { const tone = `var(--color-${KIND_COLOR[block.kind] || 'dim'})`
    html += `<div style="margin:10px 0;border:1px solid var(--color-line);border-radius:10px;overflow:hidden">
      <div style="display:flex;align-items:center;gap:8px;padding:6px 10px;background:color-mix(in srgb,${tone} 10%,transparent);border-bottom:1px solid var(--color-line)">
        <span style="font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:${tone}">${block.kind}</span>
        <span style="font-family:var(--font-mono);font-size:11px;color:var(--color-dim)">${esc(block.head)}</span></div>
      <pre style="margin:0;padding:10px;font-family:var(--font-mono);font-size:12px;line-height:1.5;color:var(--color-ink);white-space:pre-wrap">${esc(block.body.join('\n'))}</pre></div>`
    block = null } }
  for (const line of lines) {
    if (block) { if (/^end\b/.test(line.trim()) && line.search(/\S/) <= block.indent) { flush() } else { block.body.push(line); continue } ; continue }
    const m = line.match(/^(\s*)(\w+)\b(.*?)\bdo\b\s*$/)
    if (m && KIND_COLOR[m[2]] !== undefined) { block = { indent: m[1].length, kind: m[2], head: (m[2] + m[3]).trim(), body: [] }; continue }
    const h = line.match(/^(#{1,3})\s+(.*)$/)
    if (h) { const sz = [0, 19, 16, 14][h[1].length]; html += `<div style="font-family:var(--font-display);font-weight:700;font-size:${sz}px;color:var(--color-ink);margin:14px 0 6px">${esc(h[2])}</div>`; continue }
    if (line.trim() === '') { html += '<div style="height:6px"></div>'; continue }
    html += `<p style="margin:3px 0;font-size:13.5px;line-height:1.6;color:var(--color-dim)">${esc(line)}</p>`
  }
  flush()
  return `<div style="max-width:760px;margin:0 auto;padding:24px 28px;font-family:var(--font-sans)">${html}</div>`
}

class WorkInput extends SimpleEditorInput {
  get typeId() { return TYPE + '.input' }
  get editorId() { return TYPE }
}

class WorkPane extends SimpleEditorPane {
  initialize() {
    this.root = document.createElement('div')
    this.root.style.cssText = 'width:100%;height:100%;overflow:auto;background:var(--color-well)'
    return this.root
  }
  async renderInput(input) {
    const src = contentForPath(input?.resource?.path) ?? '# (file not found)\n'
    this.root.innerHTML = renderLiterate(src)
    return { dispose: () => { if (this.root) this.root.innerHTML = '' } }
  }
}

export function registerWorkEditor() {
  registerEditorPane(TYPE, 'Workbooks Literate', WorkPane, [WorkInput])
  registerEditor(
    '**/*.work',
    { id: TYPE, label: 'Workbooks Literate', priority: RegisteredEditorPriority.option },
    {},
    { createEditorInput: ({ resource }) => ({ editor: new WorkInput(resource) }) }
  )
}
