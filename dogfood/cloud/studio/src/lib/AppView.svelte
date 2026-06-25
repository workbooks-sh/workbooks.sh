<script>
  import { ui, surfaceById, isRootWs } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'

  let { surfaceId } = $props()
  const s = $derived(surfaceById(surfaceId))
  const pages = $derived(s?.payload?.pages || [])

  let histIdx = $state([0])   // history as a stack of page indices
  let pos = $state(0)         // pointer into histIdx
  const cur = $derived(pages[histIdx[pos]] || pages[0])

  let palette = $state(false)
  let q = $state('')
  const results = $derived(pages
    .map((p, i) => ({ p, i }))
    .filter(({ p }) => (p.label + ' ' + p.path).toLowerCase().includes(q.trim().toLowerCase())))

  function go(i) {
    histIdx = [...histIdx.slice(0, pos + 1), i]
    pos = histIdx.length - 1
    palette = false; q = ''
  }
  const back = () => { if (pos > 0) pos-- }
  const fwd = () => { if (pos < histIdx.length - 1) pos++ }
  const host = $derived(`${s?.name?.toLowerCase().replace(/\s+/g, '-')}.work`)
</script>

{#if s}
  <section class="flex flex-col min-w-0 bg-paper h-full">
    <!-- browser chrome -->
    <header class="flex items-center gap-2 px-3 h-[57px] border-b border-line flex-none">
      <div class="flex items-center gap-0.5">
        <button onclick={back} disabled={pos === 0}
          class="w-8 h-8 grid place-items-center rounded-lg hoverwash [&>svg]:w-[18px] [&>svg]:h-[18px] {pos === 0 ? 'text-dim/40' : 'text-dim hover:text-ink'}">{@html iconSvgByName('arrow-left', 18)}</button>
        <button onclick={fwd} disabled={pos === histIdx.length - 1}
          class="w-8 h-8 grid place-items-center rounded-lg hoverwash [&>svg]:w-[18px] [&>svg]:h-[18px] {pos === histIdx.length - 1 ? 'text-dim/40' : 'text-dim hover:text-ink'}">{@html iconSvgByName('arrow-right', 18)}</button>
        <button class="w-8 h-8 grid place-items-center rounded-lg hoverwash text-dim hover:text-ink [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName('refresh-double', 16)}</button>
      </div>

      <!-- address bar = a route explorer -->
      <div class="relative flex-1">
        <button onclick={() => { palette = !palette; q = '' }}
          class="flex items-center gap-2 w-full bg-card border border-line rounded-lg px-3 h-9 text-left hover:border-[color-mix(in_srgb,var(--color-ink)_20%,var(--color-line))]">
          <span class="text-dim grid place-items-center [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('lock', 14)}</span>
          <span class="text-[13.5px] truncate"><span class="text-dim">{host}</span>{cur?.path}</span>
          <span class="ml-auto text-dim grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('search', 15)}</span>
        </button>

        {#if palette}
          <div class="absolute top-full left-0 right-0 mt-1.5 z-20 rounded-xl border border-line bg-card overflow-hidden"
            style="box-shadow:0 18px 40px rgba(0,0,0,.35)">
            <!-- svelte-ignore a11y_autofocus -->
            <input autofocus bind:value={q} placeholder="Search routes in {s.name}…  (e.g. pricing, blog)"
              class="w-full bg-paper border-b border-line px-3 py-2.5 text-[13.5px] focus:outline-none" />
            <div class="max-h-72 overflow-y-auto py-1">
              {#each results as { p, i }}
                <button onclick={() => go(i)} class="flex items-center gap-2.5 w-full text-left px-3 py-2 hoverwash {cur === p ? 'bg-[color-mix(in_srgb,var(--color-ink)_7%,transparent)]' : ''}">
                  <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]" style="color:{KIND_COLOR.app}">{@html iconSvgByName('page-flip', 15)}</span>
                  <span class="text-[13.5px] flex-1">{p.label}</span>
                  <span class="text-dim text-[12px] font-mono">{p.path}</span>
                </button>
              {/each}
              {#if !results.length}<div class="px-3 py-4 text-dim text-[13px] text-center">No route matches “{q}”.</div>{/if}
            </div>
          </div>
        {/if}
      </div>

      {#if isRootWs(s?.workspace)}
        <span class="flex-none text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded font-mono" style="color:var(--color-violet);background:color-mix(in srgb,var(--color-violet) 18%,transparent)" title="Org-scoped · highest permission tier">org · highest scope</span>
      {/if}
      <button class="w-8 h-8 grid place-items-center rounded-lg hoverwash text-dim hover:text-ink [&>svg]:w-[16px] [&>svg]:h-[16px]" title="Open in new tab">{@html iconSvgByName('open-new-window', 16)}</button>
      <button title="Settings" aria-label="Settings"
        class="w-8 h-8 grid place-items-center rounded-lg border border-line hoverwash text-dim hover:text-ink [&>svg]:w-[16px] [&>svg]:h-[16px]
          {ui.settingsOpen ? '!text-ink !border-[color-mix(in_srgb,var(--color-ink)_30%,var(--color-line))]' : ''}"
        onclick={() => { ui.settingsOpen = !ui.settingsOpen; ui.wsSettings = null }}>{@html iconSvgByName('settings', 16)}</button>
    </header>

    <!-- viewport: a mock render of the current route -->
    <div class="flex-1 overflow-y-auto grid place-items-center p-8" style="background:var(--color-well)">
      <div class="w-full max-w-3xl rounded-2xl border border-line bg-paper overflow-hidden" style="box-shadow:0 10px 40px rgba(0,0,0,.25)">
        <div class="flex items-center gap-2 px-4 h-10 border-b border-line">
          <span class="grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]" style="color:{KIND_COLOR.app}">{@html iconSvgByName(s.icon, 15)}</span>
          <span class="font-display font-semibold text-[13px]">{s.name}</span>
          <span class="flex gap-1.5 ml-3">
            {#each pages as p}
              <button onclick={() => go(pages.indexOf(p))} class="text-[12px] px-2 py-0.5 rounded {cur === p ? 'bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] text-ink' : 'text-dim hover:text-ink'}">{p.label}</button>
            {/each}
          </span>
        </div>
        <div class="p-10">
          <div class="text-[11px] font-mono uppercase tracking-widest text-dim mb-2">{host}{cur?.path}</div>
          <h1 class="font-display text-3xl font-bold mb-3">{cur?.label}</h1>
          <p class="text-dim text-[14px] max-w-lg mb-6">This route renders the <b>{cur?.label}</b> page of {s.name}. In the real app the page’s client islands render here, behind the same auth + permissioning as the workspace.</p>
          <div class="flex flex-col gap-2.5">
            {#each [92, 78, 85, 60] as w}<div class="h-3 rounded" style="width:{w}%;background:color-mix(in srgb,var(--color-ink) 8%,transparent)"></div>{/each}
          </div>
        </div>
      </div>
    </div>
  </section>
{/if}
