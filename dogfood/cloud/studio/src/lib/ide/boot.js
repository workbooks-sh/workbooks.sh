// IDE boot — the recon spike (bd wb-8st4 → epic wb-pntm). Proves a VS Code-class workbench (monaco-vscode-api)
// boots CLIENT-SIDE in our vite build, no backend, and now wears our palette. Terminal / run / extension-host
// are the washy seams and are NOT wired here (see registry/ide-shell.work).
import * as monaco from '@codingame/monaco-vscode-editor-api'
import { initialize } from '@codingame/monaco-vscode-api/services'
import { THEMES, themeForDocument } from './theme.js'

// vite resolves `?worker` to a real Worker constructor; this is the editor's tokenization/diff worker.
import EditorWorker from '@codingame/monaco-vscode-editor-api/esm/vs/editor/editor.worker.js?worker'

// monaco-vscode-api asks MonacoEnvironment for workers by label; the editor worker covers the base lane.
self.MonacoEnvironment = { getWorker: () => new EditorWorker() }

let booting
export function bootIde() {
  // services init once per page; memoise so every mount awaits the same boot. Register our themes here.
  if (!booting) {
    booting = initialize({}).then(() => {
      for (const [name, data] of Object.entries(THEMES)) monaco.editor.defineTheme(name, data)
      monaco.editor.setTheme(themeForDocument())
    })
  }
  return booting
}

export async function mountEditor(el, { value = '', language = 'plaintext' } = {}) {
  await bootIde()
  return monaco.editor.create(el, {
    value,
    language,
    theme: themeForDocument(),
    automaticLayout: true,
    minimap: { enabled: false },
    fontFamily: 'Geist Mono, ui-monospace, monospace',
    fontSize: 13,
    padding: { top: 12 },
    scrollBeyondLastLine: false
  })
}

export { monaco }
