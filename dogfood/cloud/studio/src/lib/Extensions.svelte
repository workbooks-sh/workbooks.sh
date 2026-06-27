<script>
  // The Extensions browser — a live view over the Open VSX Registry (open-vsx.org), the vendor-neutral
  // marketplace. Mounted in BOTH the Code workbench panel AND the Toolkits "Extensions" layer; both read the
  // ONE shared registry (extensions.svelte.js). An extension is a 4th toolkit kind: a VSIX compiled to wasm,
  // run against the `vscode` shim mapped onto the Dock — so its contributions are Dock capabilities, reachable
  // by the editor AND by agents/apps. LICENSE is confirmed (dock.ext.license) at Add time and gates enabling,
  // because WE redistribute it as a shared capability (vs a user installing into their own editor).
  import { dock } from './dock/index.js'
  import { extensions, licenseStatus, licenseOk } from './extensions.svelte.js'
  import { EXTENSION_COUNT } from './extensions.count.js'
  import { iconSvgByName } from './icons.js'

  let query = $state('')
  let results = $state([])
  let loading = $state(false)
  let error = $state(null)
  let busy = $state(null) // id being license-checked
  let mode = $state('search') // 'search' (live API, rich cards) | 'all' (full local manifest, complete)
  let manifest = $state(null) // lazy-loaded full index (14,985)
  let timer

  const installed = $derived(extensions.all())

  // full-manifest filter — complete (not capped at the API's 10k deep-paging limit). Lazy-loads the ~1.5MB
  // index on first use, then filters in-memory by id.
  async function ensureManifest() {
    if (manifest) return manifest
    loading = true
    const mod = await import('./extensions.generated.js')
    manifest = mod.extensionManifest
    loading = false
    return manifest
  }
  const allFiltered = $derived(mode === 'all' && manifest
    ? (query.trim() ? manifest.filter((e) => e.id.toLowerCase().includes(query.toLowerCase())) : manifest).slice(0, 200)
    : [])

  async function search(q) {
    loading = true; error = null
    try { results = await dock.ext.search(q || 'workbooks', 24) }
    catch (e) { error = 'Open VSX unreachable'; results = [] }
    finally { loading = false }
  }
  function onInput(e) { query = e.target.value; if (mode === 'search') { clearTimeout(timer); timer = setTimeout(() => search(query), 300) } }
  async function setMode(m) { mode = m; if (m === 'all') await ensureManifest() }

  // Add = CONFIRM license (detail fetch) then register in the shared store. Permissive → enabled; else added
  // but gated (needs review) so it can be seen but not run as a shared capability.
  async function add(ext) {
    const id = ext.namespace + '.' + ext.name
    busy = id
    try { ext.license = ext.license || await dock.ext.license(ext.namespace, ext.name) } catch {}
    extensions.add(ext)
    busy = null
  }
  const isAdded = (ext) => extensions.added(ext.namespace + '.' + ext.name)
  const fmt = (n) => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(n || 0)

  $effect(() => { search('') })
</script>

<div class="h-full flex flex-col bg-paper min-w-0">
  <div class="flex-none px-3 pt-3 pb-2">
    <div class="flex items-center gap-2 h-[34px] px-2.5 rounded-lg border border-line" style="background:var(--color-well)">
      <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('search', 15)}</span>
      <input value={query} oninput={onInput} placeholder={mode === 'all' ? 'Filter all 14,985…' : 'Search Open VSX…'} spellcheck="false"
        class="flex-1 min-w-0 bg-transparent border-0 focus:outline-none text-[13px]" style="color:var(--color-ink)" />
    </div>
    <div class="flex items-center gap-2 mt-2 px-0.5">
      <span class="flex items-center gap-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">
        <span class="grid place-items-center text-bloomd [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('puzzle', 12)}</span>
        open-vsx · license-gated
      </span>
      <span class="flex-1"></span>
      <!-- search (rich, live) vs all (the COMPLETE sitemap manifest, filtered locally — not capped at 10k) -->
      <button onclick={() => setMode('search')} class="text-[11px] px-2 py-0.5 rounded-md {mode === 'search' ? 'text-ink bg-card border border-line' : 'text-dim'}">Search</button>
      <button onclick={() => setMode('all')} class="text-[11px] px-2 py-0.5 rounded-md {mode === 'all' ? 'text-ink bg-card border border-line' : 'text-dim'}">All {EXTENSION_COUNT.toLocaleString()}</button>
    </div>
  </div>

  <div class="flex-1 min-h-0 overflow-y-auto px-2 pb-3">
    <!-- ── Added (the shared registry — built-ins + license-confirmed VSX, usable across the editor/agents/apps) ── -->
    {#if installed.length}
      <div class="px-2 pt-1 pb-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">Added · shared capabilities</div>
      {#each installed as e}
        {@const ls = licenseStatus(e.license)}
        <div class="flex gap-2.5 p-2 rounded-lg">
          <div class="w-[34px] h-[34px] flex-none rounded-lg grid place-items-center"
            style="background:color-mix(in srgb,var(--color-bloom) 16%,transparent);color:var(--color-bloom)">
            <span class="[&>svg]:w-[17px] [&>svg]:h-[17px]">{@html iconSvgByName(e.source === 'builtin' ? 'sparks' : 'puzzle', 17)}</span>
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0">
              <span class="text-[13px] font-medium text-ink truncate min-w-0">{e.displayName}</span>
              {#if e.source === 'builtin'}<span class="flex-none whitespace-nowrap text-[10px] px-1.5 py-px rounded-full" style="background:color-mix(in srgb,var(--color-bloom) 16%,transparent);color:var(--color-bloomd)">built-in</span>{/if}
              <span class="flex-none whitespace-nowrap text-[10px] px-1.5 py-px rounded-full" title={ls.note}
                style="background:color-mix(in srgb,var(--color-{ls.tone}) 16%,transparent);color:var(--color-{ls.tone})">{ls.label}</span>
            </div>
            <div class="text-[10.5px] font-mono text-dim/60 truncate">{e.id}</div>
            <div class="flex items-center gap-2 mt-1.5">
              <span class="flex-1"></span>
              {#if ls.ok}
                <button onclick={() => extensions.setEnabled(e.id, !e.enabled)}
                  class="px-2 py-[3px] rounded-md text-[11px] border border-line {e.enabled ? 'text-ink' : 'text-dim'}"
                  title="Enable / disable as a shared capability">{e.enabled ? 'Enabled' : 'Disabled'}</button>
              {:else}
                <span class="text-[10.5px]" style="color:var(--color-amber)" title={ls.note}>license review needed</span>
              {/if}
              {#if e.source !== 'builtin'}<button onclick={() => extensions.remove(e.id)} class="px-1.5 py-[3px] rounded-md text-[11px] text-dim hoverwash" title="Remove">✕</button>{/if}
            </div>
          </div>
        </div>
      {/each}
      <div class="px-2 pt-3 pb-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">Marketplace</div>
    {/if}

    {#if mode === 'all'}
      <!-- the COMPLETE registry (sitemap manifest), filtered locally — leaner rows (id + repo); Add still
           confirms license via the live detail endpoint. Capped at 200 rendered for perf. -->
      {#if loading}
        <div class="px-2 py-6 text-center text-dim text-[12.5px] animate-pulse">loading full index…</div>
      {:else}
        <div class="px-2 pb-1.5 text-[10.5px] text-dim/70">{query.trim() ? `${allFiltered.length}${allFiltered.length >= 200 ? '+' : ''} match` : `${EXTENSION_COUNT.toLocaleString()} extensions — showing first 200`}</div>
        {#each allFiltered as e}
          {@const id = e.id}
          <div class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg hoverwash">
            <span class="grid place-items-center text-dim flex-none [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('box-iso', 14)}</span>
            <div class="min-w-0 flex-1">
              <div class="text-[12.5px] text-ink font-mono truncate">{id}</div>
              {#if e.repo}<div class="text-[10.5px] text-dim/60 truncate">{e.repo.replace('https://github.com/', '')}</div>{/if}
            </div>
            {#if extensions.added(id)}
              <span class="flex-none text-[11px] text-bloomd">✓</span>
            {:else}
              <button onclick={() => add({ namespace: e.ns, name: e.name, displayName: e.name, version: '', license: null })}
                disabled={busy === id} class="flex-none px-2 py-[2px] rounded-md text-[10.5px] font-medium disabled:opacity-50" style="background:var(--color-bloom);color:var(--color-well)">{busy === id ? '…' : 'Add'}</button>
            {/if}
          </div>
        {/each}
      {/if}
    {:else if loading}
      <div class="px-2 py-6 text-center text-dim text-[12.5px] animate-pulse">searching…</div>
    {:else if error}
      <div class="px-2 py-6 text-center text-[12.5px]" style="color:var(--color-bad)">{error}</div>
    {:else if !results.length}
      <div class="px-2 py-6 text-center text-dim text-[12.5px]">no extensions</div>
    {:else}
      {#each results as ext}
        <div class="flex gap-2.5 p-2 rounded-lg hoverwash">
          <div class="w-[34px] h-[34px] flex-none rounded-lg overflow-hidden grid place-items-center"
            style="background:color-mix(in srgb,var(--color-ink) 6%,transparent)">
            {#if ext.icon}<img src={ext.icon} alt="" class="w-full h-full object-cover" />
            {:else}<span class="text-dim [&>svg]:w-[18px] [&>svg]:h-[18px]">{@html iconSvgByName('box-iso', 18)}</span>{/if}
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0">
              <span class="text-[13px] font-medium text-ink truncate min-w-0">{ext.displayName}</span>
              <span class="text-[11px] text-dim flex-none">v{ext.version}</span>
            </div>
            <div class="text-[11.5px] text-dim truncate">{ext.description || ext.namespace}</div>
            <div class="flex items-center gap-2.5 mt-1.5 min-w-0">
              <span class="flex-none flex items-center gap-1 text-[10.5px] text-dim/80 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('download', 11)}{fmt(ext.downloads)}</span>
              {#if ext.rating}<span class="flex-none flex items-center gap-1 text-[10.5px] text-dim/80 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('star', 11)}{ext.rating.toFixed(1)}</span>{/if}
              <span class="text-[10.5px] text-dim/60 font-mono truncate min-w-0 flex-1">{ext.namespace}</span>
              {#if isAdded(ext)}
                <span class="flex-none flex items-center gap-1 text-[11px] text-bloomd [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('check-circle', 12)}Added</span>
              {:else}
                <button onclick={() => add(ext)} disabled={busy === ext.namespace + '.' + ext.name}
                  class="flex-none px-2 py-[3px] rounded-md text-[11px] font-medium disabled:opacity-50" style="background:var(--color-bloom);color:var(--color-well)">{busy === ext.namespace + '.' + ext.name ? 'checking…' : 'Add'}</button>
              {/if}
            </div>
          </div>
        </div>
      {/each}
    {/if}
  </div>
</div>
