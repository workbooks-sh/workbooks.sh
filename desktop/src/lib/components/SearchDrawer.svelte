<script lang="ts">
  /**
   * SearchDrawer — fuzzy file search across the active workspace, mounted
   * in the left-panel slot (⌘K). Ranks by filename match → path match;
   * a click opens the result as a document tab. Caps at 200 rows.
   *
   * Mocked corpus today via `packageWorkbooks`; the real shell queries
   * the sidecar index. This is the layout-level shell — the full search
   * surface (highlighting, keyboard nav, drag-out) is its own rebuild.
   */
  import { Search, X } from "@lucide/svelte";
  import { commands, type WorkbookEntry } from "$lib/bindings";
  import { tabs } from "$lib/tabs.svelte";
  import { chrome } from "$lib/chrome.svelte";

  let query = $state("");
  let corpus = $state<WorkbookEntry[]>([]);

  $effect(() => {
    void (async () => {
      const pkg = await commands.packageGetActive();
      corpus = pkg ? await commands.packageWorkbooks({ name: pkg.name }) : [];
    })();
  });

  const results = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q) return corpus.slice(0, 200);
    return corpus
      .filter((e) => e.name.toLowerCase().includes(q) || e.path.toLowerCase().includes(q))
      .sort((a, b) => Number(b.name.toLowerCase().startsWith(q)) - Number(a.name.toLowerCase().startsWith(q)))
      .slice(0, 200);
  });

  async function open(e: WorkbookEntry) {
    chrome.mode = "doc";
    await tabs.open(e.path);
  }
</script>

<aside class="drawer" aria-label="Search">
  <div class="field">
    <Search size={13} strokeWidth={1.8} />
    <!-- svelte-ignore a11y_autofocus -->
    <input class="input" placeholder="Search files…" bind:value={query} autofocus />
    <button type="button" class="x" aria-label="Close search" onclick={() => chrome.closeLeft()}>
      <X size={13} strokeWidth={2} />
    </button>
  </div>
  <div class="rows" role="list">
    {#each results as e (e.path)}
      <button type="button" class="row" role="listitem" title={e.path} onclick={() => open(e)}>
        <span class="name">{e.name}</span>
        <span class="path">{e.path}</span>
      </button>
    {:else}
      <p class="empty">No matches.</p>
    {/each}
  </div>
</aside>

<style>
  .drawer {
    flex-shrink: 0; width: 280px; min-width: 220px; max-width: 420px;
    display: flex; flex-direction: column; overflow: hidden;
    background: var(--color-surface); border-right: 1px solid var(--color-border);
  }
  .field {
    display: flex; align-items: center; gap: 6px; padding: 8px 10px;
    border-bottom: 1px solid var(--color-border); color: var(--color-fg-muted);
  }
  .input {
    flex: 1 1 auto; min-width: 0; background: transparent; border: 0;
    color: var(--color-fg); font: inherit; font-size: 0.84rem; outline: none;
  }
  .x {
    display: grid; place-items: center; width: 20px; height: 20px;
    border: 0; border-radius: 5px; background: transparent;
    color: var(--color-fg-muted); cursor: pointer;
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .rows { display: flex; flex-direction: column; padding: 4px; overflow-y: auto; }
  .row {
    display: flex; flex-direction: column; gap: 1px; padding: 6px 8px;
    border: 0; border-radius: 6px; background: transparent; cursor: pointer;
    text-align: left;
  }
  .row:hover { background: var(--color-surface-soft); }
  .name { font-size: 0.82rem; color: var(--color-fg); }
  .path {
    font-size: 0.68rem; color: var(--color-fg-subtle);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .empty { margin: 1rem 0.75rem; font-size: 0.78rem; color: var(--color-fg-subtle); }
</style>
