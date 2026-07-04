<script>
  // The Files IDE file-tree. Lives in the sidebar column (under the DNA bar); selecting a file drives
  // the shared fsUi state that the editor pane reads. Branded green glyph for .work, vscode glyphs else.
  import { fileTree, fsUi, openFile, createFile, renameFile, deleteFile, expandFolder } from './fs.svelte.js'
  import { iconSvgByName } from './icons.js'
  import { vsIcon, fileIconName, isWorkFile } from './file-icons.js'
  import ImportMenu from './ImportMenu.svelte'
  // showHeader=false lets a host (the Code workbench) supply its own chrome and reuse just the tree.
  let { showHeader = true } = $props()
  let importing = $state(false)

  // ── right-click context menu (New file / New folder / Rename / Delete) + inline rename ──────────
  let ctx = $state({ open: false, x: 0, y: 0, node: null })
  let editing = $state(null) // the node being inline-renamed
  let editVal = $state('')
  function openCtx(e, node) { e.preventDefault(); e.stopPropagation(); ctx = { open: true, x: e.clientX, y: e.clientY, node } }

  // a new item lands inside the right-clicked folder; on a file it lands in that file's folder (or root).
  function findParent(target, nodes = fileTree) {
    for (const n of nodes) if (n.children) {
      if (n.children.includes(target)) return n
      const p = findParent(target, n.children); if (p) return p
    }
    return null
  }
  const parentFor = (node) => !node ? null : node.type === 'folder' ? node : findParent(node)

  function startRename(node) { editing = node; editVal = node.name }
  function commitRename() { if (editing) { renameFile(editing, editVal); editing = null } }
  function cancelRename() { editing = null }

  function ctxNew(isFolder) {
    const parent = parentFor(ctx.node)
    if (parent) parent.open = true
    const node = createFile(parent, isFolder ? 'new-folder' : 'untitled.work', isFolder)
    ctx.open = false
    startRename(node) // drop straight into inline rename so the default name is editable
  }
  function ctxDelete() { if (ctx.node) deleteFile(ctx.node); ctx.open = false }
  const closeCtx = () => { ctx.open = false }
</script>

<svelte:window onclick={closeCtx} onkeydown={(e) => { if (e.key === 'Escape') { closeCtx(); cancelRename() } }} />

<div class="h-full flex flex-col bg-paper {showHeader ? 'border-r border-line' : ''} min-w-0">
  {#if showHeader}
    <div class="flex items-center gap-2 px-3.5 h-[46px] flex-none mt-2.5 border-b border-line">
      <span class="font-display font-semibold text-[17px] tracking-tight flex-1">Files</span>
      <button onclick={() => (importing = true)} class="w-[28px] h-[28px] rounded-lg grid place-items-center text-dim hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]" title="Add files — import a directory or GitHub repo">{@html iconSvgByName('plus', 15)}</button>
    </div>
  {/if}

  {#if importing}<ImportMenu onClose={() => (importing = false)} />{/if}
  <div class="flex-1 overflow-y-auto py-1.5 text-[13px]">
    {#each fileTree as node}{@render row(node, 0)}{/each}
  </div>
</div>

<!-- recursive tree row -->
{#snippet row(node, depth)}
  {#if node.type === 'folder'}
    <button onclick={() => expandFolder(node)} oncontextmenu={(e) => openCtx(e, node)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash text-ink/90"
      style="padding-left:{depth * 14 + 8}px">
      <span class="grid place-items-center text-dim transition-transform duration-100 [&>svg]:w-[11px] [&>svg]:h-[11px]" style="transform:rotate({node.open ? 90 : 0}deg)">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </span>
      <!-- a github-linked subtree carries the material GitHub folder glyph; local folders stay default -->
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html vsIcon(node.github ? (node.open ? 'folder-type-github-opened' : 'folder-type-github') : (node.open ? 'default-folder-opened' : 'default-folder'), 16)}</span>
      {#if editing === node}{@render nameInput()}{:else}<span class="truncate">{node.name}</span>{/if}
      <!-- the folder icon already says "GitHub"; the right side just carries the tracked branch. -->
      {#if node.github}
        <span class="ml-auto flex-none flex items-center gap-1 pr-1 text-[10px] font-mono text-dim/55 [&>svg]:w-[11px] [&>svg]:h-[11px]"
          title="Linked subtree · github.com/{node.github} · branch {node.branch}">{@html iconSvgByName('git-branch', 11)}{node.branch}</span>
      {/if}
    </button>
    {#if node.open}
      {#each node.children || [] as child}{@render row(child, depth + 1)}{/each}
    {/if}
  {:else}
    <button onclick={() => openFile(node)} oncontextmenu={(e) => openCtx(e, node)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash {fsUi.active === node ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] text-ink' : 'text-ink/80'}"
      style="padding-left:{depth * 14 + 22}px">
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style={isWorkFile(node.name) ? 'color:var(--color-bloomd)' : ''}>
        {#if isWorkFile(node.name)}{@html iconSvgByName('journal-page', 16)}{:else}{@html vsIcon(fileIconName(node.name), 16)}{/if}
      </span>
      {#if editing === node}{@render nameInput()}{:else}<span class="truncate">{node.name}</span>{/if}
    </button>
  {/if}
{/snippet}

<!-- inline rename input — reused on file + folder rows -->
{#snippet nameInput()}
  <!-- svelte-ignore a11y_autofocus -->
  <input bind:value={editVal} autofocus
    onclick={(e) => e.stopPropagation()}
    onkeydown={(e) => { e.stopPropagation(); if (e.key === 'Enter') commitRename(); else if (e.key === 'Escape') cancelRename() }}
    onblur={commitRename}
    class="flex-1 min-w-0 bg-paper border border-[var(--color-sky)] rounded px-1 py-0 text-[13px] text-ink focus:outline-none" />
{/snippet}

<!-- right-click context menu -->
{#if ctx.open}
  <div class="fixed z-[70] min-w-[166px] rounded-xl border border-line bg-card py-1.5"
    style="left:{ctx.x}px; top:{ctx.y}px; box-shadow:0 18px 40px rgba(0,0,0,.4)"
    onclick={(e) => e.stopPropagation()} role="menu" tabindex="-1">
    <div class="px-3 py-1 text-[10.5px] font-mono uppercase tracking-wider text-dim/70 truncate">{ctx.node?.name}</div>
    <button onclick={() => ctxNew(false)} role="menuitem"
      class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13px] hoverwash [&>span>svg]:w-[14px] [&>span>svg]:h-[14px]">
      <span class="grid place-items-center text-dim">{@html iconSvgByName('page-plus', 14)}</span> New file
    </button>
    <button onclick={() => ctxNew(true)} role="menuitem"
      class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13px] hoverwash [&>span>svg]:w-[14px] [&>span>svg]:h-[14px]">
      <span class="grid place-items-center text-dim">{@html iconSvgByName('folder-plus', 14)}</span> New folder
    </button>
    <button onclick={() => { startRename(ctx.node); ctx.open = false }} role="menuitem"
      class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13px] hoverwash [&>span>svg]:w-[14px] [&>span>svg]:h-[14px]">
      <span class="grid place-items-center text-dim">{@html iconSvgByName('edit-pencil', 14)}</span> Rename
    </button>
    <div class="my-1 mx-3 border-t border-line"></div>
    <button onclick={ctxDelete} role="menuitem"
      class="flex items-center gap-2.5 w-full text-left px-3 py-[7px] text-[13px] hoverwash [&>span>svg]:w-[14px] [&>span>svg]:h-[14px]"
      style="color:var(--color-fuchsia)">
      <span class="grid place-items-center">{@html iconSvgByName('trash', 14)}</span> Delete
    </button>
  </div>
{/if}
