// The EXTENSION HOST seam — a `vscode` API shim mapped onto the Dock. This is the emulation-thesis payoff:
// a VS Code extension is untrusted JS (`extension.js` activating against the `vscode` namespace). The real
// path compiles that JS to wasm and runs it in the sandbox; here it runs in-page against the SAME shim — the
// point is the shim, which adapts the `vscode` API onto our host capabilities:
//
//   vscode.workspace.fs.readFile  → dock.fs.read          vscode.window.createTerminal → dock.shell.exec
//   vscode.languages.register*    → our provider registry  vscode.commands.register*    → our command map
//
// So an extension never touches the host directly — only the Dock, via this adapter. Whatever an extension
// contributes (completions, commands) flows back into the workbench (dock.lang merges the completions below).
import { dock } from './index.js'

const completionProviders = [] // { extId, selector, provider }
const commands = {}            // id → fn
export const activeExtensions = [] // { id, displayName }

// build the `vscode` namespace an extension activates against — scoped to the extension's id
function createVscodeApi(extId) {
  return {
    workspace: {
      fs: {
        readFile: (uri) => dock.fs.read(uri.path ?? uri),
        writeFile: (uri, content) => dock.fs.write(uri.path ?? uri, content),
        readDirectory: (uri) => dock.fs.list(uri.path ?? uri)
      },
      getConfiguration: () => ({ get: () => undefined })
    },
    window: {
      createTerminal: () => ({ sendText: (t) => dock.shell.exec(t), show() {} }),
      showInformationMessage: (m) => { console.info(`[ext:${extId}] ${m}`); return Promise.resolve() }
    },
    languages: {
      registerCompletionItemProvider: (selector, provider) => {
        const entry = { extId, selector, provider }
        completionProviders.push(entry)
        return { dispose: () => { const i = completionProviders.indexOf(entry); if (i >= 0) completionProviders.splice(i, 1) } }
      }
    },
    commands: {
      registerCommand: (id, fn) => { commands[id] = fn; return { dispose: () => { delete commands[id] } } },
      executeCommand: (id, ...args) => commands[id]?.(...args)
    },
    CompletionItemKind: { Snippet: 'snippet', Keyword: 'keyword', Function: 'function', Variable: 'variable' }
  }
}

// activate an extension module ({ id, displayName, activate(vscode) }) against a fresh scoped shim
export function activateExtension(ext) {
  if (activeExtensions.some((e) => e.id === ext.id)) return
  try { ext.activate(createVscodeApi(ext.id)); activeExtensions.push({ id: ext.id, displayName: ext.displayName || ext.id }) }
  catch (e) { console.warn('[ext-host] activate failed', ext.id, e?.message) }
}

// aggregate completions contributed by activated extensions for a given language id — merged by dock.lang
export function extCompletions(languageId, ctx) {
  const out = []
  for (const { selector, provider } of completionProviders) {
    if (selector && selector !== languageId && selector !== '*') continue
    try {
      const items = provider.provideCompletionItems?.(ctx) || []
      for (const it of items) out.push({ label: it.label, type: it.kind || 'text', info: it.detail || it.documentation, insert: it.insertText })
    } catch { /* a misbehaving provider can't break completion */ }
  }
  return out
}

// ── a BUILT-IN sample extension, authored exactly like a real VSIX `extension.js` (activates against the
// `vscode` namespace, knows nothing of the Dock). Proves the whole chain end-to-end: vscode API → shim →
// Dock → editor. A downloaded VSIX would run identically, just compiled-to-wasm in the sandbox. ──
const workbooksSnippets = {
  id: 'workbooks.snippets',
  displayName: 'Workbooks Snippets',
  activate(vscode) {
    vscode.languages.registerCompletionItemProvider('work', {
      provideCompletionItems() {
        const k = vscode.CompletionItemKind.Snippet
        return [
          { label: 'resource…', kind: k, detail: 'snippet · Workbooks Snippets', insertText: 'resource :name do\n  field :title, :string\nend' },
          { label: 'flow…', kind: k, detail: 'snippet · Workbooks Snippets', insertText: 'flow :name do\n  step :one, run: "…"\nend' },
          { label: 'agent…', kind: k, detail: 'snippet · Workbooks Snippets', insertText: 'agent :name do\n  model "claude-opus-4-8"\nend' }
        ]
      }
    })
    vscode.commands.registerCommand('workbooks.hello', () => vscode.window.showInformationMessage('Workbooks Snippets active'))
  }
}

let bootstrapped = false
export function bootstrapExtensions() {
  if (bootstrapped) return
  bootstrapped = true
  activateExtension(workbooksSnippets)
}
