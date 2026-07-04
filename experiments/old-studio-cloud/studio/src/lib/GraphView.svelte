<script>
  // GraphView — an interactive Understand-Anything-style knowledge graph of the active workspace. Renders
  // the nexus's KnowledgeGraph (/cloud/graph: typed nodes + typed edges, structural now; LLM-enriched in
  // Phase 2) force-directed. Color by node TYPE, fuzzy search, click a node for its detail + neighbourhood.
  import { ui } from './data.svelte.js'
  import { auth } from './auth.svelte.js'
  import { api } from './api.js'
  import { nodeColor, LEGEND, edgeLabel, typeOfKind, edgeTypeOf } from './graph-model.js'
  import { forceSimulation, forceLink, forceManyBody, forceCenter, forceCollide } from 'd3-force'

  const W = 1280, H = 820
  let nodes = $state([])
  let rawEdges = $state([])
  let links = $state([])
  let view = $state({ x: 0, y: 0, k: 1 })
  let loading = $state(true)
  let error = $state(null)
  let q = $state('')
  let selected = $state(null)
  let domains = $state([])
  let layers = $state([])
  let tours = $state([])
  let impact = $state(null) // diff-impact: a Set of node ids in the blast radius of `selected`
  let tourI = $state(-1) // active tour index
  let tourStep = $state(0)
  let source = $state(null) // { name, text, loading } — the opened .work source
  let liveData = $state({}) // Phase C: resource name → { count, fields } live runtime state
  let granular = $state(false) // Phase A: expand declarations (fields/endpoints/functions) into nodes
  let runCounts = $state({}) // Phase C: agent name → recent run count (history)
  let visibility = $state(null) // Phase C: the workspace/surface visibility (public/draft/private)
  let changedActive = $state(false) // Phase E: pre-commit diff-impact highlight active
  let sim = null

  // semantic search — match name, summary, OR tags; the selected node's neighbourhood; color mode
  let mode = $state('type') // 'type' | 'domain'
  const DOMAIN_PALETTE = ['var(--color-sky)', 'var(--color-fuchsia)', 'var(--color-peach)', 'var(--color-mint)', 'var(--color-violet)', 'var(--color-amber)', 'var(--color-cream)', 'var(--color-bloomd)']
  const domainIndex = $derived(new Map((domains || []).map((d, i) => [d.id, i])))
  const layerIndex = $derived(new Map((layers || []).map((l, i) => [l.id, i])))
  const palOf = (idx) => DOMAIN_PALETTE[(idx ?? 0) % DOMAIN_PALETTE.length]
  const domainColor = (id) => palOf(domainIndex.get(id))
  const layerColor = (id) => palOf(layerIndex.get(id))
  const colorFor = (n) =>
    (mode === 'domain' && n.domain) ? domainColor(n.domain)
      : (mode === 'layer' && n.layer) ? layerColor(n.layer)
        : nodeColor(n.type)
  const modeOpts = $derived([['type', 'Type'], ...(domains.length ? [['domain', 'Domain']] : []), ...(layers.length ? [['layer', 'Layer']] : [])])

  const matched = $derived(q.trim() ? new Set(nodes.filter((n) => {
    const s = q.toLowerCase()
    return (n.name || n.id).toLowerCase().includes(s) || (n.summary || '').toLowerCase().includes(s) || (n.tags || []).some((t) => String(t || '').toLowerCase().includes(s))
  }).map((n) => n.id)) : null)
  const neighbours = $derived(selected ? new Set([selected.id, ...rawEdges.filter((e) => e.source === selected.id || e.target === selected.id).flatMap((e) => [e.source, e.target])]) : null)
  const selEdges = $derived(selected ? rawEdges.filter((e) => e.source === selected.id || e.target === selected.id) : [])
  const dim = (id) => (matched && !matched.has(id)) || (neighbours && !neighbours.has(id)) || (impact && !impact.has(id))

  // diff-impact: the transitive blast radius of a node (everything reachable via outgoing edges).
  function blastRadius(id) {
    const out = new Map()
    for (const e of rawEdges) { if (!out.has(e.source)) out.set(e.source, []); out.get(e.source).push(e.target) }
    const seen = new Set([id]); const stack = [id]
    while (stack.length) { const cur = stack.pop(); for (const t of (out.get(cur) || [])) if (!seen.has(t)) { seen.add(t); stack.push(t) } }
    return seen
  }
  function toggleImpact() { impact = impact ? null : (selected ? blastRadius(selected.id) : null) }

  // guided tours
  const tour = $derived(tourI >= 0 ? tours[tourI] : null)
  function startTour(i) { tourI = i; tourStep = 0; focusTourNode() }
  function tourGo(d) { if (!tour) return; tourStep = Math.max(0, Math.min((tour.nodeIds || []).length - 1, tourStep + d)); focusTourNode() }
  function endTour() { tourI = -1 }
  function focusTourNode() { const id = tour?.nodeIds?.[tourStep]; const n = nodes.find((x) => x.id === id); if (n) selected = n }

  // Phase E (actionable): open a node's real .work source
  async function openSource(n) {
    if (!n?.path) return
    source = { name: n.name || n.id, text: '', loading: true }
    try {
      const raw = await api.rt('/cloud/raw?path=' + encodeURIComponent(n.path))
      source = { name: n.name || n.id, text: typeof raw === 'string' ? raw : JSON.stringify(raw, null, 2), loading: false }
    } catch (e) {
      source = { name: n.name || n.id, text: 'Could not open — ' + (e?.message || ''), loading: false }
    }
  }

  // Phase E: run an agent / explain a node via the Graph agent — stream the result into the panel
  async function runAgentTask(agentName, task, title) {
    source = { name: title, text: '', loading: true }
    try {
      const r = await api.rt('/cloud/agent/run', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ agent: agentName, task, workspace: ui.workspace || 'cloud' }) })
      source = { name: title, text: (r?.reply || r?.result || r?.text || (typeof r === 'string' ? r : JSON.stringify(r, null, 2))), loading: false }
    } catch (e) {
      source = { name: title, text: 'Failed — ' + (e?.message || ''), loading: false }
    }
  }
  const explainNode = (n) => runAgentTask('graph', `Explain the "${n.id}" ${n.kind || 'unit'} in the ${ui.workspace || 'cloud'} workspace — what it does, what it depends on, and its blast radius. Cite node ids.`, 'Explain: ' + (n.name || n.id))
  const runNode = (n) => runAgentTask(n.id, 'Run.', 'Run: ' + (n.name || n.id))
  function setGranular(v) { granular = v; load() }

  // Phase E: inspect a data node's real rows
  async function inspectData(n) {
    source = { name: (n.name || n.id) + ' — rows', text: '', loading: true }
    try {
      const d = await api.rt('/cloud/data/rows?limit=25&name=' + encodeURIComponent(n.id))
      const cols = (d.fields || []).map((f) => f.name || f.field || f)
      const rows = (d.rows || []).map((row) => cols.map((c) => { const v = row[c]; return v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v) }).join('  |  '))
      source = { name: (n.name || n.id) + ' — ' + (d.total ?? rows.length) + ' rows', text: [cols.join('  |  '), cols.map(() => '———').join('  |  '), ...rows].join('\n'), loading: false }
    } catch (e) {
      source = { name: n.name || n.id, text: 'Could not load rows — ' + (e?.message || ''), loading: false }
    }
  }

  // Phase E: pre-commit diff-impact — highlight the blast radius of currently-changed files
  async function showChanged() {
    if (changedActive) { changedActive = false; impact = null; return }
    try {
      const r = await api.rt('/cloud/graph/changed?ws=' + encodeURIComponent(ui.workspace || 'cloud'))
      const changed = new Set(r.changed || [])
      const hit = nodes.filter((n) => n.path && changed.has(n.path))
      if (!hit.length) { error = 'No graph nodes in the changed files.'; setTimeout(() => (error = null), 2500); return }
      const set = new Set()
      for (const n of hit) for (const id of blastRadius(n.id)) set.add(id)
      impact = set; changedActive = true; selected = null
    } catch (_) {}
  }

  async function load() {
    loading = true; error = null; selected = null
    const ws = ui.workspace || 'cloud'
    try {
      // The graph is the PARSED .work structure (graph.ex facets + literate parse) — NO LLM enrichment.
      // The .work files already carry the semantics; we surface them, not guess them.
      let g = null
      if (auth.offline) {
        g = demoGraph()
      } else {
        try { const r = await api.rt('/cloud/graph/rich?ws=' + encodeURIComponent(ws)); if (r && r.nodes) g = r } catch (_) {}
        if (!g) g = await api.rt('/' + encodeURIComponent(ws) + '/graph') // last-resort: runtime summary
      }
      layers = []; tours = []
      impact = null; tourI = -1
      const ns = (g.nodes || []).map((n) => ({
        id: n.id, name: n.name || n.id, kind: n.kind, lang: n.lang,
        type: n.type || typeOfKind(n.kind), filePath: n.filePath || n.file,
        tags: n.tags || [n.kind, n.lang].filter(Boolean), summary: n.summary || '', domain: n.domain, layer: n.layer,
        exports: n.exports || [], imports: n.imports || [], types: n.types || [], calls: n.calls || [],
        members: n.members || [], observed: n.observed, path: n.path, deps: n.deps
      }))
      visibility = g.visibility || null
      // domains derived by PARSING the .work tree — group each unit by the folder it lives in (its area of
      // the workspace); root-level files group by kind. No LLM.
      const domMap = {}
      for (const n of ns) {
        const segs = (n.path || '').split('/').filter(Boolean)
        const dom = segs.length > 2 ? segs[1] : (n.kind || 'root')
        n.domain = dom
        ;(domMap[dom] ||= []).push(n.id)
      }
      domains = Object.entries(domMap).filter(([, ids]) => ids.length > 1).map(([id, nodeIds]) => ({ id, name: id, nodeIds }))
      rawEdges = (g.edges || []).map((e) => ({
        source: e.source || e.from, target: e.target || e.to,
        type: e.type ? edgeTypeOf(e.type) : 'depends_on', layer: e.layer, semantic: !!e.semantic, why: e.why
      }))

      // Phase C: hydrate data nodes with live runtime state (fetch first so data-flow + granular can use it)
      liveData = {}
      if (!auth.offline) {
        try {
          const dd = await api.rt('/cloud/data')
          for (const r of (dd.resources || [])) {
            if (r.name && (!ws || !r.workspace || r.workspace === ws)) liveData[r.name] = { count: r.count, fields: r.fields || [] }
          }
        } catch (_) {}
        // Phase C: agent run history — recent runs per agent
        runCounts = {}
        try {
          const ss = await api.rt('/cloud/agent/sessions')
          for (const s of (ss.sessions || [])) if (s.agent) runCounts[s.agent] = (runCounts[s.agent] || 0) + 1
        } catch (_) {}
      }

      // Phase C: data-flow edges — relabel edges whose target is a data node as reads_from / writes_to
      const kindOf = new Map(ns.map((n) => [n.id, n.kind]))
      const isData = (id) => kindOf.get(id) === 'resource' || kindOf.get(id) === 'database'
      for (const e of rawEdges) {
        if (!e.semantic && isData(e.target)) e.type = (e.type === 'writes_to' ? 'writes_to' : 'reads_from')
      }

      // Phase A: fine-grained — expand each unit's declarations (fields / exports) into child nodes
      if (granular) {
        const memColor = { tool: 'config', grant: 'config', endpoint: 'endpoint', field: 'field', step: 'step', function: 'function', class: 'class' }
        const extra = []
        for (const n of ns.slice()) {
          // prefer the block's real members (routes/fields/tools/grants/steps); else fall back to live fields / exports
          let decls = (n.members || []).map((m) => ({ label: m.label, t: m.type }))
          if (!decls.length) {
            const fields = (liveData[n.id]?.fields || []).map((f) => ({ label: f.name || f.field || f, t: 'field' }))
            const exps = (n.exports || []).slice(0, 6).map((x) => ({ label: String(x), t: n.kind === 'server' ? 'endpoint' : 'function' }))
            decls = [...fields, ...exps]
          }
          for (const d of decls.slice(0, 10)) {
            const cid = n.id + '::' + d.label
            extra.push({ id: cid, name: d.label, kind: d.t, type: memColor[d.t] || d.t, parent: n.id, tags: [d.t] })
            rawEdges.push({ source: n.id, target: cid, type: 'contains' })
          }
        }
        ns.push(...extra)
      }

      const ids = new Set(ns.map((n) => n.id))
      const ls = rawEdges.filter((e) => ids.has(e.source) && ids.has(e.target)).map((e) => ({ source: e.source, target: e.target, semantic: e.semantic }))
      run(ns, ls)
    } catch (e) {
      error = e?.message || 'failed'; loading = false
    }
  }

  function run(ns, ls) {
    if (sim) sim.stop()
    sim = forceSimulation(ns)
      .force('link', forceLink(ls).id((d) => d.id).distance((l) => (l.semantic ? 70 : 42)).strength(0.62))
      .force('charge', forceManyBody().strength(-140).distanceMax(360))
      .force('center', forceCenter(W / 2, H / 2))
      .force('collide', forceCollide(15))
      .on('tick', () => {
        nodes = ns.map((n) => ({ ...n }))
        links = ls.map((l) => ({ x1: l.source.x, y1: l.source.y, x2: l.target.x, y2: l.target.y, s: l.source.id, t: l.target.id, semantic: l.semantic }))
      })
    nodes = ns; links = []; loading = false
  }

  $effect(() => { ui.workspace; load() })

  // pan + zoom
  let dragging = false, last = null
  let svgEl
  // map a mouse event → the SVG's user (viewBox) coordinates, honoring size + preserveAspectRatio
  function svgPoint(e) {
    const pt = svgEl.createSVGPoint(); pt.x = e.clientX; pt.y = e.clientY
    return pt.matrixTransform(svgEl.getScreenCTM().inverse())
  }
  // zoom TOWARD the cursor, smoothly (scale ∝ scroll delta), keeping the point under the pointer fixed
  function onwheel(e) {
    e.preventDefault()
    if (!svgEl) return
    const p = svgPoint(e)
    const k2 = Math.max(0.15, Math.min(5, view.k * Math.exp(-e.deltaY * 0.0012)))
    const gx = (p.x - view.x) / view.k, gy = (p.y - view.y) / view.k
    view = { x: p.x - gx * k2, y: p.y - gy * k2, k: k2 }
  }
  function ondown(e) { if (!svgEl) return; dragging = true; last = svgPoint(e) }
  function onmove(e) { if (!dragging || !last || !svgEl) return; const p = svgPoint(e); view = { ...view, x: view.x + (p.x - last.x), y: view.y + (p.y - last.y) }; last = p }
  function onup() { dragging = false; last = null }

  function demoGraph() {
    return { nodes: [
      { id: 'research', name: 'Research agent', type: 'service', filePath: 'agents/research.work', lang: 'work', tags: ['agent'] },
      { id: 'pipeline', name: 'research pipeline', type: 'pipeline', tags: ['flow'] },
      { id: 'notes', name: 'notes', type: 'table', tags: ['database'] },
      { id: 'dash', name: 'Dashboard', type: 'module', tags: ['app'] }
    ], edges: [
      { source: 'research', target: 'pipeline', type: 'calls' }, { source: 'pipeline', target: 'notes', type: 'writes_to' },
      { source: 'dash', target: 'notes', type: 'reads_from' }
    ] }
  }
</script>

<div class="h-full w-full relative overflow-hidden" style="background:var(--color-paper)">
  <!-- top bar: title + search -->
  <div class="absolute top-3 left-5 right-5 z-10 flex items-center gap-3 select-none">
    <span class="font-display font-semibold text-[15px]">Graph</span>
    <span class="text-dim text-[12.5px]">{nodes.length} nodes · {ui.workspace || 'cloud'}</span>
    {#if visibility}<span class="text-[10px] px-1.5 py-0.5 rounded-md" style="background:color-mix(in srgb,var(--color-sky) 16%,transparent);color:var(--color-sky)" title="Surface visibility">{visibility}</span>{/if}
    <span class="flex-1"></span>
    {#if modeOpts.length > 1}
      <div class="flex rounded-md border border-line overflow-hidden text-[11px]">
        {#each modeOpts as [m, lbl]}
          <button onclick={() => (mode = m)} class="px-2 py-1 {mode === m ? 'text-ink bg-card' : 'text-dim hover:text-ink'}">{lbl}</button>
        {/each}
      </div>
    {/if}
    <button onclick={() => setGranular(!granular)} title="Expand declarations (fields, endpoints, functions) into nodes"
      class="text-[11.5px] px-2.5 py-1 rounded-md border border-line hover:bg-card {granular ? 'text-ink bg-card' : 'text-dim'}">{granular ? 'Granular ✓' : 'Granular'}</button>
    <button onclick={showChanged} title="Highlight the blast radius of currently-changed files (pre-commit diff-impact)"
      class="text-[11.5px] px-2.5 py-1 rounded-md border border-line hover:bg-card {changedActive ? 'text-ink bg-card' : 'text-dim'}">Changed</button>
    {#if tours.length}<button onclick={() => startTour(0)} class="text-[11.5px] px-2.5 py-1 rounded-md border border-line text-ink hover:bg-card">Tour</button>{/if}
    <input bind:value={q} placeholder="Search nodes…"
      class="w-[200px] bg-card border border-line rounded-lg px-3 py-1.5 text-[12.5px] outline-none focus:border-ink" />
  </div>
  <!-- legend -->
  <div class="absolute bottom-3 left-5 z-10 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-dim select-none max-w-[60%]">
    {#if mode === 'domain' && domains.length}
      {#each domains as d}<span class="flex items-center gap-1.5"><span class="w-[8px] h-[8px] rounded-full" style="background:{domainColor(d.id)}"></span>{d.name || d.id}</span>{/each}
    {:else}
      {#each LEGEND as [t, lbl]}<span class="flex items-center gap-1.5"><span class="w-[8px] h-[8px] rounded-full" style="background:{nodeColor(t)}"></span>{lbl}</span>{/each}
    {/if}
  </div>

  <!-- guided tour stepper -->
  {#if tour}
    <div class="absolute bottom-3 left-1/2 -translate-x-1/2 z-20 flex items-center gap-3 rounded-xl border border-line px-3.5 py-2" style="background:var(--color-card);box-shadow:0 14px 36px rgba(0,0,0,.3)">
      <span class="text-[12.5px] font-medium text-ink">{tour.title || 'Tour'}</span>
      <span class="text-dim text-[11.5px]">{tourStep + 1}/{(tour.nodeIds || []).length}</span>
      <button onclick={() => tourGo(-1)} class="text-dim hover:text-ink text-[15px] px-1">‹</button>
      <button onclick={() => tourGo(1)} class="text-dim hover:text-ink text-[15px] px-1">›</button>
      <button onclick={endTour} class="text-dim hover:text-ink text-[12px] px-1">✕</button>
    </div>
  {/if}

  {#if loading}<div class="absolute inset-0 grid place-items-center text-dim/70 text-[13px]">Building graph…</div>{/if}
  {#if error}<div class="absolute inset-0 grid place-items-center text-[13px]" style="color:var(--color-bad)">Couldn’t build the graph — {error}</div>{/if}

  <svg bind:this={svgEl} class="w-full h-full {dragging ? 'cursor-grabbing' : 'cursor-grab'}" viewBox="0 0 {W} {H}"
    onwheel={onwheel} onmousedown={ondown} onmousemove={onmove} onmouseup={onup} onmouseleave={onup} role="presentation">
    <g transform="translate({view.x},{view.y}) scale({view.k})">
      {#each links as l}
        <line x1={l.x1} y1={l.y1} x2={l.x2} y2={l.y2}
          stroke={l.semantic ? 'var(--color-violet)' : 'var(--color-line)'} stroke-width={l.semantic ? 1.2 : 1}
          stroke-dasharray={l.semantic ? '4 3' : ''}
          opacity={(dim(l.s) && dim(l.t)) ? 0.12 : (l.semantic ? 0.5 : 0.6)} />
      {/each}
      {#each nodes as n}
        <g transform="translate({n.x || 0},{n.y || 0})" opacity={dim(n.id) ? 0.2 : 1} style="cursor:pointer"
          onclick={(e) => { e.stopPropagation(); selected = n }} role="presentation">
          <circle r={selected?.id === n.id ? 9 : 7} fill={colorFor(n)} stroke="var(--color-paper)" stroke-width="1.5" />
          <text x="11" y="4" font-size="11" fill="var(--color-ink)" style="pointer-events:none">{n.name || n.id}</text>
        </g>
      {/each}
    </g>
  </svg>

  <!-- node detail -->
  {#if selected}
    <div class="absolute top-12 right-5 z-20 w-[280px] max-h-[calc(100vh-80px)] overflow-y-auto rounded-xl border border-line p-3.5" style="background:var(--color-card);box-shadow:0 14px 36px rgba(0,0,0,.3)">
      <div class="flex items-center gap-2 mb-1">
        <span class="w-[10px] h-[10px] rounded-full" style="background:{colorFor(selected)}"></span>
        <span class="text-[13.5px] font-medium text-ink truncate flex-1">{selected.name || selected.id}</span>
        <button onclick={toggleImpact} title="Blast radius — everything this depends on"
          class="text-[10px] px-1.5 py-0.5 rounded {impact ? 'text-ink bg-card border border-line' : 'text-dim hover:text-ink'}">Impact</button>
        <button onclick={() => { selected = null; impact = null }} class="text-dim hover:text-ink text-[14px]">✕</button>
      </div>
      <div class="text-[11px] font-mono uppercase tracking-wider text-dim mb-2">{selected.type}{#if selected.lang} · {selected.lang}{/if}{#if selected.domain} · {selected.domain}{/if}</div>
      {#if selected.kind === 'agent' && runCounts[selected.id]}<div class="text-[11px] text-dim mb-2">⟳ {runCounts[selected.id]} recent run{runCounts[selected.id] === 1 ? '' : 's'}</div>{/if}
      <!-- Phase C: observed runtime traffic — what actually ran (telemetry overlay) -->
      {#if selected.observed && selected.observed.runs}
        <div class="mb-2 rounded-lg border border-line p-2" style="background:color-mix(in srgb,var(--color-peach) 8%,transparent)">
          <div class="flex items-center gap-1.5 text-[11.5px] text-ink mb-0.5"><span class="w-[6px] h-[6px] rounded-full" style="background:var(--color-peach)"></span><span class="font-medium">{selected.observed.runs} runs</span><span class="text-dim/70 text-[10px]">observed traffic</span></div>
          <div class="text-[10.5px] text-dim flex flex-wrap gap-x-2.5">{#if selected.observed.tokens}<span>{selected.observed.tokens} tok</span>{/if}{#if selected.observed.latency_ms}<span>{selected.observed.latency_ms}ms avg</span>{/if}{#if selected.observed.errors}<span style="color:var(--color-bad)">{selected.observed.errors} err</span>{/if}</div>
        </div>
      {/if}
      {#if selected.summary}<div class="text-[12.5px] text-dim mb-2 leading-relaxed">{selected.summary}</div>{/if}
      {#if selected.filePath}<div class="text-[11px] font-mono text-dim/80 truncate mb-1.5">{selected.filePath}</div>{/if}
      <div class="flex gap-1.5 mb-2">
        {#if selected.path}<button onclick={() => openSource(selected)} class="flex-1 text-[11px] px-2 py-1 rounded-md border border-line text-ink hover:bg-paper">Open</button>{/if}
        <button onclick={() => explainNode(selected)} class="flex-1 text-[11px] px-2 py-1 rounded-md border border-line text-ink hover:bg-paper">Explain</button>
        {#if selected.kind === 'agent'}<button onclick={() => runNode(selected)} class="flex-1 text-[11px] px-2 py-1 rounded-md border border-line text-ink hover:bg-paper">Run</button>{/if}
        {#if liveData[selected.id]}<button onclick={() => inspectData(selected)} class="flex-1 text-[11px] px-2 py-1 rounded-md border border-line text-ink hover:bg-paper">Inspect</button>{/if}
      </div>
      <!-- Phase C: live runtime state — real rows + schema for data nodes -->
      {#if liveData[selected.id]}
        <div class="mb-2 rounded-lg border border-line p-2" style="background:color-mix(in srgb,var(--color-mint) 8%,transparent)">
          <div class="flex items-center gap-1.5 text-[11.5px] text-ink mb-1">
            <span class="w-[6px] h-[6px] rounded-full" style="background:var(--color-mint)"></span>
            <span class="font-medium">{liveData[selected.id].count ?? 0} rows</span><span class="text-dim/70 text-[10px]">live</span>
          </div>
          {#if liveData[selected.id].fields?.length}
            <div class="flex flex-wrap gap-1">{#each liveData[selected.id].fields.slice(0, 10) as f}<span class="text-[10px] font-mono px-1 py-0.5 rounded bg-paper text-dim">{f.name || f.field || f}{#if f.type}<span class="text-dim/50">:{f.type}</span>{/if}</span>{/each}</div>
          {/if}
        </div>
      {/if}
      <!-- the real declarations this unit carries (the actual content, from graph.ex facets) -->
      {#each [['Exports', selected.exports], ['Calls', selected.calls], ['Types', selected.types], ['Imports', selected.imports]] as [lbl, vals]}
        {#if vals?.length}
          <div class="mb-1.5">
            <span class="text-[10px] uppercase tracking-wider text-dim/70">{lbl}</span>
            <div class="flex flex-wrap gap-1 mt-0.5">
              {#each vals.slice(0, 12) as v}<span class="text-[10.5px] font-mono px-1.5 py-0.5 rounded bg-paper border border-line text-dim truncate max-w-[24ch]">{v}</span>{/each}
              {#if vals.length > 12}<span class="text-[10px] text-dim/60 self-center">+{vals.length - 12}</span>{/if}
            </div>
          </div>
        {/if}
      {/each}
      <!-- Phase A: the unit's real members — routes/fields/tools/grants/steps parsed from its block -->
      {#if selected.members?.length}
        <div class="mb-1.5">
          <span class="text-[10px] uppercase tracking-wider text-dim/70">Members</span>
          <div class="flex flex-wrap gap-1 mt-0.5">{#each selected.members.slice(0, 14) as m}<span class="text-[10.5px] font-mono px-1.5 py-0.5 rounded bg-paper border border-line text-dim truncate max-w-[26ch]">{m.label}<span class="text-dim/50"> · {m.type}</span></span>{/each}</div>
        </div>
      {/if}
      {#if selEdges.length}
        <div class="text-[10px] uppercase tracking-wider text-dim/70 mt-2 mb-1">Links ({selEdges.length})</div>
        <div class="flex flex-col gap-1">
          {#each selEdges as e}
            <button onclick={() => (selected = nodes.find((n) => n.id === (e.source === selected.id ? e.target : e.source)) || selected)}
              class="text-left text-[12px] leading-snug px-1.5 py-1.5 rounded-md hoverwash text-ink truncate">
              <span class="text-dim/70">{e.source === selected.id ? edgeLabel(e.type) + ' →' : '← ' + edgeLabel(e.type)}</span>
              {e.source === selected.id ? e.target : e.source}
            </button>
          {/each}
        </div>
      {/if}
    </div>
  {/if}

  <!-- source viewer (Phase E: drill into the real .work content) -->
  {#if source}
    <div class="absolute inset-0 z-30 flex" style="background:rgba(0,0,0,.4)" onclick={() => (source = null)} role="presentation">
      <div class="ml-auto h-full w-[52%] max-w-[760px] flex flex-col border-l border-line" style="background:var(--color-card)" onclick={(e) => e.stopPropagation()} role="presentation">
        <div class="flex items-center gap-2 px-4 py-2.5 border-b border-line">
          <span class="text-[13px] font-medium text-ink truncate flex-1">{source.name}</span>
          <button onclick={() => (source = null)} class="text-dim hover:text-ink text-[14px]">✕</button>
        </div>
        {#if source.loading}
          <div class="flex-1 grid place-items-center text-dim/70 text-[13px]">Loading…</div>
        {:else}
          <pre class="flex-1 overflow-auto m-0 p-4 text-[12px] leading-relaxed font-mono text-ink whitespace-pre-wrap">{source.text}</pre>
        {/if}
      </div>
    </div>
  {/if}
</div>
