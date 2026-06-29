<script>
  // a database surface = a container of TABLES. Switch tables with the dropdown; the grid shows rows.
  import { ui, surfaceById, isRootWs } from './data.svelte.js'
  import { auth } from './auth.svelte.js'
  import { loadTables } from './db.js'
  import { iconSvgByName, KIND_COLOR, dbFormat } from './icons.js'

  let { surfaceId } = $props()
  const s = $derived(surfaceById(surfaceId))
  const fmt = $derived(dbFormat(s?.payload?.format))
  const isJson = $derived(s?.payload?.format === 'json')
  // LIVE: a database surface shows its workspace's REAL data resources (/cloud/data + rows); offline keeps
  // the mock payload tables. Additive — null until loaded, then it takes over.
  let realTables = $state(null)
  $effect(() => {
    const sf = surfaceById(surfaceId)
    realTables = null
    if (sf && sf.kind === 'database' && !auth.offline) loadTables(sf.workspace).then((t) => { if (t && t.length) realTables = t })
  })
  const tables = $derived(realTables ?? (s?.payload?.tables || []))
  const documents = $derived(s?.payload?.documents || [])
  let ti = $state(0)
  let pick = $state(false)
  const t = $derived(tables[ti])

  // inline cell editing: which cell (row,col) is open as an <input>
  let edit = $state(null) // { r, c } | null
  const startEdit = (r, c) => (edit = { r, c })
  const commit = () => (edit = null)
  const onKey = (e) => { if (e.key === 'Enter' || e.key === 'Escape') { e.preventDefault(); commit() } }

  function addRow() {
    if (!t) return
    t.rows.push(t.cols.map(() => '')) // one blank per column — $state proxy re-renders
  }
  function deleteRow(r) {
    if (!t) return
    t.rows.splice(r, 1)
    if (edit && edit.r === r) edit = null
  }
</script>

{#if s}
  <section class="flex flex-col min-w-0 h-full bg-paper">
    <header class="flex items-center gap-2.5 px-4 h-[57px] border-b border-line flex-none">
      <span class="grid place-items-center [&>svg]:w-[18px] [&>svg]:h-[18px]" style="color:{fmt.color}">{@html iconSvgByName(s.icon, 18)}</span>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-display font-semibold leading-tight">{s.name}</span>
          <!-- format badge: the shape + engine this database is -->
          <span class="text-[9.5px] font-mono uppercase tracking-wide px-1.5 py-0.5 rounded" style="color:{fmt.color};background:color-mix(in srgb,{fmt.color} 15%,transparent)">{fmt.label}</span>
          {#if isRootWs(s.workspace)}
            <span class="text-[9.5px] font-mono uppercase tracking-wide px-1.5 py-0.5 rounded" style="color:var(--color-violet);background:color-mix(in srgb,var(--color-violet) 18%,transparent)" title="Org-scoped · highest permission tier">org · highest scope</span>
          {/if}
        </div>
        <div class="text-dim text-[12.5px] truncate">{s.purpose || 'Database'} · {isJson ? `${documents.length} documents` : `${tables.length} tables`}</div>
      </div>

      <!-- table switcher (grid formats only) -->
      <div class="relative ml-2" class:hidden={isJson}>
        <button onclick={() => (pick = !pick)} class="flex items-center gap-2 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[13px] [&>svg]:h-[13px]">
          <span class="grid place-items-center" style="color:{fmt.color}">{@html iconSvgByName('table', 13)}</span>
          {t?.name}
          <span class="text-dim grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('nav-arrow-down', 13)}</span>
        </button>
        {#if pick}
          <div class="absolute left-0 top-full mt-1.5 z-30 min-w-[180px] rounded-xl border border-line bg-card py-1.5" style="box-shadow:0 16px 36px rgba(0,0,0,.4)">
            {#each tables as tb, i}
              <button onclick={() => { ti = i; pick = false }} class="flex items-center gap-2.5 w-full text-left px-3 py-2 text-[13px] hoverwash {i === ti ? 'text-ink' : 'text-dim'} [&>svg]:w-[13px] [&>svg]:h-[13px]">
                <span class="grid place-items-center" style="color:{fmt.color}">{@html iconSvgByName('table', 13)}</span>
                <span class="flex-1">{tb.name}</span>
                <span class="text-dim/60 font-mono text-[11px]">{tb.rows.length}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>

      <span class="flex-1"></span>
      <button onclick={addRow} class:hidden={isJson} class="flex items-center gap-1.5 text-[13px] px-3 py-1.5 rounded-lg border border-line hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)} Row</button>
    </header>

    <div class="flex-1 overflow-auto" style="background:var(--color-well)">
      {#if isJson}
        <!-- JSON store → records, not a grid -->
        <div class="max-w-2xl mx-auto px-5 py-5 flex flex-col gap-2.5">
          {#each documents as doc}
            <div class="rounded-xl border border-line bg-paper px-4 py-3 font-mono text-[12.5px]">
              <div class="text-dim mb-1.5">{'{'}</div>
              {#each Object.entries(doc) as [k, v]}
                <div class="pl-4"><span style="color:var(--color-sky)">"{k}"</span><span class="text-dim">: </span><span style="color:var(--color-peach)">"{v}"</span><span class="text-dim">,</span></div>
              {/each}
              <div class="text-dim mt-1.5">{'}'}</div>
            </div>
          {/each}
        </div>
      {:else if t}
        <table class="text-[13px] border-separate border-spacing-0 min-w-full">
          <thead class="sticky top-0">
            <tr>
              <th class="w-10 px-3 py-2.5 text-left text-dim font-mono text-[11px] border-b border-line bg-paper">#</th>
              {#each t.cols as col}
                <th class="px-3 py-2.5 text-left font-medium text-dim font-mono text-[11px] uppercase tracking-wide border-b border-l border-line bg-paper whitespace-nowrap">{col}</th>
              {/each}
              <th class="w-8 border-b border-line bg-paper"></th>
            </tr>
          </thead>
          <tbody>
            {#each t.rows as row, ri}
              <tr class="group hover:bg-[color-mix(in_srgb,var(--color-ink)_3%,transparent)]">
                <td class="px-3 py-2 text-dim/60 font-mono text-[11px] border-b border-line">{ri + 1}</td>
                {#each t.cols as _, ci}
                  <td class="border-b border-l border-line whitespace-nowrap p-0">
                    {#if edit && edit.r === ri && edit.c === ci}
                      <!-- svelte-ignore a11y_autofocus -->
                      <input class="w-full bg-card px-3 py-2 focus:outline-none focus:bg-[color-mix(in_srgb,var(--color-sky)_8%,transparent)]"
                        bind:value={row[ci]} onblur={commit} onkeydown={onKey} autofocus />
                    {:else}
                      <button class="w-full text-left px-3 py-2 cursor-text hover:bg-[color-mix(in_srgb,var(--color-ink)_4%,transparent)]"
                        onclick={() => startEdit(ri, ci)}>{row[ci] || ' '}</button>
                    {/if}
                  </td>
                {/each}
                <td class="border-b border-line text-center align-middle">
                  <button title="Delete row" onclick={() => deleteRow(ri)}
                    class="opacity-0 group-hover:opacity-100 transition text-dim hover:text-[var(--color-bad,#d66)] grid place-items-center w-full [&>svg]:w-3.5 [&>svg]:h-3.5">{@html iconSvgByName('xmark', 14)}</button>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </div>
  </section>
{/if}
