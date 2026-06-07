<script lang="ts">
  /**
   * PackageDrawer — the content-contextual left sidebar (280px) for the
   * active Package. A header carries the package name + a grid/tree
   * layout toggle; the body renders the package's files either as an
   * iOS-springboard grid or a flat tree list. Double-click (grid) or
   * click (tree) opens the file as a document tab.
   *
   * Triggered by clicking the active package's avatar in the rail
   * (chrome.openFiles). The default layout is persisted on the Package
   * (`viewMode`); the toggle here writes that default back through the
   * command layer. Files come from the mocked `packageWorkbooks`.
   *
   * Deferred: drag/drop reorder, context menus (rename/delete), recursive
   * folder expand — they belong to the file-tree surface rebuild, not the
   * layout pass.
   */
  import { LayoutGrid, ListTree } from "@lucide/svelte";
  import { commands, type Package, type WorkbookEntry } from "$lib/bindings";
  import { tabs } from "$lib/tabs.svelte";
  import { chrome } from "$lib/chrome.svelte";

  let pkg = $state<Package | null>(null);
  let entries = $state<WorkbookEntry[]>([]);

  // Per-session layout override; falls back to the package's stored mode.
  let override = $state<Package["viewMode"] | null>(null);
  const layout = $derived(override ?? pkg?.viewMode ?? "grid");

  $effect(() => {
    void load();
  });
  async function load() {
    pkg = await commands.packageGetActive();
    entries = pkg ? await commands.packageWorkbooks({ name: pkg.name }) : [];
  }

  async function setLayout(next: Package["viewMode"]) {
    override = next;
    if (pkg && pkg.viewMode !== next) await commands.packageSetLayout({ name: pkg.name, viewMode: next });
  }

  async function openEntry(e: WorkbookEntry) {
    chrome.mode = "doc";
    await tabs.open(e.path);
  }

  function glyph(kind: WorkbookEntry["kind"]): string {
    switch (kind) {
      case "workbook": return "◆";
      case "org": return "◉";
      case "code": return "{ }";
      default: return "—";
    }
  }
</script>

<aside class="drawer" aria-label="Package files">
  <header class="hdr">
    <span class="label">{pkg?.name ?? "Package"}</span>
    <div class="switcher" role="tablist" aria-label="Layout">
      <button type="button" class="seg" class:active={layout === "grid"} role="tab"
        aria-selected={layout === "grid"} title="Grid" onclick={() => setLayout("grid")}>
        <LayoutGrid size={12} strokeWidth={1.8} />
      </button>
      <button type="button" class="seg" class:active={layout === "tree"} role="tab"
        aria-selected={layout === "tree"} title="Tree" onclick={() => setLayout("tree")}>
        <ListTree size={12} strokeWidth={1.8} />
      </button>
    </div>
  </header>

  {#if entries.length === 0}
    <p class="empty">No files yet.</p>
  {:else if layout === "grid"}
    <div class="grid" role="list">
      {#each entries as e (e.path)}
        <button type="button" class="tile" role="listitem" title={e.name} ondblclick={() => openEntry(e)}>
          <span class="tile-glyph kind-{e.kind}">{glyph(e.kind)}</span>
          <span class="tile-name">{e.name}</span>
        </button>
      {/each}
    </div>
  {:else}
    <div class="tree" role="list">
      {#each entries as e (e.path)}
        <button type="button" class="row" role="listitem" title={e.path} onclick={() => openEntry(e)}>
          <span class="kind kind-{e.kind}">{glyph(e.kind)}</span>
          <span class="row-name">{e.name}</span>
        </button>
      {/each}
    </div>
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
  .switcher {
    display: flex; border: 1px solid var(--color-border); border-radius: 5px;
    overflow: hidden; background: var(--color-surface-soft);
  }
  .seg {
    display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border: 0; background: transparent;
    color: var(--color-fg-muted); cursor: pointer;
  }
  .seg:hover { color: var(--color-fg); }
  .seg.active { background: var(--color-surface); color: var(--color-fg); }
  .empty { margin: 1rem 0.75rem; font-size: 0.78rem; color: var(--color-fg-subtle); }
  .grid {
    display: grid; grid-template-columns: repeat(auto-fill, minmax(72px, 1fr));
    gap: 6px; padding: 10px; overflow-y: auto;
  }
  .tile {
    display: flex; flex-direction: column; align-items: center; gap: 5px;
    padding: 10px 4px; border: 1px solid transparent; border-radius: 10px;
    background: transparent; cursor: pointer; color: var(--color-fg);
    transition: background 0.12s ease;
  }
  .tile:hover { background: var(--color-surface-soft); }
  .tile-glyph {
    display: grid; place-items: center; width: 40px; height: 40px;
    border-radius: 10px; background: var(--color-surface-soft);
    border: 1px solid var(--color-border); font-size: 16px;
    font-family: ui-monospace, monospace;
  }
  .tile-name {
    font-size: 0.68rem; text-align: center; line-height: 1.2;
    max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .tree { display: flex; flex-direction: column; padding: 4px; overflow-y: auto; }
  .row {
    display: flex; align-items: center; gap: 8px; padding: 5px 8px;
    border: 0; border-radius: 6px; background: transparent; cursor: pointer;
    color: var(--color-fg); font-size: 0.82rem; text-align: left;
  }
  .row:hover { background: var(--color-surface-soft); }
  .row-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .kind {
    display: inline-flex; width: 14px; justify-content: center; flex-shrink: 0;
    font-family: ui-monospace, monospace; font-size: 11px; opacity: 0.6;
  }
  .kind-workbook { color: #5b8cff; opacity: 0.9; }
  .kind-org { color: var(--color-ok); opacity: 0.9; }
  .kind-code { color: #a855f7; opacity: 0.9; }
</style>
