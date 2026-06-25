<script>
  import { workspaces, surfacesFor, foldersFor, addSurface, addFolder, moveToFolder, ui, KIND_ORDER, hasContents, contentsOf,
    dms, openDMWith, avatarOf, people, personByName, isGroupDM } from './data.svelte.js'
  import { ICO, iconSvg, iconSvgByName, KIND_COLOR, dbFormat } from './icons.js'
  import ProfileCard from './ProfileCard.svelte'
  import CreateModal from './CreateModal.svelte'

  // Each WORKSPACE is a Slack-style collapsible group; its surfaces (channels/apps/agents/workflows)
  // live inside, ordered by kind. Surfaces can optionally nest inside FOLDERS (drag to move).
  // all workspaces start collapsed on load (expand by clicking the header / caret)
  let collapsed = $state(Object.fromEntries(workspaces.map((w) => [w.id, true])))
  let expanded = $state({}) // app row -> show pages
  let openFolders = $state({})
  let dragId = $state(null)
  let dropTarget = $state(null) // folder id or `top:<wsId>` highlighted while dragging
  let menu = $state({ open: false, wsId: null, folder: null, global: false, x: 0, y: 0 })
  let creator = $state({ open: false, kind: null })
  function openCreator(kind) { menu.open = false; creator = { open: true, kind } }
  let dmCollapsed = $state(false)
  // new-message popover: fixed-positioned (so the sidebar's overflow can't clip it), multi-select to
  // build a group DM. {open,x,y} + a selection set keyed by person name.
  let dmMenu = $state({ open: false, x: 0, y: 0 })
  let dmPick = $state({})
  let dmSearch = $state('')
  const dmResults = () => {
    const q = dmSearch.trim().toLowerCase()
    return people.filter((p) => !q || p.name.toLowerCase().includes(q) || (p.role || '').toLowerCase().includes(q))
  }

  // presence dot color for a DM's person
  const PRESENCE = { active: 'var(--color-mint)', away: 'var(--color-cream)', offline: 'var(--color-line)' }
  const presenceOf = (name) => PRESENCE[personByName(name)?.status] || PRESENCE.offline

  function openDmMenu(e) {
    e.stopPropagation()
    const r = e.currentTarget.getBoundingClientRect()
    dmPick = {}; dmSearch = ''
    dmMenu = { open: true, x: r.right, y: r.top }
  }
  const dmPicked = () => people.filter((p) => dmPick[p.name]).map((p) => p.name)
  function startDm() {
    const sel = dmPicked()
    if (sel.length) { openDMWith(sel); dmMenu.open = false }
  }

  // workspaces are grouped by ACCESS SCOPE into plain gray labeled sections (no per-row color/badge,
  // no divider icon) — the per-kind colors inside each workspace stay the signal. The scope shows as
  // the row's LEAD glyph (lock / # / shield). Admin (root) sorts last and never leads.
  const SCOPES = [
    { id: 'shared', label: 'Shared', icon: 'globe' },
    { id: 'private', label: 'Private', icon: 'lock' },
    { id: 'admin', label: 'Admin', icon: 'shield' }
  ]
  // explicit w.scope wins (lets a TEAM workspace be private without being personal); else derive.
  const scopeOf = (w) => w.scope || (w.personal ? 'private' : w.admin ? 'admin' : 'shared')
  const wsInScope = (sid) => workspaces.filter((w) => scopeOf(w) === sid)

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
    { kind: 'app', label: 'App', icon: 'app-window' },
    { kind: 'database', label: 'Database', icon: 'database' }
  ]
  function openMenu(e, wsId, folder = null, global = false) {
    e.stopPropagation()
    const r = e.currentTarget.getBoundingClientRect()
    menu = { open: true, wsId, folder, global, x: r.left, y: r.bottom + 4 }
  }
  function create(kind) {
    const ws = menu.wsId
    collapsed[ws] = false
    if (kind === 'folder') { const f = addFolder(ws); openFolders[f.id] = true }
    else { addSurface(kind, ws, menu.folder); if (menu.folder) openFolders[menu.folder] = true }
    menu.open = false
  }

  // ── drag a surface onto a folder (or back to top level) ───────────────────────────────────────
  function onDrop(fid) { if (dragId != null) moveToFolder(dragId, fid); dragId = null; dropTarget = null }
</script>

<svelte:window onclick={() => { menu.open = false; dmMenu.open = false }} />

<aside class="w-[264px] h-full bg-paper border-r border-line flex flex-col min-w-0 relative">
  <!-- sidebar header (mirrors .sidehd: 46px, Franie 17px title) -->
  <div class="flex items-center gap-1 px-3.5 h-[46px] flex-none">
    <span class="flex-1 font-display font-semibold text-[17px] tracking-tight">Studio</span>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="Search">{@html ICO.search}</button>
    <button class="w-[30px] h-[30px] rounded-lg grid place-items-center text-dim hoverwash" title="New"
      onclick={(e) => openMenu(e, ui.workspace || workspaces[0].id, null, true)}>{@html ICO.plus}</button>
  </div>

  <nav class="flex-1 overflow-y-auto px-1.5 pb-3 pt-1">
    {#each SCOPES as sc, si}
      {@const list = wsInScope(sc.id)}
      {#if list.length}
        <!-- scope divider: gray glyph (lock / globe / shield) + label + rule to the right edge. The
             glyph lives ONLY here — rows below carry no lead, since the grouping already says scope. -->
        <div class="flex items-center gap-2 px-2 pb-1 {si === 0 ? 'pt-1' : 'pt-3'}">
          <span class="grid place-items-center text-dim/70 [&>svg]:w-[11px] [&>svg]:h-[11px]">{@html iconSvgByName(sc.icon, 11)}</span>
          <span class="text-[9.5px] font-mono uppercase tracking-wider text-dim/70">{sc.label}</span>
          <span class="flex-1 h-px bg-line"></span>
        </div>
      {/if}
    {#each list as w}
      {@const top = topItems(w.id)}
      {@const wfolders = foldersFor(w.id)}
      <div class="mb-0.5">
        <!-- workspace group header — # lead, emoji + name, hover +, collapse caret on the far right -->
        <div class="group/ws flex items-center gap-2 w-full px-2 py-[7px] rounded-lg hoverwash text-ink font-semibold text-[11.5px]
            {dropTarget === 'top:' + w.id ? 'ring-1 ring-[var(--color-sky)]' : ''}"
          role="button" tabindex="0"
          ondragover={(e) => { if (dragId != null) { e.preventDefault(); dropTarget = 'top:' + w.id } }}
          ondrop={(e) => { e.preventDefault(); onDrop(null) }}>
          <button class="flex items-center gap-2 flex-1 min-w-0" onclick={() => (collapsed[w.id] = !collapsed[w.id])}>
            <!-- no lead glyph: the scope divider above already says private / shared / admin -->
            <span class="flex-none text-dim grid place-items-center [&>svg]:w-[15px] [&>svg]:h-[15px]">{@html iconSvg(w.icon)}</span>
            <span class="flex-1 text-left truncate">{w.name}</span>
          </button>
          <!-- hover-revealed workspace actions: settings (gear) + add (+) -->
          <button title="{w.name} settings" onclick={(e) => { e.stopPropagation(); ui.wsSettings = w.id; ui.settingsOpen = true; ui.mediaOpen = false }}
            class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity opacity-0 group-hover/ws:opacity-100 [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('settings', 14)}</button>
          <button title="Add to {w.name}" onclick={(e) => openMenu(e, w.id)}
            class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity opacity-0 group-hover/ws:opacity-100 [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)}</button>
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
                  <!-- hover + : add an item INTO this folder -->
                  <button title="Add to {f.name}" onclick={(e) => openMenu(e, w.id, f.id)}
                    class="flex-none grid place-items-center text-dim hover:text-ink opacity-0 group-hover:opacity-100 transition-opacity [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)}</button>
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
    {/each}
  </nav>

  <!-- ── Direct Messages — pinned at the bottom, separate from workspaces ───────────────────────── -->
  <div class="flex-none border-t border-line px-1.5 pt-2 pb-2.5 max-h-[40%] overflow-y-auto">
    <div class="group/dm flex items-center gap-2 px-2 py-[5px] rounded-lg hoverwash text-dim font-semibold text-[11px] uppercase tracking-wider">
      <button class="flex items-center gap-1.5 flex-1 min-w-0" onclick={() => (dmCollapsed = !dmCollapsed)}>
        <span class="transition-transform duration-150" style="transform:rotate({dmCollapsed ? 0 : 90}deg)">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
        </span>
        <span class="truncate">Direct Messages</span>
      </button>
      <button title="New message" onclick={openDmMenu}
        class="flex-none grid place-items-center text-dim hover:text-ink [&>svg]:w-[14px] [&>svg]:h-[14px]">{@html iconSvgByName('plus', 14)}</button>
    </div>

    {#if !dmCollapsed}
      {#each dms as d}
        {@const group = isGroupDM(d)}
        <div class="group flex items-center gap-2.5 px-2 py-[6px] rounded-lg cursor-pointer text-[13.5px] hoverwash
            {ui.surfaceId === d.id ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)]' : ''}"
          onclick={() => openDMWith(d.members)} role="button" tabindex="0">
          {#if group}
            <!-- group: two overlapping avatars -->
            <span class="relative flex-none w-[22px] h-[22px]">
              <img src={avatarOf(d.members[0], 'human')} alt={d.members[0]} class="absolute left-0 top-0 w-[15px] h-[15px] rounded-[5px] object-cover border border-paper" />
              <img src={avatarOf(d.members[1], 'human')} alt={d.members[1]} class="absolute right-0 bottom-0 w-[15px] h-[15px] rounded-[5px] object-cover border border-paper" />
            </span>
          {:else}
            <span class="relative flex-none">
              <img src={avatarOf(d.members[0], 'human')} alt={d.members[0]} class="w-[22px] h-[22px] rounded-md object-cover border border-line" />
              <span class="absolute -right-0.5 -bottom-0.5 w-2.5 h-2.5 rounded-full border-2 border-paper" style="background:{presenceOf(d.members[0])}"></span>
            </span>
          {/if}
          <span class="flex-1 truncate {d.unread ? 'font-semibold text-ink' : 'text-ink/85'}">{d.members.join(', ')}</span>
          {#if d.unread}
            <span class="min-w-[18px] h-[18px] px-1.5 rounded-full grid place-items-center text-[11px] font-bold font-mono"
              style="background:var(--color-fuchsia);color:#10120f">{d.unread}</span>
          {/if}
        </div>
      {/each}
    {/if}
  </div>

  <ProfileCard />
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
      style="color:{s.kind === 'database' ? dbFormat(s.payload?.format).color : KIND_COLOR[s.kind]}">{@html iconSvg(s.icon, s.kind)}</span>
    <span class="flex-1 truncate {s.unread ? 'font-semibold text-ink' : 'text-ink/85'}">{s.name}{#if s.private}<span class="text-dim text-[11px]"> · private</span>{/if}</span>
    {#if hasContents(s)}
      <!-- unified contents affordance: a drawer that opens (pages + data volumes) -->
      <button title="Contents"
        class="flex-none grid place-items-center text-dim hover:text-ink transition-opacity
          [&>svg]:w-[16px] [&>svg]:h-[16px] {expanded[s.id] ? 'opacity-100 text-ink' : 'opacity-0 group-hover:opacity-100'}"
        onclick={(e) => { e.stopPropagation(); expanded[s.id] = !expanded[s.id] }}>{@html iconSvgByName(expanded[s.id] ? 'archive' : 'drawer', 16)}</button>
    {/if}
    {#if s.unread}
      <span class="min-w-[18px] h-[18px] px-1.5 rounded-full grid place-items-center text-[11px] font-bold font-mono"
        style="background:var(--color-blue);color:#10120f">{s.unread}</span>
    {/if}
  </div>
  {#if expanded[s.id]}
    {@const c = contentsOf(s)}
    <div class="ml-[19px] pl-2 border-l border-line py-0.5">
      {#if c.pages.length}
        <div class="px-2 pt-1 pb-0.5 text-[9.5px] font-mono uppercase tracking-wider text-dim/60">Pages</div>
        {#each c.pages as p}
          <div class="px-2 py-[3px] rounded-md text-[12.5px] text-dim hoverwash cursor-pointer">{p.label}<span class="opacity-50"> · {p.path}</span></div>
        {/each}
      {/if}
      {#if c.volumes.length}
        <div class="px-2 pt-1 pb-0.5 text-[9.5px] font-mono uppercase tracking-wider text-dim/60">Data</div>
        {#each c.volumes as v}
          {@const F = dbFormat(v.format)}
          <div class="flex items-center gap-2 px-2 py-[3px] rounded-md text-[12.5px] text-dim hoverwash cursor-pointer [&>svg]:w-[12px] [&>svg]:h-[12px]">
            <span class="grid place-items-center" style="color:{F.color}">{@html iconSvgByName(F.icon, 12)}</span>
            <span class="flex-1 truncate">{v.name}</span>
            <span class="text-[9px] font-mono uppercase tracking-wide opacity-60" style="color:{F.color}">{F.label}</span>
            {#if v.rows != null}<span class="opacity-50 font-mono text-[11px]">{v.rows}</span>{/if}
          </div>
        {/each}
      {/if}
    </div>
  {/if}
{/snippet}

<!-- New / Add context menu -->
{#if menu.open}
  <div class="fixed z-50 min-w-[178px] rounded-xl border border-line bg-card py-1.5"
    style="left:{menu.x}px; top:{menu.y}px; box-shadow:0 18px 40px rgba(0,0,0,.4)"
    onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
    {#if menu.global}
      <!-- global create: a workspace, or a surface whose destination you pick in the modal -->
      <button onclick={() => openCreator('workspace')} role="menuitem"
        class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13.5px] font-medium hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
        <span class="grid place-items-center text-ink">{@html iconSvgByName('folder-plus', 15)}</span>
        New workspace
      </button>
      <div class="my-1 mx-3 border-t border-line"></div>
      <div class="px-3 py-1 text-[10.5px] font-mono uppercase tracking-wider text-dim/70">New item</div>
    {:else}
      <div class="px-3 py-1 text-[10.5px] font-mono uppercase tracking-wider text-dim/70">
        New in {menu.folder ? (foldersFor(menu.wsId).find((f) => f.id === menu.folder)?.name) : workspaces.find((w) => w.id === menu.wsId)?.name}
      </div>
    {/if}
    {#each NEW_KINDS as k}
      <button onclick={() => menu.global ? openCreator(k.kind) : create(k.kind)} role="menuitem"
        class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13.5px] hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
        <span class="grid place-items-center" style="color:{KIND_COLOR[k.kind]}">{@html iconSvgByName(k.icon, 15)}</span>
        {k.label}
      </button>
    {/each}
    {#if !menu.global && !menu.folder}
      <div class="my-1 mx-3 border-t border-line"></div>
      <button onclick={() => create('folder')} role="menuitem"
        class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13.5px] hoverwash [&>span>svg]:w-[15px] [&>span>svg]:h-[15px]">
        <span class="grid place-items-center text-dim">{@html iconSvgByName('folder', 15)}</span>
        Folder
      </button>
    {/if}
  </div>
{/if}

{#if creator.open}
  <CreateModal kind={creator.kind} onClose={() => (creator.open = false)} />
{/if}

<!-- New message / group-DM builder — fixed so the sidebar's overflow can't clip it -->
{#if dmMenu.open}
  {@const sel = dmPicked()}
  <div class="fixed z-[60] w-[230px] rounded-xl border border-line bg-card py-1.5"
    style="left:{dmMenu.x}px; top:{dmMenu.y}px; transform:translate(-100%,-100%); box-shadow:0 18px 44px rgba(0,0,0,.45)"
    onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
    <div class="px-2 pt-1 pb-1.5">
      <div class="flex items-center gap-2 bg-paper border border-line rounded-lg px-2.5 py-1.5 [&>svg]:w-[13px] [&>svg]:h-[13px] text-dim">
        {@html iconSvgByName('search', 13)}
        <!-- svelte-ignore a11y_autofocus -->
        <input bind:value={dmSearch} placeholder="Search team…" autofocus
          class="flex-1 bg-transparent text-[13px] text-ink focus:outline-none placeholder:text-dim/60" />
      </div>
    </div>
    <div class="max-h-[220px] overflow-y-auto py-0.5">
      {#each dmResults() as p}
        <button onclick={() => (dmPick[p.name] = !dmPick[p.name])} role="menuitemcheckbox" aria-checked={!!dmPick[p.name]}
          class="flex items-center gap-2.5 w-full text-left px-3 py-[6px] text-[13px] hoverwash">
          <img src={avatarOf(p.name, 'human')} alt={p.name} class="w-5 h-5 rounded-md object-cover border border-line" />
          <span class="flex-1 text-ink">{p.name}<span class="text-dim text-[11px]"> · {p.role}</span></span>
          <span class="flex-none w-[16px] h-[16px] rounded-[5px] grid place-items-center border {dmPick[p.name] ? 'text-paper' : 'border-line'}"
            style={dmPick[p.name] ? 'background:var(--color-fuchsia);border-color:var(--color-fuchsia)' : ''}>
            {#if dmPick[p.name]}<span class="[&>svg]:w-[11px] [&>svg]:h-[11px] grid place-items-center" style="color:#10120f">{@html iconSvgByName('check', 11)}</span>{/if}
          </span>
        </button>
      {/each}
      {#if !dmResults().length}<div class="px-3 py-2 text-[12.5px] text-dim/60 italic">No one matches “{dmSearch}”</div>{/if}
    </div>
    <div class="mx-3 my-1 border-t border-line"></div>
    <div class="px-2">
      <button onclick={startDm} disabled={!sel.length}
        class="w-full text-center text-[13px] font-medium px-3 py-2 rounded-lg {sel.length ? 'text-ink bg-[color-mix(in_srgb,var(--color-fuchsia)_30%,transparent)] hover:bg-[color-mix(in_srgb,var(--color-fuchsia)_45%,transparent)]' : 'text-dim/50 cursor-not-allowed'}">
        {sel.length > 1 ? `Start group · ${sel.length}` : sel.length ? `Message ${sel[0]}` : 'Select people'}
      </button>
    </div>
  </div>
{/if}
