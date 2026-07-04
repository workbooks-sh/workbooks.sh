<script>
  import { untrack, tick } from 'svelte'
  import { SvelteFlow, Background, Controls, MarkerType } from '@xyflow/svelte'
  import '@xyflow/svelte/dist/style.css'
  import ELK from 'elkjs/lib/elk.bundled.js'
  import { ui, surfaceById, startRun } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'
  import PromptNode from './PromptNode.svelte'
  import RunDialog from './RunDialog.svelte'

  let { surfaceId, onBack } = $props()
  let testOpen = $state(false)
  function doTest(values) { startRun(surfaceId, values); onBack?.() }
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
  let editing = $state(null) // { item, label } for the full-view editor

  // typing changes a card's height → re-run layout (debounced) so neighbours don't overlap
  let relayoutTimer
  const onTouch = () => { dirty = true; clearTimeout(relayoutTimer); relayoutTimer = setTimeout(layout, 220) }
  const onExpand = (item, label) => { editing = { item, label } }

  // port colours — edges + arrowheads inherit the colour of the OUTPUT they leave from
  const GRAY = 'var(--color-dim)', MINT = 'var(--color-mint)', PEACH = 'var(--color-peach)'
  const oneIn = [{ id: 'in', label: 'in', color: GRAY, top: 50 }]
  const oneOut = [{ id: 'out', label: 'out', color: GRAY, top: 50 }]

  // model → Svelte Flow graph (nodes + edges), then ELK lays it out left-to-right (Unreal style)
  function buildGraph() {
    const ns = [], es = []
    // node renders auto-height (so ports sit on the real card edge); ELK gets an ESTIMATE
    const estH = (it) => it.kind === 'trigger' ? 64
      : 56 + Math.max(2, Math.ceil((it.prompt || '').length / 36)) * 18
    const mk = (it, label, extra = {}) => { const n = { id: it.id, type: 'prompt', position: { x: 0, y: 0 },
      data: { item: it, label, onTouch, onExpand, regenerating, inputs: oneIn, outputs: oneOut, ...extra },
      draggable: false, width: 300, _h: estH(it) }; ns.push(n); return n }
    // an edge inherits its source port's colour (into both the stroke and the arrowhead)
    const edge = (src, srcHandle, tgt, color) => es.push({
      id: `${src}:${srcHandle}->${tgt}`, source: src, target: tgt, sourceHandle: srcHandle, targetHandle: 'in',
      type: 'smoothstep',
      markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18, color },
      style: `stroke:${color};stroke-width:1.7` })

    mk(model.trigger, 'Trigger', { inputs: [], outputs: oneOut, triggerInputs: s?.payload?.inputs || [] })
    let prev = [{ id: model.trigger.id, handle: 'out', color: GRAY }]
    model.items.forEach((it, i) => {
      if (it.kind === 'condition') {
        mk(it, 'Condition', { inputs: oneIn, outputs: [
          { id: 'then', label: 'true', color: MINT, top: 36 },
          { id: 'else', label: 'false', color: PEACH, top: 64 }] })
      } else {
        mk(it, `Step ${i + 1}`)
      }
      prev.forEach((p) => edge(p.id, p.handle, it.id, p.color))
      if (it.kind === 'condition') {
        // a branch: its FIRST edge carries the condition's then/else colour, the rest are gray step→step
        const chain = (branch, handle, color) => {
          let p = { id: it.id, handle, color }
          branch.forEach((bn) => { mk(bn, 'Step'); edge(p.id, p.handle, bn.id, p.color); p = { id: bn.id, handle: 'out', color: GRAY } })
          return p
        }
        prev = [chain(it.then || [], 'then', MINT), chain(it.else || [], 'else', PEACH)]
      } else {
        prev = [{ id: it.id, handle: 'out', color: GRAY }]
      }
    })
    return { ns, es }
  }

  // read a node's actual rendered height from the DOM (null until Svelte Flow has painted it)
  function measuredH(id) {
    const el = typeof document !== 'undefined' && document.querySelector(`.svelte-flow__node[data-id="${id}"]`)
    return el && el.offsetHeight ? el.offsetHeight : null
  }

  async function layout() {
    // remember the editing caret so reassigning `nodes` (below) doesn't blow away focus mid-type
    const a = typeof document !== 'undefined' && document.activeElement
    let keepFocus = null
    if (a && a.tagName === 'TEXTAREA') {
      const nodeEl = a.closest('.svelte-flow__node')
      if (nodeEl) keepFocus = { id: nodeEl.getAttribute('data-id'), start: a.selectionStart, end: a.selectionEnd }
    }
    const { ns, es } = buildGraph()
    const g = {
      id: 'root',
      layoutOptions: {
        'elk.algorithm': 'layered', 'elk.direction': 'RIGHT',
        // big between-layers gap to leave room for the output badge + edge + next node's input badge
        'elk.layered.spacing.nodeNodeBetweenLayers': '170', 'elk.spacing.nodeNode': '46',
        'elk.spacing.edgeEdge': '20', 'elk.spacing.edgeNode': '24',
        'elk.layered.spacing.edgeEdgeBetweenLayers': '16', 'elk.layered.spacing.edgeNodeBetweenLayers': '24',
        'elk.layered.nodePlacement.strategy': 'NETWORK_SIMPLEX'
      },
      // use the REAL rendered card height once it exists (so growing a prompt re-flows the graph
      // with true spacing); fall back to the estimate on the very first layout pass.
      children: ns.map((n) => ({ id: n.id, width: n.width, height: measuredH(n.id) ?? n._h })),
      edges: es.map((e) => ({ id: e.id, sources: [e.source], targets: [e.target] }))
    }
    const res = await elk.layout(g)
    const pos = Object.fromEntries(res.children.map((c) => [c.id, { x: c.x, y: c.y }]))

    // ── straight spine, fanned branches ──────────────────────────────────────────────────────────
    // ELK gives us good COLUMN (x) positions, but its vertical balancing staggers a plain chain so
    // edges slope. We keep ELK's x and assign y ourselves: every spine node (trigger + each top-level
    // item) shares ONE baseline, so a sequential flow is a dead-straight row; a condition's then/else
    // branches fan a fixed band above/below. Ports stay at 50%, so spine edges are perfectly level.
    const hOf = (id) => measuredH(id) ?? ns.find((n) => n.id === id)?._h ?? 96
    const Y0 = 0, BAND = 150
    const npos = {}
    const setCenter = (id, cy) => { if (pos[id]) npos[id] = { x: pos[id].x, y: cy - hOf(id) / 2 } }
    const ov = {}

    setCenter(model.trigger.id, Y0)
    model.items.forEach((it) => {
      setCenter(it.id, Y0)
      if (it.kind !== 'condition') return
      ;(it.then || []).forEach((bn) => setCenter(bn.id, Y0 - BAND))
      ;(it.else || []).forEach((bn) => setCenter(bn.id, Y0 + BAND))
      // point the then/else output badges at their branch rows (above / below the card centre)
      const ch = hOf(it.id)
      const pct = (cy) => Math.max(14, Math.min(86, ((cy - (Y0 - ch / 2)) / ch) * 100))
      ov[it.id] = { outputs: [
        { id: 'then', label: 'true', color: MINT, top: pct(Y0 - BAND) },
        { id: 'else', label: 'false', color: PEACH, top: pct(Y0 + BAND) }] }
    })

    nodes = ns.map((n) => ({ ...n, position: npos[n.id] || pos[n.id] || n.position,
      data: ov[n.id] ? { ...n.data, ...ov[n.id] } : n.data }))
    edges = es

    // re-focus the textarea we were editing (Svelte Flow re-rendered the node), restoring the caret
    if (keepFocus) {
      await tick()
      const ta = document.querySelector(`.svelte-flow__node[data-id="${keepFocus.id}"] textarea`)
      if (ta && document.activeElement !== ta) {
        ta.focus()
        try { ta.setSelectionRange(keepFocus.start, keepFocus.end) } catch {}
      }
    }
  }

  // initial layout — run once on mount, UNTRACKED so it never re-subscribes to prompt edits (typing
  // must not trigger a synchronous relayout; that's what onTouch's debounce is for). Two passes: the
  // first uses height ESTIMATES (cards aren't painted yet), the second uses the REAL measured heights
  // so spine nodes centre exactly and edges are dead-straight.
  $effect(() => { untrack(async () => { await layout(); await tick(); await layout() }) })

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
      {#if onBack}
        <button onclick={onBack} title="Back to runs"
          class="grid place-items-center w-8 h-8 -ml-1 rounded-lg text-dim hover:text-ink hoverwash [&>svg]:w-[18px] [&>svg]:h-[18px]">{@html iconSvgByName('arrow-left', 18)}</button>
      {/if}
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR.workflow}">{@html iconSvgByName(s.icon, 18)}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">Editing flow · {model.items.length} steps</div>
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
      <button onclick={() => (testOpen = true)} class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg text-ink [&>svg]:w-[14px] [&>svg]:h-[14px]"
        style="background:color-mix(in srgb,var(--color-mint) 22%,transparent)">{@html iconSvgByName('flash', 14)} Test run</button>
    </header>

    <div class="flex-1 min-h-0" style="background:var(--color-well)">
      <SvelteFlow bind:nodes bind:edges {nodeTypes} colorMode={ui.theme} fitView
        nodesDraggable={false} elementsSelectable={false}
        deleteKeyCode={null} selectionKeyCode={null} multiSelectionKeyCode={null}
        proOptions={{ hideAttribution: true }}>
        <Background gap={22} />
        <Controls showLock={false} />
      </SvelteFlow>
    </div>
  </section>

  {#if testOpen}<RunDialog surface={s} test onRun={doTest} onClose={() => (testOpen = false)} />{/if}

  <!-- full-view prompt editor: a focused overlay to write a long prompt comfortably -->
  {#if editing}
    <div class="fixed inset-0 z-50 grid place-items-center p-6" style="background:rgba(0,0,0,.5)"
      onclick={() => (editing = null)} role="presentation">
      <div class="w-full max-w-2xl rounded-2xl border border-line bg-paper flex flex-col overflow-hidden"
        style="box-shadow:0 30px 80px rgba(0,0,0,.5); max-height:80vh"
        onclick={(e) => e.stopPropagation()} role="dialog" tabindex="-1">
        <div class="flex items-center gap-2.5 px-5 h-[54px] border-b border-line flex-none">
          <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style="color:{KIND_COLOR.workflow}">{@html iconSvgByName(editing.item.kind === 'condition' ? 'git-fork' : editing.item.kind === 'trigger' ? 'flash' : 'text', 16)}</span>
          <div class="font-display font-semibold">{editing.label}</div>
          <span class="flex-1"></span>
          <button onclick={() => (editing = null)} class="grid place-items-center w-8 h-8 rounded-lg text-dim hover:text-ink hoverwash [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName('xmark', 16)}</button>
        </div>
        <!-- svelte-ignore a11y_autofocus -->
        <textarea autofocus bind:value={editing.item.prompt} oninput={onTouch}
          placeholder="Write the prompt for this step…"
          class="flex-1 min-h-[260px] w-full resize-none bg-transparent px-5 py-4 text-[15px] leading-relaxed focus:outline-none placeholder:text-dim/50"></textarea>
        <div class="flex items-center gap-2 px-5 h-[52px] border-t border-line flex-none">
          <span class="text-dim text-[12px]">{(editing.item.prompt || '').length} chars · ⌘↵ to close</span>
          <span class="flex-1"></span>
          <button onclick={() => (editing = null)} class="text-[13px] px-3.5 py-1.5 rounded-lg border border-line hoverwash">Done</button>
        </div>
      </div>
    </div>
  {/if}
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
