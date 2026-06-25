<script>
  import { Handle, Position } from '@xyflow/svelte'
  import { iconSvgByName } from './icons.js'

  // a single flow node = a PROMPT, drawn Unreal-style (left→right). data.item is the live model node
  // ($state proxy) so editing the textarea mutates the flow directly. kind ∈ trigger | step | condition.
  // PORTS are labelled colour badges: inputs hang off the LEFT, outputs off the RIGHT, each with a
  // floating connection handle on its outer end. Colours flow from the port into the edge + arrowhead.
  let { data } = $props()
  const item = $derived(data.item)
  const isTrigger = $derived(item.kind === 'trigger')
  const isCond = $derived(item.kind === 'condition')

  const DIM = 'var(--color-dim)'
  const inputs = $derived(data.inputs ?? (isTrigger ? [] : [{ id: 'in', label: 'in', color: DIM, top: 50 }]))
  const outputs = $derived(data.outputs ?? [{ id: 'out', label: 'out', color: DIM, top: 50 }])

  // auto-grow the textarea up to MAX lines, then it becomes a scroll box
  const LINE = 18, MAX = 10
  let ta = $state(null)
  function grow() {
    if (!ta) return
    ta.style.height = 'auto'
    const h = Math.min(ta.scrollHeight, MAX * LINE)
    ta.style.height = h + 'px'
    ta.style.overflowY = ta.scrollHeight > MAX * LINE ? 'auto' : 'hidden'
  }
  $effect(() => { item.prompt; grow() }) // re-grow on programmatic changes too
  function onInput(e) { grow(); data.onTouch?.(e) }
</script>

<div class="wfnode group/node {data.regenerating ? 'opacity-60' : ''}"
  style="border-color:{item.status === 'draft' ? 'color-mix(in srgb,var(--color-peach) 55%,var(--color-line))'
    : isTrigger ? 'color-mix(in srgb,var(--color-mint) 45%,var(--color-line))' : 'var(--color-line)'};
    background:{isTrigger ? 'color-mix(in srgb,var(--color-mint) 13%,var(--color-paper))' : 'var(--color-paper)'}">

  <!-- input ports (left) — handle floats outermost, badge sits against the card -->
  {#each inputs as p}
    <div class="port port-in" style="top:{p.top}%; --c:{p.color}">
      <Handle type="target" position={Position.Left} id={p.id} class="wfh" />
      <span class="pbadge">{p.label}</span>
    </div>
  {/each}

  <div class="flex items-center gap-2 mb-1">
    {#if isTrigger}
      <span class="grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:var(--color-mint)">{@html iconSvgByName('flash', 13)}</span>
    {:else}
      <span class="w-2 h-2 rounded-full flex-none" style="background:{item.status === 'draft' ? 'var(--color-peach)' : 'var(--color-mint)'}"></span>
    {/if}
    <span class="text-[9.5px] font-mono uppercase tracking-wider text-dim">{data.label}</span>
    <span class="ml-auto flex items-center gap-1.5">
      {#if isCond}<span class="grid place-items-center text-dim [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:var(--color-peach)">{@html iconSvgByName('git-fork', 13)}</span>{/if}
      <!-- expand → full-view editor; hover-revealed so the card stays clean -->
      <button title="Expand editor" onclick={() => data.onExpand?.(item, data.label)}
        class="nodrag grid place-items-center text-dim hover:text-ink transition-opacity opacity-0 group-hover/node:opacity-100 [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('expand', 13)}</button>
    </span>
  </div>

  <textarea bind:this={ta} bind:value={item.prompt} oninput={onInput} rows="1"
    placeholder={isCond ? 'Describe the condition — “if the build fails”. @ to reference'
      : isTrigger ? 'When this runs…' : 'Describe this step — “Fetch new GitHub issues”. @ to reference, / for a workflow'}
    class="w-full resize-none bg-transparent text-[12.5px] leading-snug focus:outline-none placeholder:text-dim/60 nodrag nopan nowheel"
    style="overflow-y:hidden"></textarea>

  <!-- output ports (right) — badge sits against the card, handle floats outermost -->
  {#each outputs as p}
    <div class="port port-out" style="top:{p.top}%; --c:{p.color}">
      <span class="pbadge">{p.label}</span>
      <Handle type="source" position={Position.Right} id={p.id} class="wfh" />
    </div>
  {/each}
</div>

<style>
  .wfnode { width: 300px; border: 1px solid var(--color-line); border-radius: 13px; padding: 12px 14px;
    box-shadow: 0 2px 10px rgba(0,0,0,.15); }

  /* a port = a flex cluster (badge + handle) anchored just outside the card edge */
  .port { position: absolute; display: flex; align-items: center; gap: 7px; pointer-events: none; }
  .port-in  { left: 0;  transform: translate(-100%, -50%); }
  .port-out { right: 0; transform: translate(100%, -50%); }

  .pbadge {
    font: 600 9px/1 var(--font-mono, ui-monospace, monospace);
    text-transform: uppercase; letter-spacing: .07em; white-space: nowrap;
    padding: 4px 7px; border-radius: 6px; color: var(--c);
    background: color-mix(in srgb, var(--c) 15%, var(--color-paper));
    border: 1px solid color-mix(in srgb, var(--c) 42%, var(--color-line));
  }

  /* the connection dot — take it out of xyflow's absolute flow so it sits inline in the badge cluster;
     xyflow still measures its real position, so edges connect exactly where the dot is drawn */
  .port :global(.svelte-flow__handle.wfh) {
    position: static !important; transform: none !important; margin: 0 !important;
    width: 11px; height: 11px; border-radius: 9999px; pointer-events: all;
    background: var(--color-paper); border: 2px solid var(--c);
  }
</style>
