// IDE boot — the recon spike (bd wb-8st4). Goal: prove a VS Code-class workbench (monaco-vscode-api) boots
// CLIENT-SIDE in our vite build, with no backend. This is the go/no-go for the whole IDE-shell epic
// (registry/ide-shell.work). We start with the themed editor + the services init — the hardest part of the
// toolchain (workers + import.meta.url + service DI under vite). Terminal / run / extension-host are the
// washy seams and are NOT wired here; this only answers "does the shell render in our pipeline?".
import * as monaco from '@codingame/monaco-vscode-editor-api'
import { initialize } from '@codingame/monaco-vscode-api/services'
import getThemeServiceOverride from '@codingame/monaco-vscode-theme-service-override'
// registers the built-in default themes (Dark+/Light+) so the theme service has something to resolve
import '@codingame/monaco-vscode-theme-defaults-default-extension'

// vite resolves `?worker` to a real Worker constructor; this is the editor's tokenization/diff worker.
import EditorWorker from '@codingame/monaco-vscode-editor-api/esm/vs/editor/editor.worker.js?worker'

// monaco-vscode-api asks MonacoEnvironment for workers by label; the editor worker covers the base lane.
self.MonacoEnvironment = { getWorker: () => new EditorWorker() }

let booting
export function bootIde() {
  // services may only be initialized once per page; memoise the promise so every mount awaits the same boot
  if (!booting) booting = initialize({ ...getThemeServiceOverride() })
  return booting
}

export async function mountEditor(el, { value = '', language = 'plaintext', theme = 'Default Dark+' } = {}) {
  await bootIde()
  const editor = monaco.editor.create(el, {
    value,
    language,
    theme,
    automaticLayout: true,
    minimap: { enabled: false },
    fontFamily: 'Geist Mono, ui-monospace, monospace',
    fontSize: 13,
    padding: { top: 12 }
  })
  return editor
}

export { monaco }
