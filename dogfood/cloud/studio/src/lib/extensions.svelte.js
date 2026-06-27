// The shared EXTENSIONS registry — one source of truth for VSX extensions added as toolkit capabilities,
// consumed by BOTH the Code workbench panel and the Toolkits "Extensions" layer (and, via the Dock, by agents
// and app surfaces later). An extension is a 4th toolkit kind: a VSIX (untrusted JS) compiled to wasm and run
// against the `vscode` shim mapped onto the Dock, so whatever it contributes (commands, providers) is a Dock
// capability — not editor-only. LICENSE is gating metadata: we confirm it (Open VSX detail endpoint) before an
// extension can be enabled as a shared capability, because WE redistribute/compile it (vs a user installing
// into their own editor). built-in extensions (ext-host) are pre-added + permissive.
import { activeExtensions, setExtEnabled, bootstrapExtensions } from './dock/ext-host.js'

bootstrapExtensions() // ensure built-in extensions are activated before we seed from them (idempotent)

// id -> { id, displayName, namespace, name, version, license, source: 'builtin'|'openvsx', enabled }
const store = $state({ map: {} })

// licenses we accept for redistribution as a shared capability (permissive). Others need review.
const OK_LICENSES = ['MIT', 'Apache-2.0', 'Apache 2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', '0BSD', 'MPL-2.0', 'Unlicense', 'CC0-1.0']
export function licenseOk(lic) { return !!lic && OK_LICENSES.some((l) => l.toLowerCase() === String(lic).toLowerCase()) }
export function licenseStatus(lic) {
  if (!lic) return { tone: 'dim', label: 'license?', ok: false, note: 'license not confirmed — fetch detail before enabling' }
  if (licenseOk(lic)) return { tone: 'bloomd', label: lic, ok: true, note: 'permissive — OK to ship as a shared capability' }
  return { tone: 'amber', label: lic, ok: false, note: 'needs review before redistribution' }
}

// seed built-ins from the ext-host (already active against the vscode shim)
for (const e of activeExtensions) {
  store.map[e.id] = { id: e.id, displayName: e.displayName, namespace: e.id.split('.')[0], name: e.id.split('.').pop(), version: 'built-in', license: 'MIT', source: 'builtin', enabled: true }
}

export const extensions = {
  all() { return Object.values(store.map) },
  added(id) { return !!store.map[id] },
  get(id) { return store.map[id] || null },
  // add an Open VSX extension as a shared capability — license must be confirmed + acceptable
  add(ext) {
    const id = ext.namespace + '.' + ext.name
    const enabled = licenseOk(ext.license)
    store.map[id] = { id, displayName: ext.displayName || ext.name, namespace: ext.namespace, name: ext.name, version: ext.version, license: ext.license || null, source: 'openvsx', enabled }
    return store.map[id]
  },
  remove(id) { const m = { ...store.map }; delete m[id]; store.map = m },
  setEnabled(id, on) {
    const e = store.map[id]; if (!e) return
    if (on && !licenseOk(e.license)) return // gate: can't enable an unconfirmed/non-permissive license
    e.enabled = on
    if (e.source === 'builtin') setExtEnabled(id, on) // built-ins also drive the live ext-host registry
  },
  count() { return Object.keys(store.map).length },
  enabledCount() { return Object.values(store.map).filter((e) => e.enabled).length }
}
export const extState = store
