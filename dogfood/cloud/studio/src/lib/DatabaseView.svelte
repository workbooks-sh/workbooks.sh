<script>
  // a database surface = a container of TABLES. Switch tables with the dropdown; the grid shows rows.
  import { ui, surfaceById } from './data.svelte.js'
  import { iconSvgByName, KIND_COLOR } from './icons.js'

  let { surfaceId } = $props()
  const s = $derived(surfaceById(surfaceId))
  const tables = $derived(s?.payload?.tables || [])
  let ti = $state(0)
  let pick = $state(false)
  const t = $derived(tables[ti])
</script>

{#if s}
  <section class="flex flex-col min-w-0 h-full bg-paper">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{KIND_COLOR.database}">{@html iconSvgByName(s.icon, 18)}</span>
      <div class="min-w-0">
        <div class="font-display font-semibold leading-tight">{s.name}</div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose || 'Database'} · {tables.length} tables</div>
      </div>

      <!-- table switcher -->
      <div class="relative ml-2">
        <button onclick={() => (pick = !pick)} class="flex items-center gap-2 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[13px] [&>svg]:h-[13px]">
          <span class="grid place-items-center" style="color:var(--color-blue)">{@html iconSvgByName('table', 13)}</span>
          {t?.name}
          <span class="text-dim grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('nav-arrow-down', 13)}</span>
        </button>
        {#if pick}
          <div class="absolute left-0 top-full mt-1.5 z-30 min-w-[180px] rounded-xl border border-line bg-card py-1.5" style="box-shadow:0 16px 36px rgba(0,0,0,.4)">
            {#each tables as tb, i}
              <button onclick={() => { ti = i; pick = false }} class="flex items-center gap-2.5 w-full text-left px-3 py-2 text-[13px] hoverwash {i === ti ? 'text-ink' : 'text-dim'} [&>svg]:w-[13px] [&>svg]:h-[13px]">
                <span class="grid place-items-center" style="color:var(--color-blue)">{@html iconSvgByName('table', 13)}</span>
                <span class="flex-1">{tb.name}</span>
                <span class="text-dim/60 font-mono text-[11px]">{tb.rows.length}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>

      <span class="flex-1"></span>
      <button class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)} Row</button>
    </header>

    <div class="flex-1 overflow-auto" style="background:var(--color-well)">
      {#if t}
        <table class="text-[13px] border-separate border-spacing-0 min-w-full">
          <thead class="sticky top-0">
            <tr>
              <th class="w-10 px-3 py-2.5 text-left text-dim font-mono text-[11px] border-b border-line bg-paper">#</th>
              {#each t.cols as col}
                <th class="px-3 py-2.5 text-left font-medium text-dim font-mono text-[11px] uppercase tracking-wide border-b border-l border-line bg-paper whitespace-nowrap">{col}</th>
              {/each}
            </tr>
          </thead>
          <tbody>
            {#each t.rows as row, ri}
              <tr class="hover:bg-[color-mix(in_srgb,var(--color-ink)_3%,transparent)]">
                <td class="px-3 py-2 text-dim/60 font-mono text-[11px] border-b border-line">{ri + 1}</td>
                {#each row as cell}
                  <td class="px-3 py-2 border-b border-l border-line whitespace-nowrap">{cell}</td>
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </div>
  </section>
{/if}
