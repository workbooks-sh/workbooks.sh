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
const viewProviders = []       // { extId, id, title, render } — a contributed UI VIEW (the MCP-App / aux-panel analog)
const enabledMap = new Map()   // extId → bool
export const activeExtensions = [] // { id, displayName, contributes: { completions, commands, views } } — set at bootstrap

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
      showInformationMessage: (m) => { pushToast(m); return Promise.resolve() },
      // a contributed UI VIEW — render(container) injects the panel's DOM. This is the demo analog of a webview /
      // MCP-App UI resource; it opens in the persistent right-side aux panel, not the editor.
      registerView: (id, { title, icon, render }) => {
        const entry = { extId, id, title: title || id, icon: icon || 'puzzle', render }
        viewProviders.push(entry)
        return { dispose: () => { const i = viewProviders.indexOf(entry); if (i >= 0) viewProviders.splice(i, 1) } }
      }
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
        commands: commandList.filter((c) => c.extId === ext.id).length,
        views: viewProviders.filter((v) => v.extId === ext.id).length
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

// VIEWS contributed by ENABLED extensions — surfaced in the right-side aux panel (the MCP-App / drawer surface)
export function extViews() { return viewProviders.filter((v) => isEnabled(v.extId)) }
export function extViewById(id) { return viewProviders.find((v) => v.id === id) || null }

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

// a sample VIEW-contributing extension — the MCP-App / aux-panel analog. It registers an interactive UI view
// (render(container) injects real DOM); the footer opens it in the persistent right-side panel. A real MCP-UI
// server would return a UI resource rendered the same way — same surface, different source.
const workbooksPanel = {
  id: 'workbooks.panel',
  displayName: 'Workbooks Panel',
  activate(vscode) {
    vscode.window.registerView('workbooks.snippets-panel', {
      title: 'Snippets', icon: 'journal-page',
      render(container) {
        const snippets = [
          ['resource', 'resource :name do\n  field :title, :string\nend'],
          ['flow', 'flow :name do\n  step :one, run: "…"\nend'],
          ['agent', 'agent :name do\n  model "claude-opus-4-8"\nend'],
          ['hook', 'hook :name do\n  match event: [:thing]\n  notify channel: :ops\nend']
        ]
        container.style.cssText = 'display:flex;flex-direction:column;gap:8px;padding:14px;font-family:var(--font-sans)'
        container.innerHTML = `<div style="font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--color-dim)">Insert a .work block</div>` +
          snippets.map(([k]) => `<button data-k="${k}" style="text-align:left;padding:9px 11px;border:1px solid var(--color-line);border-radius:10px;background:var(--color-well);color:var(--color-ink);font-size:13px;cursor:pointer">${k} …</button>`).join('') +
          `<div data-out style="margin-top:4px;font-size:11px;color:var(--color-dim);font-family:var(--font-mono)"></div>`
        const out = container.querySelector('[data-out]')
        container.querySelectorAll('button[data-k]').forEach((b) => b.addEventListener('click', () => {
          const snip = snippets.find((s) => s[0] === b.dataset.k)[1]
          try { navigator.clipboard.writeText(snip) } catch {}
          out.textContent = `✓ copied "${b.dataset.k}" snippet`
        }))
        return { dispose() { container.innerHTML = '' } }
      }
    })
  }
}

// A REAL-extension example with a UI — modeled on Thunder Client (rangav.vscode-thunder-client on Open VSX, a
// hugely popular REST client extension whose whole surface IS a webview). This is what a genuine view-bearing
// extension looks like in our right panel: an interactive request builder that actually sends + shows the
// response. A faithful representative — the real VSIX would render its own webview into the same panel.
const restClient = {
  id: 'rangav.vscode-thunder-client',
  displayName: 'Thunder Client',
  activate(vscode) {
    vscode.window.registerView('thunder-client.request', {
      title: 'Thunder Client', icon: 'data-transfer-both',
      render(container) {
        container.style.cssText = 'padding:12px;display:flex;flex-direction:column;gap:8px;font-family:var(--font-sans);height:100%'
        container.innerHTML = `
          <div style="display:flex;gap:6px">
            <select data-method style="background:var(--color-well);border:1px solid var(--color-line);border-radius:8px;color:var(--color-ink);font-size:12px;padding:0 6px">
              <option>GET</option><option>POST</option></select>
            <input data-url value="https://api.github.com/repos/vercel/next.js"
              style="flex:1;min-width:0;background:var(--color-well);border:1px solid var(--color-line);border-radius:8px;color:var(--color-ink);font-size:12px;padding:7px 9px;font-family:var(--font-mono)" />
          </div>
          <button data-send style="padding:8px;border:none;border-radius:8px;background:var(--color-bloom);color:var(--color-well);font-weight:600;font-size:12.5px;cursor:pointer">Send</button>
          <div data-status style="font-size:11px;font-family:var(--font-mono);color:var(--color-dim)"></div>
          <pre data-resp style="flex:1;min-height:0;overflow:auto;margin:0;background:var(--color-well);border:1px solid var(--color-line);border-radius:8px;padding:9px;font-family:var(--font-mono);font-size:11px;line-height:1.5;color:var(--color-ink);white-space:pre-wrap"></pre>`
        const $ = (s) => container.querySelector(s)
        $('[data-send]').addEventListener('click', async () => {
          const url = $('[data-url]').value, method = $('[data-method]').value
          $('[data-status]').textContent = 'sending…'; $('[data-resp]').textContent = ''
          try {
            const r = await fetch(url, { method })
            const j = await r.json().catch(() => null)
            $('[data-status]').textContent = `${method} → ${r.status} ${r.statusText}`
            $('[data-resp]').textContent = JSON.stringify(j, null, 2)?.slice(0, 4000) ?? '(no body)'
          } catch (e) { $('[data-status]').textContent = 'request failed: ' + (e?.message || e) }
        })
        return { dispose() { container.innerHTML = '' } }
      }
    })
  }
}

let bootstrapped = false
export function bootstrapExtensions() {
  if (bootstrapped) return
  bootstrapped = true
  activateExtension(workbooksSnippets)
  activateExtension(workbooksPanel)
  activateExtension(restClient)
}
