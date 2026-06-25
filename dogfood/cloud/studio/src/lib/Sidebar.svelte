<script>
  import { workspaces, surfacesFor, foldersFor, addSurface, addFolder, moveToFolder, ui, KIND_ORDER } from './data.svelte.js'
  import { ICO, iconSvg, iconSvgByName, KIND_COLOR } from './icons.js'

  // Each WORKSPACE is a Slack-style collapsible group; its surfaces (channels/apps/agents/workflows)
  // live inside, ordered by kind. Surfaces can optionally nest inside FOLDERS (drag to move).
  let collapsed = $state({})
  let expanded = $state({}) // app row -> show pages
  let openFolders = $state({})
  let dragId = $state(null)
  let dropTarget = $state(null) // folder id or `top:<wsId>` highlighted while dragging
  let menu = $state({ open: false, wsId: null, x: 0, y: 0 })

  const kindRank = (k) => KIND_ORDER.indexOf(k)
  const byKind = (list) => [...list].sort((a, b) => kindRank(a.kind) - kindRank(b.kind))
  const topItems = (wsId) => byKind(surfacesFor(wsId).filter((s) => !s.folder))
  const folderItems = (wsId, fid) => byKind(surfacesFor(wsId).filter((s) => s.folder === fid))

  function pick(s) { ui.surfaceId = s.id; ui.workspace = s.workspace; s.unread = 0 }
  const wsUnread = (wsId) => surfacesFor(wsId).reduce((n, s) => n + (s.unread || 0), 0)

  // ── the New / + context menu ──────────────────────────────────────────────────────────────────
  const NEW_KINDS = [
    { kind: 'chat', label: 'Channel', icon: 'chat-bubble' },
    { kind: 'agent', label: 'Agent', icon: 'cpu' },
    { kind: 'workflow', label: 'Workflow', icon: 'git-fork' },
    { kind: 'app', label: 'App', icon: 'app-window' }
  ]
  function openMenu(e, wsId) {
    e.stopPropagation()
    const r = e.currentTarget.getBoundingClientRect()
    menu = { open: true, wsId, x: r.left, y: r.bottom + 4 }
  }
  function create(kind) {
    const ws = menu.wsId
    collapsed[ws] = false
    if (kind === 'folder') { const f = addFolder(ws); openFolders[f.id] = true }
    else addSurface(kind, ws)
    menu.open = false
  }

  // ── drag a surface onto a folder (or back to top level) ───────────────────────────────────────
  function onDrop(fid) { if (dragId != null) moveToFolder(dragId, fid); dragId = null; dropTarget = null }
</script>

<svelte:window onclick={() => (menu.open = false)} />

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0">
  <!-- sidebar header (mirrors .sidehd: 46px, Franie 17px title) -->
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Studio</span>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="Search">{@html ICO.search}</button>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="New"
      onclick={(e) => openMenu(e, ui.workspace || workspaces[0].id)}>{@html ICO.plus}</button>
  </div>

  <nav class="flex-1 overflow-y-auto px-1.5 pb-3 pt-1">
    {#each workspaces as w}
      {@const top = topItems(w.id)}
      {@const wfolders = foldersFor(w.id)}
      {@const unread = wsUnread(w.id)}
      <div class="mb-0.5">
        <!-- workspace group header — # lead, emoji + name, hover +, collapse caret on the far right -->
        <div class="group/ws flex items-center gap-2 w-full px-2 py-[7px] rounded-lg hoverwash text-ink font-semibold text-[11.5px]
            {dropTarget === 'top:' + w.id ? 'ring-1 ring-[var(--color-sky)]' : ''}"
          role="button" tabindex="0"
          ondragover={(e) => { if (dragId != null) { e.preventDefault(); dropTarget = 'top:' + w.id } }}
          ondrop={(e) => { e.preventDefault(); onDrop(null) }}>
          <button class="flex items-center gap-2 flex-1 min-w-0" onclick={() => (collapsed[w.id] = !collapsed[w.id])}>
            {#if w.personal}
              <span class="flex-none text-dim grid place-items-center [&>svg]:w-[13px] [&>svg]:h-[13px]" title="Private to you">{@html iconSvgByName('lock', 13)}</span>
            {:else}
              <span class="flex-none text-dim font-mono text-[13px]">#</span>
            {/if}
            <span class="flex-none text-dim grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvg(w.icon)}</span>
            <span class="flex-1 text-left truncate">{w.name}</span>
          </button>
          <!-- hover-revealed + : add an item to THIS workspace -->
          <button title="Add to {w.name}" onclick={(e) => openMenu(e, w.id)}
            class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity opacity-0 group-hover/ws:opacity-100 [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)}</button>
          {#if unread}<span class="flex-none text-dim font-mono text-[10.5px]">{unread}</span>{/if}
          <button class="flex-none text-dim transition-transform duration-150" style="transform:rotate({collapsed[w.id] ? 0 : 90}deg)"
            onclick={() => (collapsed[w.id] = !collapsed[w.id])}>
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
        </div>

        {#if !collapsed[w.id]}
          <!-- tree guide-bar + indent so the workspace's items read as nested under it -->
          <div class="ml-[15px] pl-2 border-l border-line">
            {#each top as s}{@render surfaceRow(s)}{/each}

            <!-- folders: a gray folder row that holds dragged-in surfaces -->
            {#each wfolders as f}
              {@const fitems = folderItems(w.id, f.id)}
              <div class="rounded-lg {dropTarget === f.id ? 'ring-1 ring-[var(--color-sky)] bg-[color-mix(in_srgb,var(--color-sky)_8%,transparent)]' : ''}"
                role="button" tabindex="0"
                ondragover={(e) => { if (dragId != null) { e.preventDefault(); dropTarget = f.id } }}
                ondragleave={() => { if (dropTarget === f.id) dropTarget = null }}
                ondrop={(e) => { e.preventDefault(); onDrop(f.id) }}>
                <div class="group flex items-center gap-2.5 pl-2 pr-2 py-[6px] rounded-lg cursor-pointer text-[13.5px] hoverwash"
                  onclick={() => (openFolders[f.id] = !openFolders[f.id])} role="button" tabindex="0">
                  <span class="w-[16px] flex-none grid place-items-center text-dim [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvgByName(openFolders[f.id] ? 'folder' : 'folder', 15)}</span>
                  <span class="flex-1 truncate text-ink/85">{f.name}</span>
                  <span class="flex-none text-dim font-mono text-[10.5px]">{fitems.length}</span>
                  <span class="flex-none text-dim transition-transform duration-150" style="transform:rotate({openFolders[f.id] ? 90 : 0}deg)">
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
                  </span>
                </div>
                {#if openFolders[f.id]}
                  <div class="ml-[15px] pl-2 border-l border-line">
                    {#each fitems as s}{@render surfaceRow(s)}{/each}
                    {#if !fitems.length}<div class="px-2 py-1.5 text-dim/60 text-[12px] italic">Drag items here</div>{/if}
                  </div>
                {/if}
              </div>
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </nav>
</aside>

<!-- a single surface row — reused at top level and inside folders -->
{#snippet surfaceRow(s)}
  <div class="group flex items-center gap-2.5 pl-2 pr-2 py-[6px] rounded-lg cursor-pointer text-[13.5px] hoverwash
      {ui.surfaceId === s.id ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''} {dragId === s.id ? 'opacity-40' : ''}"
    onclick={() => pick(s)} role="button" tabindex="0"
    draggable="true"
    ondragstart={(e) => { dragId = s.id; e.dataTransfer.effectAllowed = 'move' }}
    ondragend={() => { dragId = null; dropTarget = null }}>
    <span class="w-[16px] flex-none grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]"
      style="color:{KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
    <span class="flex-1 truncate {s.unread ? 'font-semibold text-ink' : 'text-ink/85'}">{s.name}{#if s.private}<span class="text-dim text-[11px]"> · private</span>{/if}</span>
    {#if s.kind === 'app'}
      <!-- pages affordance: hover-revealed (or sticky while open), NOT a second caret -->
      <button title="Open pages"
        class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity
          [&>svg]:w-[15px] [&>svg]:h-[15px] {expanded[s.id] ? 'opacity-100 text-ink' : 'opacity-0 group-hover:opacity-100'}"
        onclick={(e) => { e.stopPropagation(); expanded[s.id] = !expanded[s.id] }}>{@html ICO.tree}</button>
    {/if}
    {#if s.unread}
      <span class="min-w-[18px] h-[18px] px-1.5 rounded-full grid place-items-center text-[11px] font-bold font-mono"
        style="background:var(--color-blue);color:#10120f">{s.unread}</span>
    {/if}
  </div>
  {#if s.kind === 'app' && expanded[s.id]}
    <div class="ml-[19px] pl-2 border-l border-line">
      {#each s.payload.pages as p}
        <div class="px-2 py-[3px] rounded-md text-[12.5px] text-dim hoverwash cursor-pointer">{p.label}<span class="opacity-50"> · {p.path}</span></div>
      {/each}
    </div>
  {/if}
{/snippet}

<!-- New / Add context menu -->
{#if menu.open}
  <div class="fixed z-50 min-w-[178px] rounded-xl border border-line bg-card py-1.5"
    style="left:{menu.x}px; top:{menu.y}px; box-shadow:0 18px 40px rgba(0,0,0,.4)"
    onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
    <div class="px-3 py-1 text-[10.5px] font-mono uppercase tracking-wider text-dim/70">New in {workspaces.find((w) => w.id === menu.wsId)?.name}</div>
    {#each NEW_KINDS as k}
      <button onclick={() => create(k.kind)} role="menuitem"
        class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13.5px] hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
        <span class="grid place-items-center" style="color:{KIND_COLOR[k.kind]}">{@html iconSvgByName(k.icon, 15)}</span>
        {k.label}
      </button>
    {/each}
    <div class="my-1 mx-3 border-t border-line"></div>
    <button onclick={() => create('folder')} role="menuitem"
      class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13.5px] hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
      <span class="grid place-items-center text-dim">{@html iconSvgByName('folder', 15)}</span>
      Folder
    </button>
  </div>
{/if}
