<!--
  FileTree — Claude Code style file system browser showing what's packaged
  inside a generated .workbook.html. Expandable folders. Click a file to
  preview its content/description in the right pane (caller-supplied).
-->
<script lang="ts">
  interface FileNode {
    name: string;
    kind: "file" | "dir";
    size?: string;
    note?: string;
    children?: FileNode[];
  }

  interface Props {
    root: FileNode;
    initiallyOpen?: string[]; // paths to expand by default
    onSelect?: (path: string, node: FileNode) => void;
  }

  let { root, initiallyOpen = [], onSelect }: Props = $props();

  let openPaths = $state(new Set(initiallyOpen));
  let selectedPath = $state<string | null>(null);

  function toggle(path: string) {
    if (openPaths.has(path)) openPaths.delete(path);
    else openPaths.add(path);
    openPaths = new Set(openPaths);
  }

  function select(path: string, node: FileNode) {
    selectedPath = path;
    onSelect?.(path, node);
  }
</script>

{#snippet row(node: FileNode, depth: number, path: string)}
  {@const isOpen = openPaths.has(path)}
  {@const isSelected = selectedPath === path}
  <button
    type="button"
    onclick={() => (node.kind === "dir" ? toggle(path) : select(path, node))}
    class="flex items-baseline w-full text-left px-2 py-1 rounded hover:bg-bg-tint transition-colors gap-1.5 group {isSelected ? 'bg-blue-soft' : ''}"
    style="padding-left: {8 + depth * 14}px"
  >
    {#if node.kind === "dir"}
      <span class="text-fg-subtle text-[10px] w-3 inline-block">{isOpen ? "▾" : "▸"}</span>
      <span class="text-blue text-[14px]" aria-hidden="true">▢</span>
      <span class="font-mono text-[12.5px] text-fg group-hover:text-fg">{node.name}/</span>
    {:else}
      <span class="w-3"></span>
      <span class="text-fg-muted text-[12px]" aria-hidden="true">▭</span>
      <span class="font-mono text-[12.5px] text-fg-soft">{node.name}</span>
    {/if}
    {#if node.size}
      <span class="ml-auto text-[10.5px] font-mono text-fg-subtle">{node.size}</span>
    {/if}
  </button>
  {#if node.kind === "dir" && isOpen && node.children}
    {#each node.children as child}
      {@render row(child, depth + 1, `${path}/${child.name}`)}
    {/each}
  {/if}
{/snippet}

<div class="rounded-2xl bg-white shadow-[0_2px_4px_rgba(0,0,0,0.04),0_24px_48px_-20px_rgba(0,0,0,0.16)] ring-1 ring-line overflow-hidden">
  <div class="px-4 py-3 bg-bg-soft border-b border-line">
    <span class="font-mono text-[12px] text-fg">~/.claude/skills/brands/nike/</span>
  </div>
  <div class="py-2 max-h-[420px] overflow-y-auto">
    {@render row(root, 0, root.name)}
  </div>
</div>
