<script>
  // The Toolkits page sub-nav — the connected/browse sidebar. "Connected" shows what's enabled in your
  // sandboxes; "All toolkits" is the whole catalog; then one entry per category. Same sidebar shell as
  // Studio/Files/You so the four rail destinations stay consistent.
  import { ui } from './data.svelte.js'
  import { toolkits, enabledToolkits, CATEGORIES, toolkitsInCategory } from './toolkits.svelte.js'
  import { iconSvgByName } from './icons.js'

  const connectedCount = $derived(enabledToolkits().length)
  function go(v) { ui.toolkitsView = v }
</script>

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0">
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none mt-2.5">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Toolkits</span>
  </div>
  <nav class="flex-1 overflow-y-auto p-2.5 flex flex-col gap-0.5">
    <button onclick={() => go('connected')}
      class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px]
        {ui.toolkitsView === 'connected' ? 'bg-card text-ink' : 'text-dim hover:text-ink hover:bg-card/50'}">
      <span class="grid place-items-center">{@html iconSvgByName('check-circle', 16)}</span>
      <span class="text-[13.5px] flex-1">Connected</span>
      <span class="text-[11px] font-mono text-dim">{connectedCount}</span>
    </button>
    <button onclick={() => go('all')}
      class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px]
        {ui.toolkitsView === 'all' ? 'bg-card text-ink' : 'text-dim hover:text-ink hover:bg-card/50'}">
      <span class="grid place-items-center">{@html iconSvgByName('apple-shortcuts', 16)}</span>
      <span class="text-[13.5px] flex-1">All toolkits</span>
      <span class="text-[11px] font-mono text-dim">{toolkits.length}</span>
    </button>

    <div class="text-[10.5px] font-mono uppercase tracking-wider text-dim/70 px-2.5 mt-3 mb-1">Browse</div>
    {#each CATEGORIES as c}
      <button onclick={() => go(c)}
        class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition
          {ui.toolkitsView === c ? 'bg-card text-ink' : 'text-dim hover:text-ink hover:bg-card/50'}">
        <span class="text-[13.5px] flex-1 truncate">{c}</span>
        <span class="text-[11px] font-mono text-dim">{toolkitsInCategory(c).length}</span>
      </button>
    {/each}
  </nav>
</aside>
