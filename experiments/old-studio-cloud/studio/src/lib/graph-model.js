// graph-model.js — the Understand-Anything KnowledgeGraph vocabulary (ported from
// vendor/understand-anything/core/types.ts) that the Graph surface speaks: node types, edge types, and the
// color/label maps the GraphView (and, in Phase 2, the LLM pipeline) use. The nexus emits this shape from
// /cloud/graph (structural now; LLM-enriched later).

// UA NodeType → accent color
export const NODE_COLOR = {
  service: 'var(--color-fuchsia)', module: 'var(--color-sky)', endpoint: 'var(--color-sky)',
  function: 'var(--color-ink)', class: 'var(--color-violet)', file: 'var(--color-ink)', field: 'var(--color-mint)',
  pipeline: 'var(--color-peach)', flow: 'var(--color-peach)', step: 'var(--color-peach)',
  table: 'var(--color-mint)', schema: 'var(--color-mint)', resource: 'var(--color-mint)',
  config: 'var(--color-dim)', document: 'var(--color-cream)', concept: 'var(--color-amber)',
  domain: 'var(--color-amber)', topic: 'var(--color-amber)', entity: 'var(--color-violet)',
  module_dep: 'var(--color-dim)'
}
export const nodeColor = (t) => NODE_COLOR[t] || 'var(--color-ink)'

// the legend the dashboard shows
export const LEGEND = [
  ['service', 'Service / Agent'], ['module', 'Module / App'], ['pipeline', 'Flow'],
  ['table', 'Data'], ['function', 'Function'], ['concept', 'Concept']
]

// EdgeType → human label (35 types in UA; these are the ones the structural pass emits today)
export const EDGE_LABEL = {
  calls: 'calls', imports: 'imports', exports: 'exports', contains: 'contains',
  reads_from: 'reads', writes_to: 'writes', depends_on: 'depends on', tested_by: 'tested by',
  related: 'related', similar_to: 'similar', documents: 'documents', triggers: 'triggers'
}
export const edgeLabel = (t) => EDGE_LABEL[t] || t || 'links'

// The nexus runtime serves a structural graph at /<mount>/graph (server.ex mount_graph → graph_summary):
//   nodes: { id, file, kind, deps, lang, observed }   edges: { from, to, type, layer }
// Map .work kind → UA NodeType and the structural edge atom → UA EdgeType, client-side (the LLM pipeline
// will emit the rich shape directly in Phase 2).
export const KIND_TO_TYPE = {
  agent: 'service', server: 'service', app: 'module', client: 'module', dep: 'module',
  flow: 'pipeline', worker: 'pipeline', resource: 'table', database: 'table', def: 'function'
}
export const typeOfKind = (k) => KIND_TO_TYPE[k] || k || 'module'

export const EDGE_OF = {
  calls: 'calls', imports: 'imports', import: 'imports', fetch: 'reads_from', ref: 'related',
  dep: 'depends_on', compose: 'contains', style: 'related'
}
export const edgeTypeOf = (t) => EDGE_OF[t] || t || 'depends_on'
