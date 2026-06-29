<script>
  // The persistent right-side AUX PANEL — where a capability's VIEW renders (the MCP-App / MCP-UI surface).
  // It lives at the app-grid level, so it stays across every section (Studio · Code · Toolkits · You). The
  // active view is `ui.auxView` (a contributed view id); we render its provider's DOM into our container. A
  // real MCP-UI server returns a UI resource rendered here the same way — one surface, swappable source.
  import { ui } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  let host = $state(null)
  // The active aux view. MCP-UI rendering (an MCP server returning a UI resource) wires in here next; until
  // then nothing sets ui.auxView, so this panel stays dormant. (Extensions, the old source, are removed.)
  const view = $derived(ui.auxView ? null : null)

  // (re)render the active view's DOM whenever it changes
  $effect(() => {
    const v = view
    if (!host) return
    host.innerHTML = ''
    if (!v) return
    const disposer = v.render(host)
    return () => { try { disposer?.dispose?.() } catch {} ; if (host) host.innerHTML = '' }
  })
</script>

<div class="h-full flex flex-col min-w-0" style="background:var(--color-paper)">
  <div class="flex items-center gap-2 px-3.5 h-[40px] flex-none border-b border-line">
    <span class="grid place-items-center text-bloomd [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName(view?.icon || 'puzzle', 15)}</span>
    <span class="text-[13px] font-medium text-ink truncate">{view?.title || 'Panel'}</span>
    <span class="flex-1"></span>
    <button onclick={() => (ui.auxView = null)} title="Close panel"
      class="w-[26px] h-[26px] grid place-items-center rounded-md text-dim hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('xmark', 14)}</button>
  </div>
  <div bind:this={host} class="flex-1 min-h-0 overflow-y-auto"></div>
</div>
