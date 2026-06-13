<script lang="ts">
  /**
   * SearchDrawer (wb-aakl.19) — composable search.
   *
   * Runs every enabled SearchProvider (registry) and renders results
   * grouped by provider: local files/workbooks, bookmarks, open tabs, and
   * the nexus web lane. Click a local result to open it as a tab; a web
   * result opens its URL in a tab (the readability path). Toolkits add
   * providers via the Browser SDK — they appear here as peers.
   */
  import { MagnifyingGlass as Search, X } from "phosphor-svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import { search, type ProviderResults } from "$lib/search/registry.svelte";
  import type { SearchResult } from "$lib/search/types";

  let { onclose }: { onclose?: () => void } = $props();

  let query = $state("");
  let inputEl: HTMLInputElement | null = $state(null);
  let highlighted = $state(0);
  let groups = $state<ProviderResults[]>([]);
  let busy = $state(false);

  // Run all providers on query change (debounced). The empty query shows
  // each provider's default set (recent files etc.).
  let runToken = 0;
  $effect(() => {
    const q = query;
    const token = ++runToken;
    busy = true;
    const t = setTimeout(() => {
      void search.searchAll(q).then((g) => {
        if (token !== runToken) return; // a newer query superseded this
        groups = g.filter((x) => x.results.length > 0 || x.error);
        busy = false;
      });
    }, 120);
    return () => clearTimeout(t);
  });

  // Flat list (in group order) for keyboard nav.
  const flat = $derived(groups.flatMap((g) => g.results));

  $effect(() => {
    void query;
    highlighted = 0;
  });
  $effect(() => {
    queueMicrotask(() => inputEl?.focus());
  });

  async function open(r: SearchResult) {
    try {
      // Local results open by path; web results open their URL in a tab
      // (the viewer's readability path renders it inside the browser).
      await tabsStore.open(r.path ?? r.url ?? "");
    } catch (e) {
      console.warn("[search] open failed", e);
    }
  }

  function onKey(e: KeyboardEvent) {
    if (document.activeElement !== inputEl) return;
    if (e.key === "Escape") {
      e.preventDefault();
      if (query) query = "";
      else onclose?.();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      highlighted = Math.min(highlighted + 1, Math.max(0, flat.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      highlighted = Math.max(highlighted - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const r = flat[highlighted];
      if (r) void open(r);
    }
  }

  function onDragStart(e: DragEvent, r: SearchResult) {
    if (!e.dataTransfer) return;
    const target = r.path ?? r.url ?? "";
    e.dataTransfer.effectAllowed = "copy";
    e.dataTransfer.setData("text/uri-list", r.path ? `file://${target}` : target);
    e.dataTransfer.setData("text/plain", target);
    if (r.path) e.dataTransfer.setData("application/x-workbooks-file-path", r.path);
  }

  // Index of a result within the flat list, for keyboard highlight.
  function flatIndex(g: ProviderResults, i: number): number {
    let n = 0;
    for (const grp of groups) {
      if (grp === g) return n + i;
      n += grp.results.length;
    }
    return n + i;
  }
</script>

<svelte:window onkeydown={onKey} />

<aside class="drawer" aria-label="Search">
    <div class="search-row">
      <Search weight="bold" size={13} />
      <input
        bind:this={inputEl}
        bind:value={query}
        type="text"
        placeholder="Search files, bookmarks, the web…"
        spellcheck="false"
        autocomplete="off"
      />
      {#if query}
        <button type="button" class="clear" aria-label="Clear search" onclick={() => (query = "")}>
          <X weight="bold" size={11} />
        </button>
      {/if}
    </div>

    <div class="results" role="listbox" aria-label="Search results">
      {#if groups.length === 0}
        <div class="empty">
          {busy ? "Searching…" : query ? "No matches." : "Search across files, bookmarks, tabs and the web."}
        </div>
      {:else}
        {#each groups as g (g.provider.id)}
          <div class="group-head">
            {#if g.provider.icon}{@const Icon = g.provider.icon}<Icon weight="fill" size={11} />{/if}
            <span>{g.provider.label}</span>
            {#if g.error}<span class="g-err">unavailable</span>{/if}
          </div>
          {#each g.results as r, i (g.provider.id + (r.path ?? r.url ?? "") + i)}
            {@const fi = flatIndex(g, i)}
            <button
              type="button"
              class="result"
              class:active={fi === highlighted}
              role="option"
              aria-selected={fi === highlighted}
              draggable="true"
              ondragstart={(e) => onDragStart(e, r)}
              onmouseenter={() => (highlighted = fi)}
              onclick={() => open(r)}
              title={r.path ?? r.url ?? r.title}
            >
              <span class="kind kind-{r.kind}" aria-hidden="true"></span>
              <span class="name">{r.title}</span>
              {#if r.subtitle}<span class="path">{r.subtitle}</span>{/if}
            </button>
          {/each}
        {/each}
      {/if}
    </div>
</aside>

<style>
  .drawer {
    flex-shrink: 0;
    width: 280px;
    min-width: 220px;
    max-width: 420px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background: color-mix(in srgb, var(--color-surface) 88%, transparent);
    backdrop-filter: blur(14px);
    -webkit-backdrop-filter: blur(14px);
    border-right: 1px solid var(--color-border-strong);
  }

  .search-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.55rem 0.75rem;
    border-bottom: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .search-row input {
    flex: 1 1 auto;
    background: transparent;
    border: 0;
    outline: 0;
    color: var(--color-fg);
    font-family: var(--font-mono);
    font-size: 13px;
    min-width: 0;
  }
  .search-row input::placeholder { color: var(--color-fg-subtle); }
  .clear {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border-radius: 4px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    flex-shrink: 0;
    transition: color 0.15s, background 0.15s;
  }
  .clear:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .results {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 4px;
    display: flex;
    flex-direction: column;
  }
  .empty {
    padding: 1.25rem 1rem;
    text-align: center;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
  }
  .result {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    background: transparent;
    border: 0;
    border-radius: 8px;
    padding: 0.4rem 0.55rem;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.82rem;
    cursor: pointer;
    text-align: left;
    min-width: 0;
    transition: background 0.15s;
  }
  .result.active { background: var(--color-surface-soft); }
  .result:hover { background: var(--color-surface-soft); }
  .result .name {
    font-weight: 500;
    flex-shrink: 0;
  }

  .group-head {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 8px 3px;
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.09em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
  }
  .group-head .g-err { margin-left: auto; color: var(--color-warn); text-transform: none; letter-spacing: 0; }
  /* kind dot — a quiet color cue per result kind */
  .kind {
    width: 7px;
    height: 7px;
    border-radius: 2px;
    flex-shrink: 0;
    background: var(--color-fg-subtle);
  }
  .kind-workbook { background: var(--color-brand); }
  .kind-web { background: var(--color-chip-blue); }
  .kind-bookmark { background: var(--color-chip-peach); }
  .kind-tab { background: var(--color-chip-lavender); }
  .kind-answer { background: var(--color-brand); border-radius: 50%; }
  .result .path {
    color: var(--color-fg-muted);
    font-size: 11px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    direction: rtl;
    text-align: left;
    flex: 1 1 auto;
    font-family: var(--font-mono);
  }
</style>
