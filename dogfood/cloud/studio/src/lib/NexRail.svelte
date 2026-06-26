<script>
  import { ui, nexuses, RAIL_SECS } from './data.svelte.js'
  import { ICO } from './icons.js'

  const nex = $derived(nexuses.find((n) => n.id === ui.nexus))

  // component-local affordances
  let extraNexuses = $state([])           // locally-added nexuses (demo)
  let newNexusOpen = $state(false)
  let newNexusName = $state('')
  let toolkitsOpen = $state(false)
  const DEMO_TOOLKITS = ['fmt · formatter', 'http · fetch kit', 'sqlite · store', 'crypto · hashing']

  function addNexus() {
    const name = newNexusName.trim()
    if (!name) return
    extraNexuses = [...extraNexuses, { id: `local-${Date.now()}`, name, icon: '✦' }]
    newNexusName = ''
    newNexusOpen = false
  }
</script>

<!-- bg-well offsets the rail a shade from the paper sidebar so the two columns read apart
     (well = darker than paper in dark mode, brighter than the cream paper in light mode) -->
<div class="flex flex-col items-center w-[70px] h-full bg-well border-r border-line select-none pb-2">
  <!-- nexus dropdown trigger -->
  <div class="relative pt-2.5 pb-1.5">
    <button class="nextile" class:on={ui.nexMenu} title={nex.name} onclick={(e) => { e.stopPropagation(); ui.nexMenu = !ui.nexMenu }}>
      <span class="text-[26px] leading-none">{nex.icon}</span>
      <span class="absolute -right-[3px] -bottom-[3px] w-4 h-4 rounded-full bg-paper border border-line grid place-items-center text-dim">
        <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"
          style="transform:rotate(90deg)"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </span>
    </button>
    {#if ui.nexMenu}
      <div class="absolute left-[54px] top-1 z-20 w-52 rounded-xl border border-line bg-card shadow-xl p-1.5"
        style="box-shadow:0 18px 40px rgba(0,0,0,.35)" onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
        <div class="px-2.5 py-1.5 text-[10px] font-mono uppercase tracking-widest text-dim">Switch nexus</div>
        {#each nexuses as n}
          <button class="flex items-center gap-2.5 w-full text-left px-2.5 py-2 rounded-lg hoverwash"
            class:font-semibold={n.id === ui.nexus}
            onclick={() => { ui.nexus = n.id; ui.nexMenu = false }}>
            <span class="text-lg">{n.icon}</span><span class="flex-1">{n.name}</span>
            {#if n.id === ui.nexus}<span class="text-xs" style="color:var(--color-mint)">●</span>{/if}
          </button>
        {/each}
        {#each extraNexuses as n}
          <button class="flex items-center gap-2.5 w-full text-left px-2.5 py-2 rounded-lg hoverwash"
            class:font-semibold={n.id === ui.nexus}
            onclick={() => { ui.nexus = n.id; ui.nexMenu = false }}>
            <span class="text-lg">{n.icon}</span><span class="flex-1">{n.name}</span>
            {#if n.id === ui.nexus}<span class="text-xs" style="color:var(--color-mint)">●</span>{/if}
          </button>
        {/each}
        <div class="h-px bg-line my-1.5 mx-1"></div>
        {#if newNexusOpen}
          <div class="px-1.5 py-1">
            <!-- svelte-ignore a11y_autofocus -->
            <input autofocus bind:value={newNexusName} placeholder="Nexus name…"
              onkeydown={(e) => { if (e.key === 'Enter') addNexus(); if (e.key === 'Escape') newNexusOpen = false }}
              class="w-full bg-paper border border-line rounded-lg px-2.5 py-1.5 text-[13px] focus:outline-none" />
            <div class="flex gap-1.5 mt-1.5">
              <button class="flex-1 text-[12px] px-2 py-1.5 rounded-lg text-ink bg-[color-mix(in_srgb,var(--color-mint)_30%,transparent)] hover:bg-[color-mix(in_srgb,var(--color-mint)_45%,transparent)]" onclick={addNexus}>Create</button>
              <button class="text-[12px] px-2 py-1.5 rounded-lg text-dim hoverwash" onclick={() => { newNexusOpen = false; newNexusName = '' }}>Cancel</button>
            </div>
          </div>
        {:else}
          <button class="flex items-center gap-2.5 w-full text-left px-2.5 py-2 rounded-lg hoverwash text-dim"
            onclick={() => (newNexusOpen = true)}>
            {@html ICO.plus}<span>New nexus…</span>
          </button>
        {/if}
      </div>
    {/if}
  </div>

  <div class="w-[26px] h-px bg-line my-1"></div>

  <!-- rail sections (icon-above-label) -->
  <nav class="flex flex-col gap-1.5 items-center w-full mt-1">
    {#each RAIL_SECS as sec}
      <button class="railsec flex flex-col items-center gap-1 w-[58px] py-[7px] rounded-xl cursor-pointer transition
          {ui.section === sec.id ? 'text-ink' : 'text-dim hover:text-ink'}"
        onclick={() => (ui.section = sec.id)}>
        <span class="rsico">{@html ICO[sec.icon]}</span>
        <span class="text-[11px] font-semibold">{sec.label}</span>
      </button>
    {/each}
  </nav>

  <div class="flex-1"></div>

  <!-- bottom group: Toolkits / You. Admin is no longer a rail console — it moved INTO Studio as the
       org-scoped "Admin" workspace (ROOT), so admin is built from the same surfaces as everything else. -->
  <div class="relative flex flex-col gap-1.5 items-center w-full pt-3 border-t border-line">
    <button class="railsec flex flex-col items-center gap-1 w-[58px] py-[7px] rounded-xl {toolkitsOpen ? 'text-ink' : 'text-dim hover:text-ink'}"
      onclick={(e) => { e.stopPropagation(); toolkitsOpen = !toolkitsOpen }}>
      <span class="rsico">{@html ICO.toolbox}</span><span class="text-[11px] font-semibold">Toolkits</span>
    </button>
    {#if toolkitsOpen}
      <div class="absolute left-[64px] bottom-2 z-20 w-52 rounded-xl border border-line bg-card shadow-xl p-1.5"
        style="box-shadow:0 18px 40px rgba(0,0,0,.35)" onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
        <div class="px-2.5 py-1.5 text-[10px] font-mono uppercase tracking-widest text-dim">Toolkits</div>
        {#each DEMO_TOOLKITS as t}
          <button class="flex items-center gap-2.5 w-full text-left px-2.5 py-2 rounded-lg hoverwash text-[13px]">
            <span class="text-dim">{@html ICO.toolbox}</span><span class="flex-1">{t}</span>
          </button>
        {/each}
      </div>
    {/if}
    <button class="railsec flex flex-col items-center gap-1 w-[58px] py-[7px] pb-2.5 rounded-xl text-dim hover:text-ink"
      onclick={() => { ui.settingsOpen = true; toolkitsOpen = false }}>
      <img src="https://i.pravatar.cc/72?u=shane" alt="You" class="w-[30px] h-[30px] rounded-[9px] object-cover border border-line" />
      <span class="text-[11px] font-semibold">You</span>
    </button>
  </div>
</div>
