// The EXTENSION HOST seam — a `vscode` API shim mapped onto the Dock. This is the emulation-thesis payoff:
// a VS Code extension is untrusted JS (`extension.js` activating against the `vscode` namespace). The real
// path compiles that JS to wasm and runs it in the sandbox; here it runs in-page against the SAME shim — the
// point is the shim, which adapts the `vscode` API onto our host capabilities:
//
//   vscode.workspace.fs.readFile  → dock.fs.read          vscode.window.createTerminal → dock.shell.exec
//   vscode.languages.register*    → our provider registry  vscode.commands.register*    → our command map
//   vscode.window.showInformation* → a workbench toast      (so a command's effect is visible)
//
// Whatever an extension CONTRIBUTES surfaces where its type belongs: completions → the editor (dock.lang
// merges them); commands → the Command Palette (extCommands); disabling an extension drops its contributions.
import { dock } from './index.js'
import { pushToast } from '../toast.svelte.js'

const completionProviders = [] // { extId, selector, provider }
const commandList = []         // { id, extId, title, run }
const commands = {}            // id → fn (for executeCommand)
const enabledMap = new Map()   // extId → bool
export const activeExtensions = [] // { id, displayName, contributes: { completions, commands } } — set at bootstrap

const isEnabled = (extId) => enabledMap.get(extId) !== false
const titleOf = (id, displayName) => {
  const last = id.split('.').pop().replace(/[-_]/g, ' ')
  return `${displayName}: ${last.replace(/\b\w/g, (c) => c.toUpperCase())}`
}

// build the `vscode` namespace an extension activates against — scoped to the extension's id
function createVscodeApi(extId, displayName) {
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
      showInformationMessage: (m) => { pushToast(m); return Promise.resolve() }
    },
    languages: {
      registerCompletionItemProvider: (selector, provider) => {
        const entry = { extId, selector, provider }
        completionProviders.push(entry)
        return { dispose: () => { const i = completionProviders.indexOf(entry); if (i >= 0) completionProviders.splice(i, 1) } }
      }
    },
    commands: {
      registerCommand: (id, fn) => {
        commands[id] = fn
        commandList.push({ id, extId, title: titleOf(id, displayName), run: fn })
        return { dispose: () => { delete commands[id] } }
      },
      executeCommand: (id, ...args) => commands[id]?.(...args)
    },
    CompletionItemKind: { Snippet: 'snippet', Keyword: 'keyword', Function: 'function', Variable: 'variable' }
  }
}

// activate an extension module ({ id, displayName, activate(vscode) }) against a fresh scoped shim
export function activateExtension(ext) {
  if (activeExtensions.some((e) => e.id === ext.id)) return
  const dn = ext.displayName || ext.id
  try {
    ext.activate(createVscodeApi(ext.id, dn))
    enabledMap.set(ext.id, true)
    activeExtensions.push({
      id: ext.id, displayName: dn,
      contributes: {
        completions: completionProviders.filter((p) => p.extId === ext.id).length,
        commands: commandList.filter((c) => c.extId === ext.id).length
      }
    })
  } catch (e) { console.warn('[ext-host] activate failed', ext.id, e?.message) }
}

export function setExtEnabled(extId, on) { enabledMap.set(extId, !!on) }
export const extEnabled = (extId) => isEnabled(extId)

// completions contributed by ENABLED extensions for a language id — merged by dock.lang
export function extCompletions(languageId, ctx) {
  const out = []
  for (const { extId, selector, provider } of completionProviders) {
    if (!isEnabled(extId)) continue
    if (selector && selector !== languageId && selector !== '*') continue
    try {
      const items = provider.provideCompletionItems?.(ctx) || []
      for (const it of items) out.push({ label: it.label, type: it.kind || 'text', info: it.detail || it.documentation, insert: it.insertText })
    } catch { /* a misbehaving provider can't break completion */ }
  }
  return out
}

// commands contributed by ENABLED extensions — surfaced in the Command Palette
export function extCommands() { return commandList.filter((c) => isEnabled(c.extId)) }

// ── a BUILT-IN sample extension, authored exactly like a real VSIX `extension.js` (activates against the
// `vscode` namespace, knows nothing of the Dock). Contributes COMPLETIONS (→ editor) and a COMMAND (→ palette),
// proving both surfaces. A downloaded VSIX runs identically, just compiled-to-wasm in the sandbox. ──
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
    vscode.commands.registerCommand('workbooks.snippets.about', () =>
      vscode.window.showInformationMessage('Workbooks Snippets — adds resource/flow/agent completions to .work files'))
  }
}

let bootstrapped = false
export function bootstrapExtensions() {
  if (bootstrapped) return
  bootstrapped = true
  activateExtension(workbooksSnippets)
}
