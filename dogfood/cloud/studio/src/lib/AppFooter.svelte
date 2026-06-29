<script>
  // The app-wide footer — a thin strip across the whole layout that surfaces ONLY what is genuinely live, every
  // item interactive IN PLACE: connected capabilities → an action popover; enabled extensions → a compact LIST
  // MENU (a capability WITH a view opens it in the persistent right-side aux panel — the MCP-App surface); the
  // branch → an environment switcher. No fake metrics; empty segments render nothing. Popovers close via a
  // transparent backdrop (Svelte-5 event delegation defeats stopPropagation against svelte:window).
  import { dock } from './dock/index.js'
  import { mcpState, setEnabled } from './mcp.svelte.js'
  import { vcsState, vcs, loadBranches } from './dock/vcs.svelte.js'
  import { activity } from './activity.svelte.js'
  import { ui } from './data.svelte.js'
  import { iconSvgByName } from './icons.js'

  const connected = $derived(dock.nativecli.list().filter((c) => c.connected))
  const servers = $derived(mcpState.installed)
  const enabledCount = $derived(servers.filter((s) => s.enabled).length)

  let pop = $state(null) // 'cap:<provider>' | 'branch' | 'mcp' | null

  const isOpen = (k) => pop === k
  function toggle(k) { pop = pop === k ? null : k }
  function close() { pop = null }

  function useInTerminal() { close(); ui.section = 'code'; ui.wantTerminal = true }
  function disconnect(c) { close(); dock.shell.exec('disconnect ' + c.provider) }
  function pickBranch(b) { close(); vcs.checkout(b) }
  // load the active workspace's REAL branches whenever the workspace changes
  $effect(() => { ui.workspace; loadBranches() })
  function manageMcp() { close(); ui.section = 'toolkits'; ui.toolkitsLayer = 'mcp'; ui.toolkitsView = 'all' }
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

  <!-- MCP servers — a compact LIST MENU (enable/disable in place; manage opens the Toolkits MCP layer) -->
  {#if servers.length}
    <div class="relative">
      <button onclick={() => toggle('mcp')} title="MCP servers"
        class="flex items-center gap-1.5 px-1.5 h-[18px] rounded-md hoverwash [&>svg]:w-[12px] [&>svg]:h-[12px] {isOpen('mcp') ? 'text-ink' : 'hover:text-ink'}">
        {@html iconSvgByName('antenna', 12)}{enabledCount}
      </button>
      {#if isOpen('mcp')}
        <div class="absolute right-0 bottom-[24px] z-[70] w-[280px] rounded-xl border border-line p-1.5"
          style="background:var(--color-card); box-shadow:0 14px 36px rgba(0,0,0,.3)">
          <div class="px-2 py-1 flex items-center"><span class="text-[10px] uppercase tracking-wider text-dim/70 flex-1">MCP servers</span><button onclick={manageMcp} class="text-[10px] text-dim/60 hover:text-ink">manage</button></div>
          {#each servers as s}
            <div class="flex items-center gap-1.5 px-2 py-1.5 rounded-md hoverwash">
              <span class="grid place-items-center flex-none [&>svg]:w-[14px] [&>svg]:h-[14px]" style="color:{s.transport === 'http' ? 'var(--color-mint)' : 'var(--color-sky)'}">{@html iconSvgByName(s.transport === 'http' ? 'antenna' : 'box-iso', 14)}</span>
              <span class="text-[12.5px] text-ink truncate flex-1 min-w-0">{s.name}</span>
              <button onclick={() => setEnabled(s.sid, !s.enabled)} title="Enable / disable"
                class="flex-none w-[26px] text-[11px] {s.enabled ? 'text-bloomd' : 'text-dim'}">{s.enabled ? 'on' : 'off'}</button>
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
