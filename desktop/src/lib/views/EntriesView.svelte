<script lang="ts">
  /**
   * EntriesView — a server-paginated list, the surface the old app never
   * had (its SearchDrawer just hard-capped at 200 rows). Each navigation
   * re-fetches one slice via `commands.entriesPage(offset/limit)`, so the
   * client holds only the visible page plus the total count.
   *
   * A filter input resets to page 1. Page size persists across launches
   * via the store (shaped for tauri-store). Rows carry a kind glyph that
   * mirrors the titlebar's document-tab glyphs (◆ workbook, ◉ org,
   * { } code, — text). Opening a row is deferred to the tabs surface.
   */
  import { onMount } from "svelte";
  import { commands, type WorkbookEntry } from "$lib/bindings";
  import { store } from "$lib/store.svelte";
  import Pagination from "$lib/components/Pagination.svelte";

  const SIZE_KEY = "entries.pageSize";

  let page = $state(1);
  let pageSize = $state(20);
  let query = $state("");
  let items = $state<WorkbookEntry[]>([]);
  let total = $state(0);
  let loading = $state(true);

  const GLYPH: Record<WorkbookEntry["kind"], string> = {
    workbook: "◆",
    org: "◉",
    code: "{ }",
    text: "—",
  };

  async function load() {
    loading = true;
    const res = await commands.entriesPage({
      offset: (page - 1) * pageSize,
      limit: pageSize,
      query,
    });
    items = res.items;
    total = res.total;
    loading = false;
  }

  onMount(async () => {
    const saved = await store.get<number>(SIZE_KEY);
    if (saved) pageSize = saved;
    await load();
  });

  function setPage(p: number) {
    page = p;
    void load();
  }

  function setSize(n: number) {
    pageSize = n;
    page = 1;
    void store.set(SIZE_KEY, n);
    void load();
  }

  let debounce: ReturnType<typeof setTimeout>;
  function onQuery(v: string) {
    query = v;
    page = 1;
    clearTimeout(debounce);
    debounce = setTimeout(() => void load(), 180);
  }
</script>

<section class="entries">
  <header class="head">
    <h1>Entries</h1>
    <input
      class="filter"
      type="search"
      placeholder="Filter by name or path…"
      value={query}
      oninput={(e) => onQuery(e.currentTarget.value)}
    />
  </header>

  <div class="list" class:dim={loading}>
    {#if items.length === 0}
      <p class="empty">{loading ? "Loading…" : "No matching entries."}</p>
    {:else}
      {#each items as e (e.path)}
        <button class="row" title={e.path}>
          <span class="glyph kind-{e.kind}">{GLYPH[e.kind]}</span>
          <span class="name">{e.name}</span>
          <span class="path">{e.path}</span>
          <span class="badge">{e.kind}</span>
        </button>
      {/each}
    {/if}
  </div>

  <footer class="foot">
    <Pagination {page} {pageSize} {total} onpage={setPage} onsize={setSize} />
  </footer>
</section>

<style>
  .entries {
    max-width: 720px;
    margin: 0 auto;
    padding: 1.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
    height: 100%;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }
  .head h1 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }
  .filter {
    margin-left: auto;
    width: 240px;
    height: 30px;
    padding: 0 0.6rem;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.8rem;
  }
  .filter:focus {
    outline: none;
    border-color: var(--color-border-strong);
  }
  .list {
    flex: 1 1 auto;
    min-height: 0;
    overflow: auto;
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
    transition: opacity 0.12s ease;
  }
  .list.dim {
    opacity: 0.55;
  }
  .empty {
    margin: 1rem 0;
    font-size: 0.82rem;
    color: var(--color-fg-muted);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    width: 100%;
    padding: 0.45rem 0.55rem;
    border: 1px solid transparent;
    border-radius: 8px;
    background: transparent;
    text-align: left;
    cursor: pointer;
  }
  .row:hover {
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .glyph {
    flex-shrink: 0;
    width: 24px;
    text-align: center;
    font-size: 0.8rem;
    color: var(--color-fg-muted);
  }
  .name {
    font-size: 0.84rem;
    font-weight: 500;
  }
  .path {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  .badge {
    flex-shrink: 0;
    padding: 2px 8px;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    font-size: 0.66rem;
    font-weight: 600;
    color: var(--color-fg-muted);
  }
  .foot {
    flex-shrink: 0;
    padding-top: 0.4rem;
    border-top: 1px solid var(--color-border);
  }
</style>
