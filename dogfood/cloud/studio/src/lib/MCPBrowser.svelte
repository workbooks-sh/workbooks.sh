<script>
  // The MCP browser — the Toolkits "MCP" layer (replaces VS Code extensions). Browse the official MCP
  // registry (2,131 WASM-compatible servers — remote HTTP + npm/JS, no Python), install/enable/remove
  // (cloud-synced per nexus via /cloud/mcp), or add your own by URL/command. Catalog lazy-loads (738KB)
  // only when this opens, so it never bloats the main bundle.
  import { mcpState, loadCatalog, install, uninstall, setEnabled, isInstalled } from './mcp.svelte.js'
  import { runAction, askConfirm } from './adminkit.svelte.js'
  import { iconSvgByName } from './icons.js'
  import Pill from './Pill.svelte'

  let query = $state('')
  let adding = $state(false)
  let custom = $state({ name: '', transport: 'http', endpoint: '' })
  let busy = $state(null)

  $effect(() => { loadCatalog() })

  const installed = $derived(mcpState.installed)
  // catalog filtered by query; cap render for perf. Hide already-installed from the catalog list.
  const matches = $derived.by(() => {
    const cat = mcpState.catalog || []
    const q = query.trim().toLowerCase()
    const f = q ? cat.filter((e) => e.name.toLowerCase().includes(q) || e.id.toLowerCase().includes(q) || (e.description || '').toLowerCase().includes(q)) : cat
    return f.filter((e) => !isInstalled(e.id)).slice(0, 150)
  })
  const transportColor = (t) => t === 'http' ? 'var(--color-mint)' : 'var(--color-sky)'
  const transportLabel = (t) => t === 'http' ? 'remote' : 'local'

  async function doInstall(e) {
    busy = e.id
    await runAction(() => install(e), { success: `Installed ${e.name}` })
    busy = null
  }
  async function doUninstall(s) {
    if (await askConfirm({ title: `Remove ${s.name}?`, body: 'This MCP server is uninstalled from the nexus.', confirmLabel: 'Remove', danger: true }))
      await runAction(() => uninstall(s.sid), { success: `Removed ${s.name}` })
  }
  async function doToggle(s) { await runAction(() => setEnabled(s.sid, !s.enabled), {}) }
  async function doAddCustom() {
    if (!custom.name.trim() || !custom.endpoint.trim()) return
    busy = 'custom'
    const sid = 'custom/' + custom.name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-')
    const r = await runAction(() => install({ id: sid, name: custom.name.trim(), transport: custom.transport, endpoint: custom.endpoint.trim(), source: 'custom' }), { success: `Added ${custom.name.trim()}` })
    busy = null
    if (r) { custom = { name: '', transport: 'http', endpoint: '' }; adding = false }
  }
</script>

<div class="h-full flex flex-col bg-paper min-w-0">
  <div class="flex-none px-3 pt-3 pb-2">
    <div class="flex items-center gap-2 h-[34px] px-2.5 rounded-lg border border-line" style="background:var(--color-well)">
      <span class="grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName('search', 15)}</span>
      <input bind:value={query} placeholder="Search {(mcpState.catalog||[]).length.toLocaleString()} MCP servers…" spellcheck="false"
        class="flex-1 min-w-0 bg-transparent border-0 focus:outline-none text-[13px]" style="color:var(--color-ink)" />
    </div>
    <div class="flex items-center gap-2 mt-2 px-0.5">
      <span class="flex items-center gap-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">
        <span class="grid place-items-center text-bloomd [&>svg]:w-[12px] [&>svg]:h-[12px]">{@html iconSvgByName('box-iso', 12)}</span>
        model context protocol · runs in your nexus sandbox
      </span>
      <span class="flex-1"></span>
      <button onclick={() => (adding = !adding)} class="text-[11px] px-2 py-0.5 rounded-md border border-line text-dim hover:text-ink">{adding ? 'Cancel' : '+ Add server'}</button>
    </div>
    {#if adding}
      <div class="mt-2 p-2.5 rounded-lg border border-line flex flex-col gap-2" style="background:var(--color-card)">
        <input bind:value={custom.name} placeholder="Name" class="bg-paper border border-line rounded-md px-2.5 py-1.5 text-[12.5px] outline-none focus:border-ink" />
        <div class="flex gap-2">
          <select bind:value={custom.transport} class="bg-paper border border-line rounded-md px-2 py-1.5 text-[12.5px] outline-none">
            <option value="http">remote (HTTP)</option><option value="stdio">local (stdio→wasm)</option>
          </select>
          <input bind:value={custom.endpoint} placeholder={custom.transport === 'http' ? 'https://server/mcp' : 'npm-package or command'} class="flex-1 bg-paper border border-line rounded-md px-2.5 py-1.5 text-[12.5px] font-mono outline-none focus:border-ink" />
        </div>
        <button onclick={doAddCustom} disabled={busy === 'custom' || !custom.name.trim() || !custom.endpoint.trim()} class="self-end px-3 py-1.5 rounded-md text-[12.5px] font-medium disabled:opacity-40" style="background:var(--color-ink);color:var(--color-paper)">Add</button>
      </div>
    {/if}
  </div>

  <div class="flex-1 min-h-0 overflow-y-auto px-2 pb-3">
    <!-- installed -->
    {#if installed.length}
      <div class="px-2 pt-1 pb-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">Installed · {installed.length}</div>
      {#each installed as s}
        <div class="flex gap-2.5 p-2 rounded-lg">
          <div class="w-[34px] h-[34px] flex-none rounded-lg grid place-items-center" style="background:color-mix(in srgb,{transportColor(s.transport)} 16%,transparent);color:{transportColor(s.transport)}">
            <span class="[&>svg]:w-[17px] [&>svg]:h-[17px]">{@html iconSvgByName(s.transport === 'http' ? 'antenna' : 'box-iso', 17)}</span>
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0">
              <span class="text-[13px] font-medium text-ink truncate min-w-0">{s.name}</span>
              <Pill label={transportLabel(s.transport)} color={transportColor(s.transport)} />
              {#if s.source === 'custom'}<Pill label="custom" color="var(--color-dim)" />{/if}
            </div>
            <div class="text-[10.5px] font-mono text-dim/60 truncate">{s.endpoint || s.sid}</div>
            <div class="flex items-center gap-2 mt-1.5">
              <span class="flex-1"></span>
              <button onclick={() => doToggle(s)} class="px-2 py-[3px] rounded-md text-[11px] border border-line {s.enabled ? 'text-ink' : 'text-dim'}">{s.enabled ? 'Enabled' : 'Disabled'}</button>
              <button onclick={() => doUninstall(s)} class="px-1.5 py-[3px] rounded-md text-[11px] text-dim hover:text-[var(--color-bad)]" title="Remove">✕</button>
            </div>
          </div>
        </div>
      {/each}
      <div class="px-2 pt-3 pb-1.5 text-[10.5px] uppercase tracking-wider text-dim/70">Registry</div>
    {/if}

    <!-- catalog -->
    {#if mcpState.loading}
      <div class="px-2 py-6 text-center text-dim text-[12.5px] animate-pulse">loading catalog…</div>
    {:else if !matches.length}
      <div class="px-2 py-6 text-center text-dim text-[12.5px]">no matches</div>
    {:else}
      {#each matches as e}
        <div class="flex gap-2.5 p-2 rounded-lg hoverwash">
          <div class="w-[34px] h-[34px] flex-none rounded-lg grid place-items-center" style="background:color-mix(in srgb,var(--color-ink) 6%,transparent);color:{transportColor(e.transport)}">
            <span class="[&>svg]:w-[16px] [&>svg]:h-[16px]">{@html iconSvgByName(e.transport === 'http' ? 'antenna' : 'box-iso', 16)}</span>
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-1.5 min-w-0">
              <span class="text-[13px] font-medium text-ink truncate min-w-0">{e.name}</span>
              <Pill label={transportLabel(e.transport)} color={transportColor(e.transport)} />
            </div>
            <div class="text-[11.5px] text-dim truncate">{e.description || e.id}</div>
            <div class="flex items-center gap-2.5 mt-1.5 min-w-0">
              <span class="text-[10.5px] text-dim/60 font-mono truncate min-w-0 flex-1">{e.id}</span>
              <button onclick={() => doInstall(e)} disabled={busy === e.id}
                class="flex-none px-2 py-[3px] rounded-md text-[11px] font-medium disabled:opacity-50" style="background:var(--color-bloom);color:var(--color-well)">{busy === e.id ? '…' : 'Install'}</button>
            </div>
          </div>
        </div>
      {/each}
    {/if}
  </div>
</div>
