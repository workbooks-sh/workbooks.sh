<script>
  // Toolkits — the catalogue page, grouped BY PROVIDER. A toolkit is a CLI compiled to WASM + its skills.
  // A provider groups all its connections (variants); the catalogue shows one card per provider. A single-
  // connection provider keeps an inline enable toggle; a multi-connection provider shows a Details button that
  // opens a drawer where each connection is toggled. Icons resolve through our glyphs toolkit; the sub-nav
  // (ToolkitsNav) drives the filter (connected / all / a category).
  import { ui } from './data.svelte.js'
  import { LAYERS, connectedProviders, providersInLayer, providersInLayerCategory, variantType, markFor, capsOf, CAP_META, LANG_META, AUTH_META, connState } from './toolkits.svelte.js'
  import Glyph from './Glyph.svelte'
  import { iconSvgByName } from './icons.js'

  const view = $derived(ui.toolkitsView)
  const layer = $derived(ui.toolkitsLayer)
  const layerMeta = $derived(LAYERS.find((l) => l.id === layer))
  // Connected is cross-layer (everything enabled); All / a category are scoped to the active layer
  const shown = $derived(
    view === 'connected' ? connectedProviders() :
    view === 'all' ? providersInLayer(layer) : providersInLayerCategory(layer, view)
  )
  const title = $derived(view === 'connected' ? 'Connected' : view === 'all' ? `All ${layerMeta.label.toLowerCase()}` : view)
  const sub = $derived(
    view === 'connected' ? 'Toolkits with a connection enabled in your sandboxes' :
    view === 'all' ? layerMeta.blurb :
    `${view} · ${layerMeta.label.toLowerCase()}`)

  // search within the current view, then page in on scroll (the catalogue is ~700 providers — never render all)
  const PAGE = 36
  let query = $state('')
  let limit = $state(PAGE)
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase()
    if (!q) return shown
    return shown.filter((p) =>
      p.name.toLowerCase().includes(q) || p.id.includes(q) || p.category.toLowerCase().includes(q) ||
      p.variants.some((v) => v.name.toLowerCase().includes(q) || (v.tools || []).some((x) => x.includes(q))))
  })
  const visible = $derived(filtered.slice(0, limit))
  $effect(() => { view; layer; query; limit = PAGE })

  // infinite scroll — bump the limit when a sentinel near the bottom enters the scroll viewport
  let scroller = $state(null), sentinel = $state(null)
  $effect(() => {
    if (!scroller || !sentinel) return
    const io = new IntersectionObserver((es) => {
      if (es[0].isIntersecting && limit < filtered.length) limit = Math.min(limit + PAGE, filtered.length)
    }, { root: scroller, rootMargin: '600px' })
    io.observe(sentinel)
    return () => io.disconnect()
  })

  const MAX_TOOLS = 4
  function toggle(t) { t.enabled = !t.enabled }
  function connect(t) {
    if (t.auth === 'env') ui.secretsModal = t.id
    else if (t.auth === 'oauth') ui.authTerminal = t.id
  }
</script>

<div class="h-full bg-paper flex flex-col min-w-0">
  <div class="flex items-center gap-3 px-6 pt-6 pb-4 flex-none border-b border-line">
    <div class="flex-1 min-w-0">
      <div class="font-display font-semibold text-[19px] tracking-tight leading-none">{title}</div>
      <div class="text-dim text-[12.5px] mt-1.5">{sub} · {filtered.length} {filtered.length === 1 ? 'toolkit' : 'toolkits'}{query.trim() ? ' found' : ''}</div>
    </div>
    <label class="flex items-center gap-2 px-3 h-9 rounded-xl border border-line bg-card text-dim focus-within:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))] transition [&>svg]:w-4 [&>svg]:h-4 flex-none w-[260px] max-w-[40vw]">
      {@html iconSvgByName('search', 16)}
      <input bind:value={query} placeholder="Search toolkits…" spellcheck="false"
        class="flex-1 min-w-0 bg-transparent border-0 outline-none text-ink text-[13px] placeholder:text-dim" />
      {#if query}<button onclick={() => (query = '')} aria-label="Clear" class="text-dim hover:text-ink [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('xmark', 14)}</button>{/if}
    </label>
  </div>

  <div bind:this={scroller} class="flex-1 overflow-y-auto px-6 py-6">
    {#if !filtered.length}
      <div class="text-dim/70 text-[13.5px]">{query.trim() ? `No providers match “${query.trim()}”.` : 'Nothing here yet. Browse the catalog and enable a toolkit to make its CLI available to your agents.'}</div>
    {:else}
      <div class="grid gap-3.5" style="grid-template-columns:repeat(auto-fill,minmax(290px,1fr))">
        {#each visible as p (p.id)}
          {@const rep = p.rep}
          {@const mk = markFor(rep)}
          {@const lang = LANG_META[rep.lang] || { label: rep.lang, tint: 'var(--color-dim)' }}
          {@const single = p.variants.length === 1}
          {@const v0 = p.variants[0]}
          {@const cs = single ? connState(v0) : null}
          {@const enabledCount = p.variants.filter((v) => v.enabled).length}
          {@const connectedCount = p.variants.filter((v) => v.enabled && (v.auth === 'none' || v.connected)).length}
          {@const enabledVs = p.variants.filter((v) => v.enabled)}
          {@const aggNeeds = enabledVs.some((v) => connState(v).needs)}
          {@const showAgg = enabledVs.some((v) => v.auth !== 'none')}
          <div class="group rounded-2xl border border-line bg-card p-4 flex flex-col gap-3 transition"
            style="border-color:{enabledCount ? 'color-mix(in srgb,var(--color-mint) 32%,var(--color-line))' : 'var(--color-line)'}">
            <div class="flex items-start gap-3">
              <span class="w-10 h-10 rounded-xl grid place-items-center flex-none border border-line bg-paper overflow-hidden [&_svg]:w-[23px] [&_svg]:h-[23px]">
                <Glyph ref={mk.ref} color={mk.color} ink={mk.ink} size={23} fallback={rep.fallback} />
              </span>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <span class="font-semibold text-[14px] truncate">{p.name}</span>
                  {#if single && rep.lang}
                    <span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none" style="color:{lang.tint};border:1px solid color-mix(in srgb,{lang.tint} 40%,transparent)">{lang.label}</span>
                  {/if}
                  {#if single && AUTH_META[v0.auth]}
                    <span class="flex-none px-1.5 py-0.5 rounded text-[10px] font-mono leading-none text-dim border border-line">{AUTH_META[v0.auth].badge}</span>
                  {/if}
                  {#if single && v0.stars}
                    <span class="flex-none flex items-center gap-0.5 text-[10.5px] font-mono text-dim/80 [&>svg]:w-3 [&>svg]:h-3" title="{v0.stars.toLocaleString()} GitHub stars · {v0.license || 'open source'}">{@html iconSvgByName('star', 12)}{v0.stars >= 1000 ? (v0.stars / 1000).toFixed(1) + 'k' : v0.stars}</span>
                  {/if}
                </div>
                <div class="text-dim text-[12.5px] mt-1 leading-snug">{single ? v0.summary : `${p.variants.length} connections`}</div>
              </div>
              <div class="flex items-center gap-1.5 flex-none">
                {#if single}
                  <button onclick={() => (ui.toolkitDetail = v0.id)} title="Details"
                    class="w-6 h-6 grid place-items-center rounded-md text-dim hover:text-ink border border-transparent hover:border-line opacity-0 group-hover:opacity-100 transition [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('info-circle', 14)}</button>
                  <button onclick={() => toggle(v0)} title={v0.enabled ? 'Disable' : 'Enable'}
                    class="w-9 h-5 rounded-full relative transition" style="background:{v0.enabled ? 'var(--color-mint)' : 'var(--color-line)'}">
                    <span class="absolute top-0.5 w-4 h-4 rounded-full bg-paper transition-all" style="left:{v0.enabled ? '18px' : '2px'}"></span>
                  </button>
                {:else}
                  <!-- multi-connection: open the manage drawer; the count reads connected/total -->
                  <button onclick={() => (ui.providerDetail = p.id)} title="Manage connections"
                    class="flex items-center gap-1.5 px-2.5 h-6 rounded-md text-[11.5px] text-dim hover:text-ink border border-line hover:border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))] transition [&>svg]:w-3 [&>svg]:h-3">
                    {@html iconSvgByName('settings', 12)}Manage
                    <span class="font-mono text-[10.5px]"><span style="color:{connectedCount ? 'var(--color-mint)' : 'inherit'}">{connectedCount}</span>/{p.variants.length}</span></button>
                {/if}
              </div>
            </div>

            {#if single}
              <div class="flex flex-wrap gap-1.5">
                {#each v0.tools.slice(0, MAX_TOOLS) as tool}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">{tool}</span>{/each}
                {#if v0.tools.length > MAX_TOOLS}
                  <button onclick={() => (ui.toolkitDetail = v0.id)} title="See all {v0.tools.length} commands"
                    class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim hover:text-ink hover:border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))] transition">+{v0.tools.length - MAX_TOOLS}</button>
                {/if}
              </div>
            {:else}
              <!-- the provider's connection types as chips (Default · MCP · SCIM …) -->
              <div class="flex flex-wrap gap-1.5">
                {#each p.variants.slice(0, 4) as v}
                  <span class="px-2 py-0.5 rounded-md text-[11px] bg-paper border border-line {v.enabled ? 'text-ink' : 'text-dim'}" style={v.enabled ? 'border-color:color-mix(in srgb,var(--color-mint) 40%,var(--color-line))' : ''}>{variantType(v, p.name)}</span>
                {/each}
                {#if p.variants.length > 4}<span class="px-2 py-0.5 rounded-md text-[11px] font-mono bg-paper border border-line text-dim">+{p.variants.length - 4}</span>{/if}
              </div>
            {/if}

            <div class="flex items-end gap-2 mt-auto pt-1">
              <div class="flex items-center flex-wrap gap-1.5 flex-1">
                {#each capsOf(p) as cap}
                  <span class="px-1.5 py-0.5 rounded text-[10px] font-mono leading-none"
                    style="color:{CAP_META[cap].color};background:color-mix(in srgb,{CAP_META[cap].color} 14%,transparent)">{CAP_META[cap].label}</span>
                {/each}
              </div>
              {#if single}
                {#if v0.enabled && cs && (cs.needs || cs.ok)}
                  <button onclick={() => connect(v0)} title={cs.ok ? 'Connected — manage' : ''}
                    class="flex-none flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] border transition [&>svg]:w-3 [&>svg]:h-3"
                    style="color:{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'};border-color:color-mix(in srgb,{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'} 38%,transparent);background:color-mix(in srgb,{cs.ok ? 'var(--color-mint)' : 'var(--color-peach)'} 11%,transparent)">{@html iconSvgByName(cs.ok ? 'check' : 'warning-triangle', 12)}{cs.label}</button>
                {/if}
              {:else if showAgg}
                <!-- multi-connection: aggregate auth state of the enabled connections -->
                <button onclick={() => (ui.providerDetail = p.id)} title={aggNeeds ? 'Connections need authentication' : 'Connected'}
                  class="flex-none flex items-center gap-1 px-2 py-1 rounded-lg text-[11px] border transition [&>svg]:w-3 [&>svg]:h-3"
                  style="color:{aggNeeds ? 'var(--color-peach)' : 'var(--color-mint)'};border-color:color-mix(in srgb,{aggNeeds ? 'var(--color-peach)' : 'var(--color-mint)'} 38%,transparent);background:color-mix(in srgb,{aggNeeds ? 'var(--color-peach)' : 'var(--color-mint)'} 11%,transparent)">{@html iconSvgByName(aggNeeds ? 'warning-triangle' : 'check', 12)}{aggNeeds ? 'Authenticate' : 'Connected'}</button>
              {/if}
            </div>
          </div>
        {/each}
      </div>
      <div bind:this={sentinel} class="h-px"></div>
      {#if limit < filtered.length}
        <div class="text-dim/60 text-[12px] text-center mt-5">Loading more… showing {visible.length} of {filtered.length}</div>
      {:else if filtered.length > PAGE}
        <div class="text-dim/40 text-[12px] text-center mt-5">All {filtered.length} shown</div>
      {/if}
    {/if}
  </div>
</div>
