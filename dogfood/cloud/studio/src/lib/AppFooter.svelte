<script>
  // The app-wide footer — a thin strip across the whole layout that surfaces ONLY what is genuinely live, every
  // item interactive IN PLACE: connected capabilities → an action popover; enabled extensions → a compact LIST
  // MENU (a capability WITH a view opens it in the persistent right-side aux panel — the MCP-App surface); the
  // branch → an environment switcher. No fake metrics; empty segments render nothing. Popovers close via a
  // transparent backdrop (Svelte-5 event delegation defeats stopPropagation against svelte:window).
  import { dock } from './dock/index.js'
  import { extensions, licenseStatus } from './extensions.svelte.js'
  import { extViews } from './dock/ext-host.js'
  import { vcsState, vcs } from './dock/vcs.svelte.js'
  import { activity } from './activity.svelte.js'
  import { ui } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  const connected = $derived(dock.nativecli.list().filter((c) => c.connected))
  const exts = $derived(extensions.all())
  const enabledCount = $derived(exts.filter((e) => e.enabled).length)
  const viewsByExt = $derived(Object.fromEntries(extViews().map((v) => [v.extId, v])))
  // favorited extensions that have a view → quick-launch icons, left of the extensions chip
  const favs = $derived(extensions.favorites().filter((e) => e.enabled && viewsByExt[e.id]))

  let pop = $state(null) // 'cap:<provider>' | 'branch' | 'ext' | null

  const isOpen = (k) => pop === k
  function toggle(k) { pop = pop === k ? null : k }
  function close() { pop = null }

  function useInTerminal() { close(); ui.section = 'code'; ui.wantTerminal = true }
  function disconnect(c) { close(); dock.shell.exec('disconnect ' + c.provider) }
  function pickBranch(b) { close(); vcs.checkout(b) }
  function openView(extId) { close(); ui.auxView = viewsByExt[extId]?.id || null }
</script>

{#if pop}<div class="fixed inset-0 z-[55]" onclick={close} role="presentation"></div>{/if}

<div class="h-full w-full flex items-center gap-3 px-3 text-[11px] border-t border-line select-none"
  style="background:var(--color-paper); color:var(--color-dim)">

  <span class="flex items-center gap-1.5" title="Emulated wasm runtime">
    <span class="w-[7px] h-[7px] rounded-full" style="background:var(--color-bloom)"></span>sandbox
  </span>

  {#if activity.inflight > 0}
    <span class="flex items-center gap-1.5 text-ink" title="Running">
      <span class="w-[6px] h-[6px] rounded-full animate-ping" style="background:var(--color-sky)"></span>
      <span class="font-mono">{activity.label || 'running'}</span>
    </span>
  {/if}

  <!-- connected capabilities -->
  {#each connected as c}
    <div class="relative">
      <button onclick={() => toggle('cap:' + c.provider)}
        class="flex items-center gap-1.5 px-1.5 h-[18px] rounded-md hover:text-ink hoverwash">
        <span class="w-[6px] h-[6px] rounded-full" style="background:var(--color-bloomd)"></span>{c.provider}
      </button>
      {#if isOpen('cap:' + c.provider)}
        <div class="absolute left-0 bottom-[24px] z-[70] min-w-[180px] rounded-xl border border-line p-1.5"
          style="background:var(--color-card); box-shadow:0 14px 36px rgba(0,0,0,.3)">
          <div class="px-2 py-1 text-[12px] text-ink font-medium">{c.provider}</div>
          <div class="px-2 pb-1.5 text-[10.5px] text-dim/70 font-mono">{c.bin} · {c.verbs.join(' ')}</div>
          <button onclick={useInTerminal} class="flex items-center gap-2 w-full text-left px-2 py-1.5 rounded-md text-[12px] text-ink hoverwash [&>svg]:w-[13px] [&>svg]:h-[13px]">{@html iconSvgByName('terminal', 13)} Use in terminal</button>
          <button onclick={() => disconnect(c)} class="w-full text-left px-2 py-1.5 rounded-md text-[12px] hoverwash" style="color:var(--color-bad)">Disconnect</button>
        </div>
      {/if}
    </div>
  {/each}

  <span class="flex-1"></span>

  <!-- favorited extension views — quick-launch icons, left of the extensions chip -->
  {#each favs as f}
    <button onclick={() => (ui.auxView = ui.auxView === viewsByExt[f.id].id ? null : viewsByExt[f.id].id)}
      title={f.displayName}
      class="w-[20px] h-[18px] grid place-items-center rounded-md hoverwash [&>svg]:w-[14px] [&>svg]:h-[14px] {ui.auxView === viewsByExt[f.id]?.id ? 'text-bloomd' : 'text-dim hover:text-ink'}">{@html iconSvgByName(viewsByExt[f.id].icon, 14)}</button>
  {/each}

  <!-- extensions (MCP servers are a type) — a compact LIST MENU; a view opens the right aux panel -->
  {#if exts.length}
    <div class="relative">
      <button onclick={() => toggle('ext')} title="Extensions"
        class="flex items-center gap-1.5 px-1.5 h-[18px] rounded-md hoverwash [&>svg]:w-[12px] [&>svg]:h-[12px] {isOpen('ext') ? 'text-ink' : 'hover:text-ink'}">
        {@html iconSvgByName('puzzle', 12)}{enabledCount}
      </button>
      {#if isOpen('ext')}
        <div class="absolute right-0 bottom-[24px] z-[70] w-[280px] rounded-xl border border-line p-1.5"
          style="background:var(--color-card); box-shadow:0 14px 36px rgba(0,0,0,.3)">
          <div class="px-2 py-1 flex items-center"><span class="text-[10px] uppercase tracking-wider text-dim/70 flex-1">Extensions</span><span class="text-[10px] text-dim/50">MCP servers are a type</span></div>
          {#each exts as e}
            {@const ls = licenseStatus(e.license)}
            {@const hasView = viewsByExt[e.id] && e.enabled}
            <div class="flex items-center gap-1.5 px-2 py-1.5 rounded-md hoverwash">
              <span class="grid place-items-center flex-none text-bloomd [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName(viewsByExt[e.id]?.icon || (e.source === 'builtin' ? 'sparks' : 'puzzle'), 14)}</span>
              <button onclick={() => hasView && openView(e.id)} class="text-[12.5px] text-ink truncate flex-1 min-w-0 text-left {hasView ? 'cursor-pointer hover:text-bloomd' : 'cursor-default'}">{e.displayName}</button>
              {#if hasView}
                <button onclick={() => extensions.toggleFavorite(e.id)} title="Favorite (pin to footer)"
                  class="flex-none grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px] {extensions.isFavorite(e.id) ? 'text-amber' : 'text-dim/50 hover:text-ink'}">{@html iconSvgByName(extensions.isFavorite(e.id) ? 'star-solid' : 'star', 13)}</button>
                <button onclick={() => openView(e.id)} class="flex-none text-[11px] px-1.5 py-[2px] rounded-md text-ink hoverwash border border-line">Open</button>
              {/if}
              {#if ls.ok}
                <button onclick={() => extensions.setEnabled(e.id, !e.enabled)} title="Enable / disable"
                  class="flex-none w-[26px] text-[11px] {e.enabled ? 'text-bloomd' : 'text-dim'}">{e.enabled ? 'on' : 'off'}</button>
              {:else}
                <span class="flex-none text-[10px]" style="color:var(--color-amber)">review</span>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/if}

  <span class="font-mono text-dim/80">{ui.workspace}</span>

  <!-- branch / environment switcher -->
  <div class="relative">
    <button onclick={() => toggle('branch')}
      class="flex items-center gap-1 font-mono hover:text-ink hoverwash px-1.5 h-[18px] rounded-md [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName('git-branch', 11)}{vcsState.branch}</button>
    {#if isOpen('branch')}
      <div class="absolute right-0 bottom-[24px] z-[70] min-w-[170px] rounded-xl border border-line p-1.5"
        style="background:var(--color-card); box-shadow:0 14px 36px rgba(0,0,0,.3)">
        <div class="px-2 py-1 text-[10px] uppercase tracking-wider text-dim/70">Branch · environment</div>
        {#each vcsState.branches as b}
          <button onclick={() => pickBranch(b)}
            class="flex items-center gap-2 w-full text-left px-2 py-1.5 rounded-md text-[12px] hoverwash {b === vcsState.branch ? 'text-ink' : 'text-dim'}">
            <span class="w-[6px] h-[6px] rounded-full flex-none" style="background:{b === vcsState.branch ? 'var(--color-bloomd)' : 'var(--color-line)'}"></span>
            <span class="font-mono flex-1">{b}</span>
            {#if b === vcsState.branch}<span class="text-bloomd text-[11px]">✓</span>{/if}
          </button>
        {/each}
      </div>
    {/if}
  </div>
</div>
