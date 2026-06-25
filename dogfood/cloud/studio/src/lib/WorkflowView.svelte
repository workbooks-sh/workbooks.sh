<script>
  import { SvelteFlow, Background, Controls, MarkerType } from '@xyflow/svelte'
  import '@xyflow/svelte/dist/style.css'
  import ELK from 'elkjs/lib/elk.bundled.js'
  import { ui, surfaceById } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'
  import PromptNode from './PromptNode.svelte'

  let { surfaceId } = $props()
  const s = $derived(surfaceById(surfaceId))
  const elk = new ELK()
  const nodeTypes = { prompt: PromptNode }

  // ── the model: a flow built from prompts, not a node palette ──────────────────────────────────
  let mid = 0
  const node = (kind, prompt, status = 'generated') => ({ id: `n${++mid}`, kind, prompt, status })

  function seed(surf) {
    mid = 0
    const trigger = node('trigger', surf?.name === 'deploy-check' ? 'When a deploy is requested' : 'When this workflow is triggered')
    if (surf?.name === 'deploy-check') {
      const cond = node('condition', 'If the weave reports capability violations')
      cond.then = [node('step', 'Block the deploy and post the violations to #system')]
      cond.else = [node('step', 'Run check, then verify against the artifact')]
      return { trigger, items: [node('step', 'Weave the workbook tree into one shippable artifact'), cond, node('step', 'Mark the deploy ready and notify the requester')] }
    }
    return { trigger, items: (surf?.payload?.steps || ['Do something']).map((t) => node('step', t)) }
  }

  let model = $state(seed(s))
  let dirty = $state(false)
  let regenerating = $state(false)
  let nodes = $state.raw([])
  let edges = $state.raw([])

  const onTouch = () => { dirty = true }

  // model → Svelte Flow graph (nodes + edges), then ELK lays it out top-to-bottom
  function buildGraph() {
    const ns = [], es = []
    // node renders auto-height (so the bottom port sits on the real card edge); ELK gets an ESTIMATE
    const estH = (it) => it.kind === 'trigger' ? 62
      : 50 + Math.max(2, Math.ceil((it.prompt || '').length / 34)) * 18
    const mk = (it, label, extra = {}) => { const n = { id: it.id, type: 'prompt', position: { x: 0, y: 0 },
      data: { item: it, label, onTouch, regenerating, ...extra }, draggable: false,
      width: 280, _h: estH(it) }; ns.push(n); return n }
    const edge = (src, tgt, opts = {}) => es.push({ id: `${src}-${opts.sourceHandle || ''}-${tgt}-${opts.targetHandle || ''}`,
      source: src, target: tgt, type: 'smoothstep',
      markerEnd: { type: MarkerType.ArrowClosed, width: 20, height: 20, color: 'var(--color-dim)' },
      style: 'stroke:var(--color-dim);stroke-width:1.5', ...opts })

    mk(model.trigger, 'Trigger')
    let prev = [{ id: model.trigger.id }]
    model.items.forEach((it, i) => {
      const merge = prev.length === 2
      mk(it, it.kind === 'condition' ? 'Condition' : `Step ${i + 1}`, merge ? { merge: true } : {})
      const inH = ['in', 'in2']
      prev.forEach((p, k) => edge(p.id, it.id, {
        ...(p.sourceHandle ? { sourceHandle: p.sourceHandle } : {}),
        ...(merge ? { targetHandle: inH[k] } : {}) }))
      if (it.kind === 'condition') {
        const chain = (branch, handle, label, color) => {
          let p = { id: it.id, sourceHandle: handle }
          branch.forEach((bn, j) => {
            mk(bn, label)
            edge(p.id, bn.id, { ...(p.sourceHandle ? { sourceHandle: p.sourceHandle } : {}), ...(j === 0 ? { label, labelStyle: `fill:${color}` } : {}) })
            p = { id: bn.id }
          })
          return p
        }
        const tEnd = chain(it.then || [], 'then', 'true', 'var(--color-mint)')
        const eEnd = chain(it.else || [], 'else', 'false', 'var(--color-peach)')
        prev = [tEnd, eEnd]
      } else {
        prev = [{ id: it.id }]
      }
    })
    return { ns, es }
  }

  async function layout() {
    const { ns, es } = buildGraph()
    const g = {
      id: 'root',
      layoutOptions: {
        'elk.algorithm': 'layered', 'elk.direction': 'DOWN',
        'elk.layered.spacing.nodeNodeBetweenLayers': '78', 'elk.spacing.nodeNode': '90',
        'elk.spacing.edgeEdge': '24', 'elk.spacing.edgeNode': '24',
        'elk.layered.spacing.edgeEdgeBetweenLayers': '18', 'elk.layered.spacing.edgeNodeBetweenLayers': '24',
        'elk.layered.nodePlacement.strategy': 'NETWORK_SIMPLEX'
      },
      children: ns.map((n) => ({ id: n.id, width: n.width, height: n._h })),
      edges: es.map((e) => ({ id: e.id, sources: [e.source], targets: [e.target] }))
    }
    const res = await elk.layout(g)
    const pos = Object.fromEntries(res.children.map((c) => [c.id, { x: c.x, y: c.y }]))

    // ── kill edge crossings by making ports FOLLOW the laid-out nodes ──────────────────────────
    // ELK is free to place a condition's then/else subtrees on either side; if our fixed 28/72
    // ports don't match that order the branch edges cross. So we read back each branch's x and put
    // the source port directly above its own subtree (and route merge edges to the near-side port).
    const center = (id) => { const p = pos[id]; return p ? p.x + 140 : null }
    const pctOf = (cid, id) => { const cx = pos[cid]?.x, c = center(id)
      return cx == null || c == null ? null : Math.max(14, Math.min(86, ((c - cx) / 280) * 100)) }
    const ov = {}
    model.items.forEach((it) => {
      if (it.kind !== 'condition') return
      ov[it.id] = { thenLeft: pctOf(it.id, it.then?.[0]?.id) ?? 28, elseLeft: pctOf(it.id, it.else?.[0]?.id) ?? 72 }
    })

    nodes = ns.map((n) => ({ ...n, position: pos[n.id] || n.position,
      data: ov[n.id] ? { ...n.data, ...ov[n.id] } : n.data }))

    // merge edges (two branches → one node): send the left source into `in`, the right into `in2`
    const merged = new Set(ns.filter((n) => n.data.merge).map((n) => n.id))
    edges = es.map((e) => merged.has(e.target)
      ? { ...e, targetHandle: (pos[e.source]?.x ?? 0) <= (pos[e.target]?.x ?? 0) ? 'in' : 'in2' }
      : e)
  }

  $effect(() => { layout() })

  function regenerate() {
    regenerating = true
    setTimeout(() => {
      const mark = (list) => list.forEach((n) => { n.status = 'generated'; if (n.then) mark(n.then); if (n.else) mark(n.else) })
      mark(model.items); dirty = false; regenerating = false; layout()
    }, 1100)
  }
  function addStep() { model.items.push(node('step', '', 'draft')); dirty = true; layout() }
  function addCondition() {
    const c = node('condition', '', 'draft'); c.then = [node('step', '', 'draft')]; c.else = [node('step', '', 'draft')]
    model.items.push(c); dirty = true; layout()
  }
</script>

{#if s}
  <section class="flex flex-col min-w-0 h-full">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none bg-paper">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR.workflow}">{@html iconSvgByName(s.icon, 18)}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">Prompt-built flow · {model.items.length} steps</div>
      </div>
      <span class="flex-1"></span>
      {#if dirty}<span class="text-[12px]" style="color:var(--color-peach)">Prompts changed</span>{/if}
      <button onclick={regenerate} disabled={regenerating}
        class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border [&>svg]:w-[15px] [&>svg]:h-[15px]
          {dirty && !regenerating ? 'text-ink border-[color-mix(in_srgb,var(--color-peach)_60%,var(--color-line))]' : 'text-dim border-line'} hoverwash">
        <span class={regenerating ? 'animate-spin' : ''}>{@html iconSvgByName(regenerating ? 'refresh' : 'sparks', 15)}</span>
        {regenerating ? 'Regenerating…' : 'Regenerate flow'}
      </button>
      <button onclick={addStep} class="flex items-center gap-1.5 text-[13px] px-2.5 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)} Step</button>
      <button onclick={addCondition} class="flex items-center gap-1.5 text-[13px] px-2.5 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('git-fork', 14)} Condition</button>
    </header>

    <div class="flex-1 min-h-0" style="background:var(--color-well)">
      <SvelteFlow bind:nodes bind:edges {nodeTypes} colorMode={ui.theme} fitView
        nodesDraggable={false} elementsSelectable={false} proOptions={{ hideAttribution: true }}>
        <Background gap={22} />
        <Controls showLock={false} />
      </SvelteFlow>
    </div>
  </section>
{/if}

<style>
  /* edges: subtle by default, light up (and jump to front) on hover so you can trace a path */
  section :global(.svelte-flow__edge-path) { transition: stroke .12s, stroke-width .12s; }
  section :global(.svelte-flow__edge:hover) { z-index: 10 !important; }
  section :global(.svelte-flow__edge:hover .svelte-flow__edge-path) {
    stroke: var(--color-sky) !important; stroke-width: 3 !important;
  }
  section :global(.svelte-flow__edge:hover .svelte-flow__arrowhead path),
  section :global(.svelte-flow__edge:hover marker path) { fill: var(--color-sky) !important; stroke: var(--color-sky) !important; }
  /* widen the invisible hit-area so hovering the edge is easy */
  section :global(.svelte-flow__edge-interaction) { stroke-width: 18px; }
  section :global(.svelte-flow__edge) { pointer-events: visiblePainted; }
</style>
