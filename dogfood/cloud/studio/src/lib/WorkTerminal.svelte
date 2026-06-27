<script>
  // A fully-custom, themed terminal panel for the Code workbench. NOT xterm/VS Code — our own Svelte
  // component in our palette. It is a thin VIEW over `dock.shell` (the host capability seam): input goes to
  // `dock.shell.exec`, the returned lines render here. The local provider answers in-browser today; the
  // runtime provider makes `exec` a host_exec into Nexus.Shell (the shell compiled to one wasm module) with
  // streamed output — same shape, no change here.
  import { dock } from './dock/index.js'
  import { iconSvgByName } from './icons.js'

  let { onClose } = $props()
  let lines = $state([
    { kind: 'sys', text: 'washy — workbooks shell (emulated, wasm sandbox). type `help`.' }
  ])
  let input = $state('')
  let scroller = $state(null)
  let history = []
  let hi = -1

  function emit(text, kind = 'out') { lines = [...lines, { kind, text }] }

  async function run(raw) {
    const cmd = raw.trim()
    emit('$ ' + cmd, 'cmd')
    if (!cmd) return
    history.unshift(cmd); hi = -1
    const result = await dock.shell.exec(cmd)
    for (const ln of result) {
      if (ln.kind === 'clear') { lines = []; continue }
      emit(ln.text, ln.kind)
    }
    queueScroll()
  }

  function onKey(e) {
    if (e.key === 'Enter') { run(input); input = ''; queueScroll() }
    else if (e.key === 'ArrowUp') { if (hi < history.length - 1) { hi++; input = history[hi] || '' } e.preventDefault() }
    else if (e.key === 'ArrowDown') { if (hi > 0) { hi--; input = history[hi] || '' } else { hi = -1; input = '' } }
  }
  function queueScroll() { requestAnimationFrame(() => { if (scroller) scroller.scrollTop = scroller.scrollHeight }) }

  const tone = { sys: 'var(--color-dim)', dim: 'var(--color-dim)', cmd: 'var(--color-ink)', out: 'var(--color-ink)', ok: 'var(--color-bloomd)', err: 'var(--color-bad)' }
</script>

<div class="h-full flex flex-col min-h-0" style="background:var(--color-well)">
  <!-- panel tab strip -->
  <div class="flex items-center gap-1 px-2 h-[32px] flex-none border-b border-line" style="background:var(--color-paper)">
    <span class="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-[12px] text-ink"
      style="background:color-mix(in srgb,var(--color-ink) 7%,transparent)">
      <span class="grid place-items-center text-bloomd [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('terminal', 14)}</span>
      Terminal
    </span>
    <span class="px-2.5 py-1 rounded-md text-[12px] text-dim hoverwash cursor-default">Output</span>
    <span class="px-2.5 py-1 rounded-md text-[12px] text-dim hoverwash cursor-default">Problems</span>
    <span class="flex-1"></span>
    <button onclick={() => (lines = [])} title="Clear" class="w-[26px] h-[26px] grid place-items-center rounded-md text-dim hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('erase', 14)}</button>
    <button onclick={onClose} title="Close panel" class="w-[26px] h-[26px] grid place-items-center rounded-md text-dim hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('xmark', 14)}</button>
  </div>

  <!-- scrollback -->
  <div bind:this={scroller} class="flex-1 min-h-0 overflow-y-auto px-3 py-2 font-mono text-[12.5px] leading-[1.55]">
    {#each lines as ln}
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
