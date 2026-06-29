<script>
  import { ALL_ICON_NAMES, iconSvgByName } from './icons.js'

  // controlled modal: pick from the WHOLE Iconoir library (1682 icons) with fuzzy search.
  let { value, color = 'var(--color-ink)', onpick, onclose } = $props()
  let q = $state('')
  const CAP = 180 // render cap; search narrows the long tail

  // subsequence fuzzy match (chars in order), ranked by tightness/earliness
  function score(key, query) {
    let qi = 0, last = -1, gaps = 0
    for (let i = 0; i < key.length && qi < query.length; i++) {
      if (key[i] === query[qi]) { if (last >= 0) gaps += i - last - 1; last = i; qi++ }
    }
    return qi === query.length ? gaps - last * 0.01 : Infinity
  }

  const all = $derived.by(() => {
    const query = q.trim().toLowerCase()
    if (!query) return ALL_ICON_NAMES
    return ALL_ICON_NAMES.map((k) => ({ k, s: score(k, query) })).filter((r) => r.s !== Infinity)
      .sort((a, b) => a.s - b.s).map((r) => r.k)
  })
  const shown = $derived(all.slice(0, CAP))
</script>

<div class="fixed inset-0 z-50 grid place-items-center" style="background:rgba(0,0,0,.55)" onclick={onclose} role="presentation">
  <div class="w-[480px] max-h-[72vh] rounded-2xl border border-line bg-card overflow-hidden flex flex-col"
    style="box-shadow:0 30px 70px rgba(0,0,0,.5)" onclick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
    <div class="p-3 border-b border-line">
      <!-- svelte-ignore a11y_autofocus -->
      <input autofocus bind:value={q} placeholder="Search 1,682 Iconoir icons…  (e.g. cloud, rocket, graph)"
        class="w-full bg-paper border border-line rounded-lg px-3 py-2 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_70%,var(--color-line))]" />
    </div>
    <div class="overflow-y-auto p-3">
      {#if shown.length}
        <div class="grid grid-cols-9 gap-1.5">
          {#each shown as key (key)}
            <button title={key} onclick={() => onpick(key)}
              class="aspect-square rounded-lg grid place-items-center hoverwash [&>svg]:w-[19px] [&>svg]:h-[19px]
                {value === key ? 'ring-1 ring-[color-mix(in_srgb,var(--color-ink)_35%,transparent)] bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''}"
              style="color:{color}">{@html iconSvgByName(key, 19)}</button>
          {/each}
        </div>
      {:else}
        <div class="text-dim text-[13px] text-center py-8">No icons match “{q}”.</div>
      {/if}
    </div>
    <div class="px-3 py-2 border-t border-line text-dim text-[11px] flex justify-between">
      <span>{all.length} match{all.length === 1 ? '' : 'es'}{all.length > CAP ? ` · showing ${CAP}` : ''}</span>
      <span>Color is set by kind</span>
    </div>
  </div>
</div>
