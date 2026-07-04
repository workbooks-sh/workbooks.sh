<script>
  // The Toolkits page sub-nav. One column: Connected (cross-layer) at the top, then the three layers — Skills ·
  // Tools · Integrations — each row IS that layer's "show everything" entry (no separate "All" row). Selecting a
  // layer reveals its categories under Browse. Counts are per layer; Connected is everything enabled.
  import { ui } from './data.svelte.js'
  import { LAYERS, connectedProviders, providerCount, categoriesInLayer, providersInLayerCategory } from './toolkits.svelte.js'
  import { iconSvgByName } from './icons.js'

  const layer = $derived(ui.toolkitsLayer)
  const onLayer = $derived(ui.toolkitsView !== 'connected') // a layer row (vs Connected) is the active context
  const connectedCount = $derived(connectedProviders().length)
  const cats = $derived(categoriesInLayer(layer))
  function pickLayer(l) { ui.toolkitsLayer = l; ui.toolkitsView = 'all' }
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

    {#each LAYERS as l}
      <button onclick={() => pickLayer(l.id)} title={l.blurb}
        class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition [&>span>svg]:w-[16px] [&>span>svg]:h-[16px]
          {onLayer && layer === l.id && ui.toolkitsView === 'all' ? 'bg-card text-ink' : 'text-dim hover:text-ink hover:bg-card/50'}">
        <span class="grid place-items-center">{@html iconSvgByName(l.icon, 16)}</span>
        <span class="text-[13.5px] flex-1">{l.label}</span>
        <span class="text-[11px] font-mono text-dim">{providerCount(l.id)}</span>
      </button>
    {/each}

    {#if onLayer && cats.length > 1}
      <div class="text-[10.5px] font-mono uppercase tracking-wider text-dim/70 px-2.5 mt-3 mb-1">Browse {LAYERS.find((l) => l.id === layer).label.toLowerCase()}</div>
      {#each cats as c}
        <button onclick={() => go(c)}
          class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg text-left transition
            {ui.toolkitsView === c ? 'bg-card text-ink' : 'text-dim hover:text-ink hover:bg-card/50'}">
          <span class="text-[13.5px] flex-1 truncate">{c}</span>
          <span class="text-[11px] font-mono text-dim">{providersInLayerCategory(layer, c).length}</span>
        </button>
      {/each}
    {/if}
  </nav>
</aside>
