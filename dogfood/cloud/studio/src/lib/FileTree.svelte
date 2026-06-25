<script>
  // The Files IDE file-tree. Lives in the sidebar column (under the DNA bar); selecting a file drives
  // the shared fsUi state that the editor pane reads. Branded green glyph for .work, vscode glyphs else.
  import { fileTree, fsUi, openFile } from './fs.svelte.js'
  import { vsIcon, fileIconName, isWorkFile, iconSvgByName } from './icons.js'
</script>

<div class="h-full flex flex-col bg-paper border-r border-line min-w-0">
  <div class="flex items-center gap-2 px-3.5 h-[46px] flex-none mt-2.5 border-b border-line">
    <span class="font-display font-semibold text-[17px] tracking-tight flex-1">Files</span>
    <button class="w-[28px] h-[28px] rounded-lg grid place-items-center text-dim hoverwash [&>svg]:w-[15px] [&>svg]:h-[15px]" title="New file">{@html iconSvgByName('plus', 15)}</button>
  </div>
  <div class="flex-1 overflow-y-auto py-1.5 text-[13px]">
    {#each fileTree as node}{@render row(node, 0)}{/each}
  </div>
</div>

<!-- recursive tree row -->
{#snippet row(node, depth)}
  {#if node.type === 'folder'}
    <button onclick={() => (node.open = !node.open)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash text-ink/90"
      style="padding-left:{depth * 14 + 8}px">
      <span class="grid place-items-center text-dim transition-transform duration-100 [&>svg]:w-[11px] [&>svg]:h-[11px]" style="transform:rotate({node.open ? 90 : 0}deg)">
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </span>
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]">{@html vsIcon(node.open ? 'default-folder-opened' : 'default-folder', 16)}</span>
      <span class="truncate">{node.name}</span>
    </button>
    {#if node.open}
      {#each node.children as child}{@render row(child, depth + 1)}{/each}
    {/if}
  {:else}
    <button onclick={() => openFile(node)}
      class="flex items-center gap-1.5 w-full text-left py-[3px] pr-2 hoverwash {fsUi.active === node ? '!bg-[color-mix(in_srgb,var(--color-ink)_8%,transparent)] text-ink' : 'text-ink/80'}"
      style="padding-left:{depth * 14 + 22}px">
      <span class="grid place-items-center [&>svg]:w-[16px] [&>svg]:h-[16px]" style={isWorkFile(node.name) ? 'color:var(--color-bloomd)' : ''}>
        {#if isWorkFile(node.name)}{@html iconSvgByName('journal-page', 16)}{:else}{@html vsIcon(fileIconName(node.name), 16)}{/if}
      </span>
      <span class="truncate">{node.name}</span>
    </button>
  {/if}
{/snippet}
