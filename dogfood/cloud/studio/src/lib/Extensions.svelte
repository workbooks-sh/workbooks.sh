<script>
  // The Extensions browser — a live view over the Open VSX Registry (open-vsx.org), the vendor-neutral
  // marketplace (Theia/Gitpod/VSCodium use it; MS's own marketplace forbids third-party clients). It calls
  // dock.ext.search/get — REAL public REST today. "Install" is the seam to the emulated extension host: a
  // VSIX is untrusted JS, so the real path compiles it to wasm and runs it in the sandbox against a `vscode`
  // shim mapped onto the Dock (see registry/ide-workbench.work). Here it records intent + reads as installed.
  import { dock } from './dock/index.js'
  import { iconSvgByName } from './icons.js'

  let query = $state('')
  let results = $state([])
  let loading = $state(false)
  let error = $state(null)
  let installed = $state(new Set())
  let timer

  async function search(q) {
    loading = true; error = null
    try { results = await dock.ext.search(q || 'workbooks', 24) }
    catch (e) { error = 'Open VSX unreachable'; results = [] }
    finally { loading = false }
  }
  function onInput(e) {
    query = e.target.value
    clearTimeout(timer)
    timer = setTimeout(() => search(query), 300)
  }
  function install(ext) { installed = new Set(installed).add(ext.namespace + '.' + ext.name) }
  const isInstalled = (ext) => installed.has(ext.namespace + '.' + ext.name)
  const fmt = (n) => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(n || 0)

  $effect(() => { search('') }) // initial popular list
</script>

<div class="h-full flex flex-col bg-paper min-w-0">
  <!-- search header -->
  <div class="flex-none px-3 pt-3 pb-2">
    <div class="flex items-center gap-2 h-[34px] px-2.5 rounded-lg border border-line" style="background:var(--color-well)">
      <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('search', 15)}</span>
      <input value={query} oninput={onInput} placeholder="Search Open VSX…" spellcheck="false"
        class="flex-1 min-w-0 bg-transparent border-0 focus:outline-none text-[13px]" style="color:var(--color-ink)" />
    </div>
    <div class="flex items-center gap-1.5 mt-2 px-0.5 text-[10.5px] uppercase tracking-wider text-dim/70">
      <span class="grid place-items-center text-bloomd [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('puzzle', 12)}</span>
      open-vsx.org · marketplace
    </div>
  </div>

  <div class="flex-1 min-h-0 overflow-y-auto px-2 pb-3">
    {#if loading}
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
            <div class="flex items-center gap-1.5">
              <span class="text-[13px] font-medium text-ink truncate">{ext.displayName}</span>
              <span class="text-[11px] text-dim flex-none">v{ext.version}</span>
            </div>
            <div class="text-[11.5px] text-dim truncate">{ext.description || ext.namespace}</div>
            <div class="flex items-center gap-3 mt-1.5">
              <span class="flex items-center gap-1 text-[10.5px] text-dim/80 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('download', 11)}{fmt(ext.downloads)}</span>
              {#if ext.rating}<span class="flex items-center gap-1 text-[10.5px] text-dim/80 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('star', 11)}{ext.rating.toFixed(1)}</span>{/if}
              <span class="text-[10.5px] text-dim/60 font-mono truncate">{ext.namespace}</span>
              <span class="flex-1"></span>
              {#if isInstalled(ext)}
                <span class="flex items-center gap-1 text-[11px] text-bloomd [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('check-circle', 12)}Installed</span>
              {:else}
                <button onclick={() => install(ext)}
                  class="px-2 py-[3px] rounded-md text-[11px] font-medium" style="background:var(--color-bloom);color:var(--color-well)">Install</button>
              {/if}
            </div>
          </div>
        </div>
      {/each}
    {/if}
  </div>
</div>
