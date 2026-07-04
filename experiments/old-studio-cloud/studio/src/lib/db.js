// db.js — real data volumes for a database surface. /cloud/data lists the tenant's resources (typed
// tables → SQLite); /cloud/data/rows?name=X returns { fields, rows }. We map them into the table shape
// DatabaseView already renders ({ name, cols, rows }). Correlated by workspace (a refinement later keys
// on the declaring .work file). Offline → null, so the surface keeps its mock payload tables.
import { api } from './api.js'

export async function loadTables(workspace) {
  let resources = []
  try {
    const r = await api.rt('/cloud/data')
    resources = (r.resources || []).filter((x) => !workspace || x.workspace === workspace)
  } catch (_) {
    return null
  }
  if (!resources.length) return []
  return Promise.all(resources.map(async (res) => {
    try {
      const d = await api.rt('/cloud/data/rows?limit=100&name=' + encodeURIComponent(res.name))
      const cols = (d.fields || []).map((f) => f.name || f.field || f)
      const rows = (d.rows || []).map((row) => cols.map((c) => {
        const v = row[c]
        return v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v)
      }))
      return { name: res.name, cols, rows, total: d.total }
    } catch (_) {
      return { name: res.name, cols: [], rows: [] }
    }
  }))
}
