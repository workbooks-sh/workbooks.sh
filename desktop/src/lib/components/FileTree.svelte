<script lang="ts">
  /**
   * FileTree — one node row in the explorer, recursive. A folder expands lazily
   * (read_dir on first open); a file opens as a document tab. The whole subtree is
   * driven by the host fs, so the workbook/package is genuinely explorable.
   */
  import { ChevronRight, Folder, FolderOpen, FileText, FileCode, File as FileIcon } from "@lucide/svelte";
  import { listDir, type DirEntry } from "$lib/files";
  import { tabs } from "$lib/tabs.svelte";
  import { chrome } from "$lib/chrome.svelte";
  import Self from "./FileTree.svelte";

  let { entry, depth = 0 }: { entry: DirEntry; depth?: number } = $props();

  let open = $state(false);
  let children = $state<DirEntry[] | null>(null);
  let loading = $state(false);
  let err = $state("");

  async function toggle() {
    if (!entry.isDir) {
      chrome.mode = "doc";
      await tabs.open(entry.path);
      return;
    }
    open = !open;
    if (open && children === null) {
      loading = true;
      try {
        children = await listDir(entry.path);
      } catch (e) {
        err = e instanceof Error ? e.message : String(e);
        children = [];
      } finally {
        loading = false;
      }
    }
  }

  function fileIcon(name: string) {
    const ext = name.split(".").pop()?.toLowerCase() ?? "";
    if (["rs", "ts", "js", "py", "go", "ex", "exs", "json", "toml", "c", "zig"].includes(ext)) return FileCode;
    if (["org", "md", "txt", "html", "htm"].includes(ext)) return FileText;
    return FileIcon;
  }

  const active = $derived(!entry.isDir && tabs.active?.path === entry.path);
</script>

<button
  type="button"
  class="row"
  class:active
  style="padding-left:{depth * 12 + 6}px"
  title={entry.path}
  onclick={() => void toggle()}
>
  {#if entry.isDir}
    <span class="caret" class:open><ChevronRight size={13} strokeWidth={2} /></span>
    {#if open}<FolderOpen size={14} strokeWidth={1.7} />{:else}<Folder size={14} strokeWidth={1.7} />{/if}
  {:else}
    <span class="caret"></span>
    {@const Icon = fileIcon(entry.name)}
    <Icon size={14} strokeWidth={1.7} />
  {/if}
  <span class="name">{entry.name}</span>
</button>

{#if entry.isDir && open}
  {#if loading}
    <div class="hint" style="padding-left:{(depth + 1) * 12 + 22}px">…</div>
  {:else if err}
    <div class="hint err" style="padding-left:{(depth + 1) * 12 + 22}px">{err}</div>
  {:else if children}
    {#each children as child (child.path)}
      <Self entry={child} depth={depth + 1} />
    {/each}
    {#if children.length === 0}
      <div class="hint" style="padding-left:{(depth + 1) * 12 + 22}px">empty</div>
    {/if}
  {/if}
{/if}

<style>
  .row {
    display: flex; align-items: center; gap: 4px; width: 100%;
    padding: 3px 6px; border: 0; background: transparent; cursor: pointer;
    color: var(--color-fg); font-size: 0.82rem; text-align: left;
    border-radius: 5px;
  }
  .row:hover { background: var(--color-surface-soft); }
  .row.active { background: var(--color-surface-soft); color: var(--color-fg); font-weight: 500; }
  .caret {
    display: inline-flex; align-items: center; justify-content: center;
    width: 14px; flex-shrink: 0; color: var(--color-fg-subtle);
    transition: transform 0.12s ease;
  }
  .caret.open { transform: rotate(90deg); }
  .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .hint { font-size: 0.74rem; color: var(--color-fg-subtle); padding-top: 2px; padding-bottom: 2px; }
  .hint.err { color: #e06c75; }
</style>
