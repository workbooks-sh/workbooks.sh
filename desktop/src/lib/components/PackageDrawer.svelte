<script lang="ts">
  /**
   * PackageDrawer — the explorer sidebar (280px). Opens a folder (a workbook
   * package, or any directory of .org context) and shows it as a real, lazily-
   * expanded file tree off the host fs. Click a file → it opens as a document
   * tab in the DocView surface; click a folder → it expands. The chosen root
   * persists across restarts (workspace store), so the explorer is there by
   * default next launch.
   *
   * Triggered by the active package avatar in the rail (chrome.openFiles).
   */
  import { FolderOpen, RefreshCw } from "@lucide/svelte";
  import { workspace } from "$lib/workspace.svelte";
  import { listDir, type DirEntry } from "$lib/files";
  import FileTree from "./FileTree.svelte";

  let roots = $state<DirEntry[]>([]);
  let loading = $state(false);
  let err = $state("");
  // Bump to force the tree to remount (collapse + reload) on refresh / root change.
  let nonce = $state(0);

  $effect(() => {
    // Re-read whenever the root changes.
    const root = workspace.root;
    void load(root);
  });

  async function load(root: string | null) {
    err = "";
    if (!root) {
      roots = [];
      return;
    }
    loading = true;
    try {
      roots = await listDir(root);
    } catch (e) {
      err = e instanceof Error ? e.message : String(e);
      roots = [];
    } finally {
      loading = false;
    }
  }

  async function openFolder() {
    await workspace.openFolder();
  }
  function refresh() {
    nonce++;
    void load(workspace.root);
  }
</script>

<aside class="drawer" aria-label="Explorer">
  <header class="hdr">
    <span class="label" title={workspace.root ?? ""}>{workspace.name}</span>
    <div class="tools">
      {#if workspace.root}
        <button type="button" class="tool" title="Refresh" onclick={refresh}>
          <RefreshCw size={12} strokeWidth={1.8} />
        </button>
      {/if}
      <button type="button" class="tool" title="Open folder…" onclick={() => void openFolder()}>
        <FolderOpen size={13} strokeWidth={1.8} />
      </button>
    </div>
  </header>

  {#if !workspace.root}
    <div class="empty">
      <p>No folder open.</p>
      <button type="button" class="open-cta" onclick={() => void openFolder()}>
        <FolderOpen size={14} strokeWidth={1.8} /> Open folder
      </button>
    </div>
  {:else if loading}
    <p class="hint">Loading…</p>
  {:else if err}
    <p class="hint err">{err}</p>
  {:else if roots.length === 0}
    <p class="hint">Empty folder.</p>
  {:else}
    {#key nonce}
      <div class="tree" role="tree">
        {#each roots as entry (entry.path)}
          <FileTree {entry} />
        {/each}
      </div>
    {/key}
  {/if}
</aside>

<style>
  .drawer {
    flex-shrink: 0; width: 280px; min-width: 220px; max-width: 420px;
    display: flex; flex-direction: column; overflow: hidden;
    background: var(--color-surface); border-right: 1px solid var(--color-border);
  }
  .hdr {
    display: flex; align-items: center; justify-content: space-between; gap: 8px;
    padding: 6px 8px 6px 10px; border-bottom: 1px solid var(--color-border);
  }
  .label {
    font-size: 11.5px; font-weight: 500; color: var(--color-fg-muted);
    text-transform: uppercase; letter-spacing: 0.04em;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .tools { display: flex; gap: 2px; flex-shrink: 0; }
  .tool {
    display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border: 0; background: transparent;
    color: var(--color-fg-muted); cursor: pointer; border-radius: 5px;
  }
  .tool:hover { color: var(--color-fg); background: var(--color-surface-soft); }
  .empty {
    display: flex; flex-direction: column; gap: 0.6rem; align-items: flex-start;
    margin: 1rem 0.75rem; font-size: 0.8rem; color: var(--color-fg-subtle);
  }
  .open-cta {
    display: inline-flex; align-items: center; gap: 0.4rem;
    padding: 0.4rem 0.7rem; border: 1px solid var(--color-border);
    border-radius: 6px; background: var(--color-page); color: var(--color-fg);
    cursor: pointer; font-size: 0.8rem;
  }
  .open-cta:hover { background: var(--color-surface-soft); }
  .hint { margin: 0.8rem 0.75rem; font-size: 0.78rem; color: var(--color-fg-subtle); }
  .hint.err { color: var(--color-err); }
  .tree { flex: 1 1 auto; overflow-y: auto; padding: 4px; }
</style>
