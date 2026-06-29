// The SECRETS seam — the demo half of Nexus.Secrets. A native CLI / MCP server never holds its own
// credential: the host injects it at invocation. Reactive ($state) so the app footer + Toolkits reflect
// connections live. NOTHING is persisted to source/disk; production reads ONLY through Nexus.Secrets.
const store = $state({ map: {} }) // ENV_NAME -> token

export const secrets = {
  set(env, value) { store.map = { ...store.map, [env]: value } },
  get(env) { return store.map[env] || null },
  has(env) { return !!store.map[env] },
  clear(env) { const m = { ...store.map }; delete m[env]; store.map = m },
  list() { return Object.keys(store.map) }
}
