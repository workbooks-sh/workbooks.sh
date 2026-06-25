<script>
  import { Handle, Position } from '@xyflow/svelte'
  import { iconSvgByName } from './icons.js'

  // a single flow node = a PROMPT. data.item is the live model node ($state proxy) so editing the
  // textarea mutates the flow directly. kind ∈ trigger | step | condition.
  let { data } = $props()
  const item = $derived(data.item)
  const isTrigger = $derived(item.kind === 'trigger')
  const isCond = $derived(item.kind === 'condition')
</script>

<div class="wfnode {data.regenerating ? 'opacity-60' : ''}"
  style="border-color:{item.status === 'draft' ? 'color-mix(in srgb,var(--color-peach) 55%,var(--color-line))'
    : isTrigger ? 'color-mix(in srgb,var(--color-mint) 45%,var(--color-line))' : 'var(--color-line)'};
    background:{isTrigger ? 'color-mix(in srgb,var(--color-mint) 13%,var(--color-paper))' : 'var(--color-paper)'}">

  {#if !isTrigger}
    <Handle type="target" position={Position.Top} id="in" class="wfh" style={data.merge ? 'left:28%' : ''} />
    {#if data.merge}<Handle type="target" position={Position.Top} id="in2" class="wfh" style="left:72%" />{/if}
  {/if}

  <div class="flex items-center gap-2 mb-1">
    {#if isTrigger}
      <span class="grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:var(--color-mint)">{@html iconSvgByName('flash', 13)}</span>
    {:else}
      <span class="w-2 h-2 rounded-full flex-none" style="background:{item.status === 'draft' ? 'var(--color-peach)' : 'var(--color-mint)'}"></span>
    {/if}
    <span class="text-[9.5px] font-mono uppercase tracking-wider text-dim">{data.label}</span>
    {#if isCond}<span class="grid place-items-center ml-auto text-dim [&>svg]:w-[13px] [&>svg]:h-[13px]" style="color:var(--color-peach)">{@html iconSvgByName('git-fork', 13)}</span>{/if}
  </div>

  <textarea bind:value={item.prompt} oninput={data.onTouch} rows="2"
    placeholder={isCond ? 'Describe the condition — “if the build fails”. @ to reference'
      : isTrigger ? 'When this runs…' : 'Describe this step — “Fetch new GitHub issues”. @ to reference, / for a workflow'}
    class="w-full resize-none bg-transparent text-[12.5px] leading-snug focus:outline-none placeholder:text-dim/60 nodrag"></textarea>

  {#if isCond}
    <Handle type="source" position={Position.Bottom} id="then" class="wfh wfh-then" style="left:{data.thenLeft ?? 28}%" />
    <Handle type="source" position={Position.Bottom} id="else" class="wfh wfh-else" style="left:{data.elseLeft ?? 72}%" />
  {:else}
    <Handle type="source" position={Position.Bottom} id="out" class="wfh" />
  {/if}
</div>

<style>
  .wfnode { width: 280px; border: 1px solid var(--color-line); border-radius: 12px; padding: 10px 12px;
    box-shadow: 0 2px 10px rgba(0,0,0,.15); }
  /* handles — bigger, themed, sitting flush on the card edge */
  .wfnode :global(.wfh) {
    width: 11px; height: 11px; border-radius: 9999px;
    background: var(--color-paper); border: 2px solid var(--color-dim);
  }
  .wfnode :global(.wfh-then) { border-color: var(--color-mint); }
  .wfnode :global(.wfh-else) { border-color: var(--color-peach); }
</style>
