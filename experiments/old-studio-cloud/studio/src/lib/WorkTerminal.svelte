<script>
  // A fully-custom, themed terminal panel — a VIEW over the shared `term` store (term.svelte.js), which is a
  // thin layer over dock.shell.exec. Input here and the toolbar's Run/Weave feed the SAME scrollback. The
  // runtime provider makes exec a host_exec into Nexus.Shell (the shell compiled to one wasm module) with
  // streamed output — same shape, no change here.
  import { term, exec, clear } from './term.svelte.js'
  import { iconSvgByName } from './icons.js'

  let { onClose } = $props()
  let input = $state('')
  let scroller = $state(null)
  let history = []
  let hi = -1

  async function submit() {
    const cmd = input
    input = ''
    if (cmd.trim()) { history.unshift(cmd.trim()); hi = -1 }
    await exec(cmd)
    queueScroll()
  }
  function onKey(e) {
    if (e.key === 'Enter') submit()
    else if (e.key === 'ArrowUp') { if (hi < history.length - 1) { hi++; input = history[hi] || '' } e.preventDefault() }
    else if (e.key === 'ArrowDown') { if (hi > 0) { hi--; input = history[hi] || '' } else { hi = -1; input = '' } }
  }
  function queueScroll() { requestAnimationFrame(() => { if (scroller) scroller.scrollTop = scroller.scrollHeight }) }

  const tone = { sys: 'var(--color-dim)', dim: 'var(--color-dim)', cmd: 'var(--color-ink)', out: 'var(--color-ink)', ok: 'var(--color-bloomd)', err: 'var(--color-bad)' }
</script>

<div class="h-full flex flex-col min-h-0" style="background:var(--color-well)">
  <!-- panel header -->
  <div class="flex items-center gap-1 px-2 h-[32px] flex-none border-b border-line" style="background:var(--color-paper)">
    <span class="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-[12px] text-ink"
      style="background:color-mix(in srgb,var(--color-ink) 7%,transparent)">
      <span class="grid place-items-center text-bloomd [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('terminal', 14)}</span>
      Terminal
    </span>
    <span class="flex-1"></span>
    <button onclick={clear} title="Clear" class="w-[26px] h-[26px] grid place-items-center rounded-md text-dim hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('erase', 14)}</button>
    <button onclick={onClose} title="Close panel" class="w-[26px] h-[26px] grid place-items-center rounded-md text-dim hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('xmark', 14)}</button>
  </div>

  <!-- scrollback -->
  <div bind:this={scroller} class="flex-1 min-h-0 overflow-y-auto px-3 py-2 font-mono text-[12.5px] leading-[1.55]">
    {#each term.lines as ln}
      <div class="whitespace-pre-wrap" style="color:{tone[ln.kind] || 'var(--color-ink)'}">{ln.text}</div>
    {/each}
    <!-- prompt -->
    <div class="flex items-center gap-1.5">
      <span style="color:var(--color-bloomd)">›</span>
      <!-- svelte-ignore a11y_autofocus -->
      <input bind:value={input} onkeydown={onKey} autofocus spellcheck="false"
        class="flex-1 min-w-0 bg-transparent border-0 focus:outline-none font-mono text-[12.5px]"
        style="color:var(--color-ink)" />
    </div>
  </div>
</div>
