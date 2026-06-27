// The DOCK — the single host capability surface the whole Code workbench talks to (the `invoke`/Dock seam
// from platform canon). The UI only ever calls `dock.fs.* / shell.* / lang.* / vcs.* / ext.*`; a PROVIDER
// fulfills each call. Today: `local` (browser, mock tree). Later: `runtime` (RCP/WS to
// the nexus — fs→WASHIE, shell→Nexus.Shell wasm, lang→a wasm LSP server) — selected by config, no UI change.
//
// This same surface is ALSO the target of the `vscode` API shim for emulated VSIX extensions:
//   vscode.workspace.fs → dock.fs · window.createTerminal → dock.shell · languages.* → dock.lang · etc.
// So the dock is both "our API" and the VS-Code-compat layer (see registry/ide-workbench.work).
import { local } from './local.js'

const providers = { local /* , runtime: … (RCP) — drops in here */ }
let active = providers.local

export function useProvider(name) { if (providers[name]) active = providers[name] }
export const providerName = () => active.name

// thin delegating facade so call sites never hold a provider reference directly
const ns = (group) => new Proxy({}, { get: (_t, m) => (...args) => active[group][m](...args) })
export const dock = {
  fs: ns('fs'), shell: ns('shell'), lang: ns('lang'), vcs: ns('vcs'), ext: ns('ext'),
  cli: ns('cli'), nativecli: ns('nativecli'), secrets: ns('secrets')
}
// dock.ext exposes the marketplace + license confirmation; the shared extensions store (extensions.svelte.js)
// is the registry both the Code panel and the Toolkits Extensions layer read.
