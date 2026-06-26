<script>
  // The Toolkits page sub-nav. A 3-way TYPE SWITCHER (Skills · Tools · Integrations) pins the active layer at
  // the top; everything below — Connected (cross-layer), the "All" entry, and the Browse categories with their
  // counts — reflects whichever layer is active. This keeps the ~870 auth integrations from drowning the
  // curated tools/skills: each layer is its own bucket.
  import { ui } from './data.svelte.js'
  import { LAYERS, connectedProviders, providerCount, categoriesInLayer, providersInLayerCategory } from './toolkits.svelte.js'
  import { iconSvgByName } from './icons.js'

  const layer = $derived(ui.toolkitsLayer)
  const connectedCount = $derived(connectedProviders().length)
  const cats = $derived(categoriesInLayer(layer))
  function pickLayer(l) { ui.toolkitsLayer = l; ui.toolkitsView = 'all' }
  function go(v) { ui.toolkitsView = v }
</script>

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0">
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none mt-2.5">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Toolkits</span>
  </div>

  <!-- the type switcher: which of the three layers the catalogue is showing -->
  <div class="px-2.5 mt-1 flex-none">
    <div class="flex gap-0.5 p-0.5 rounded-xl bg-card border border-line">
      {#each LAYERS as l}
        <button onclick={() => pickLayer(l.id)} title={l.blurb}
          class="flex-1 flex items-center justify-center gap-1 px-1.5 py-1.5 rounded-lg text-[12px] transition [&>svg]:w-[13px] [&>svg]:h-[13px]
            {layer === l.id ? 'bg-paper text-ink shadow-sm font-medium' : 'text-dim hover:text-ink'}">
          {@html iconSvgByName(l.icon, 13)}{l.label}
        </button>
      {/each}
    </div>
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
      <span class="grid place-items-center">{@html iconSvgByName(LAYERS.find((l) => l.id === layer).icon, 16)}</span>
      <span class="text-[13.5px] flex-1">All {LAYERS.find((l) => l.id === layer).label.toLowerCase()}</span>
      <span class="text-[11px] font-mono text-dim">{providerCount(layer)}</span>
    </button>

    {#if cats.length > 1}
      <div class="text-[10.5px] font-mono uppercase tracking-wider text-dim/70 px-2.5 mt-3 mb-1">Browse</div>
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
