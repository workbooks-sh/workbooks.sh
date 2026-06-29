// mcp.svelte.js — the MCP server store (replaces the old extensions store). An "MCP server" is a Model
// Context Protocol endpoint the nexus has installed: a remote HTTP server (just a URL) or a local npm
// package run as JS→WASM. Installed servers are CLOUD-SYNCED per nexus via /cloud/mcp; the browsable
// catalog (2,131 WASM-compatible servers) lazy-loads from mcp.generated.js only when the browser opens.
import { api } from './api.js'

export const mcpState = $state({ installed: [], catalog: null, loading: false })

// installed servers (cloud-synced). Called on boot + after any mutation.
export async function loadInstalled() {
  try { mcpState.installed = (await api.rt('/cloud/mcp')).servers || [] } catch (_) {}
}

// the catalog is 738KB → only pulled when the user opens the MCP browser
export async function loadCatalog() {
  if (mcpState.catalog) return mcpState.catalog
  mcpState.loading = true
  try { mcpState.catalog = (await import('./mcp.generated.js')).mcpCatalog }
  finally { mcpState.loading = false }
  return mcpState.catalog
}

export const isInstalled = (sid) => mcpState.installed.some((s) => s.sid === sid)
export const installedById = (sid) => mcpState.installed.find((s) => s.sid === sid)
export const enabledServers = () => mcpState.installed.filter((s) => s.enabled)

// install from a catalog entry OR a custom {sid|id, name, transport, url|endpoint}
export async function install(entry) {
  const r = await api.cloudPost('/cloud/mcp', {
    sid: entry.id || entry.sid,
    name: entry.name,
    transport: entry.transport || 'http',
    endpoint: entry.url || entry.endpoint || (entry.pkg ? entry.pkg.identifier : ''),
    args: entry.args || '',
    env: entry.env || '',
    source: entry.source || 'catalog',
    enabled: true
  })
  await loadInstalled()
  return r
}

export async function uninstall(sid) { const r = await api.cloudPost('/cloud/mcp/delete', { sid }); await loadInstalled(); return r }
export async function setEnabled(sid, enabled) { const r = await api.cloudPost('/cloud/mcp/toggle', { sid, enabled }); await loadInstalled(); return r }
