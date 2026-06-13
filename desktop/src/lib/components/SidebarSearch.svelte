<script lang="ts">
  /**
   * SidebarSearch (wb-aakl.19) — an inline search bar that lives at the top of
   * the sidebar and searches the actual FILE SYSTEM (the workspace's files +
   * workbooks). This is distinct from the titlebar's global ⌘K search badge:
   * it's always-present, scoped to local files, and opens its results inline
   * below the field. Results never show until you type.
   */
  import { MagnifyingGlass, X } from "phosphor-svelte";
  import Icon from "$lib/ui/Icon.svelte";
  import { fileIconUrl } from "$lib/ui/materialIcon";
  import { docIcons } from "$lib/ui/docIcon.svelte";
  import { filesProvider } from "$lib/search/builtins";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { DEMO_FOLDER_CHILDREN } from "$lib/onboarding/demo";
  import type { SearchResult } from "$lib/search/types";

  let { onOpen }: { onOpen?: (path: string) => void } = $props();

  let query = $state("");

  // Flattened demo files so the bar demos real results during the tour (the
  // file index is empty before any runtime exists).
  const demoFiles = Object.values(DEMO_FOLDER_CHILDREN).flat();

  const results = $derived.by<SearchResult[]>(() => {
    const q = query.trim();
    if (!q) return [];
    if (onboarding.active) {
      const lq = q.toLowerCase();
      return demoFiles
        .filter((f) => f.title.toLowerCase().includes(lq) || f.path.toLowerCase().includes(lq))
        .slice(0, 8)
        .map((f) => ({
          kind: "workbook" as const,
          title: f.title,
          subtitle: f.path,
          path: f.path,
          providerId: "files",
          score: 0,
        }));
    }
    const r = filesProvider.search(q);
    return (Array.isArray(r) ? r : []).filter((x) => x.path).slice(0, 8);
  });

  function open(r: SearchResult) {
    if (r.path) onOpen?.(r.path);
    query = "";
  }
  function clear() {
    query = "";
  }
</script>

<div class="sb-search" class:has-results={results.length > 0}>
  <div class="field">
    <MagnifyingGlass size={14} weight="bold" aria-hidden="true" />
    <input
      type="search"
      placeholder="Search files…"
      bind:value={query}
      spellcheck="false"
      autocomplete="off"
      aria-label="Search files"
      onkeydown={(e) => { if (e.key === "Escape") clear(); }}
    />
    {#if query}
      <button type="button" class="clear" aria-label="Clear" onclick={clear}>
        <X size={12} weight="bold" />
      </button>
    {/if}
  </div>

  {#if query.trim() && results.length === 0}
    <div class="sb-results"><span class="empty">No files</span></div>
  {:else if results.length > 0}
    <div class="sb-results" role="listbox">
      {#each results as r (r.path)}
        {@const identity = docIcons.iconFor(r.path ?? "")}
        <button type="button" class="hit" role="option" aria-selected="false" onclick={() => open(r)} title={r.path}>
          <span class="hit-icon">
            {#if identity}
              <Icon value={identity} name={r.title} size={14} />
            {:else}
              <img class="mi" src={fileIconUrl(r.path ?? "")} alt="" />
            {/if}
          </span>
          <span class="hit-text">
            <span class="hit-title">{r.title}</span>
            {#if r.subtitle}<span class="hit-sub">{r.subtitle}</span>{/if}
          </span>
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .sb-search {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 2px 2px 6px;
  }
  .field {
    display: flex;
    align-items: center;
    gap: 7px;
    height: 30px;
    padding: 0 7px 0 9px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
    transition: border-color 0.15s, background 0.15s;
  }
  .field:focus-within {
    border-color: var(--color-border-strong);
    background: var(--color-surface);
    color: var(--color-fg);
  }
  .field :global(svg) { display: block; flex-shrink: 0; }
  .field input {
    flex: 1 1 auto;
    min-width: 0;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.82rem;
    outline: none;
  }
  .field input::placeholder { color: var(--color-fg-subtle); }
  .field input::-webkit-search-cancel-button { display: none; }
  .clear {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--color-fg-subtle);
    cursor: pointer;
  }
  .clear:hover { background: color-mix(in srgb, var(--color-fg) 8%, transparent); color: var(--color-fg); }

  .sb-results {
    display: flex;
    flex-direction: column;
    gap: 1px;
    max-height: 240px;
    overflow-y: auto;
    padding: 2px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface);
    box-shadow: var(--shadow-pop);
  }
  .empty {
    padding: 8px 10px;
    font-size: 0.78rem;
    color: var(--color-fg-subtle);
  }
  .hit {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 5px 8px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
  }
  .hit:hover { background: color-mix(in srgb, var(--color-fg) 6%, transparent); }
  .hit-icon { display: inline-flex; flex-shrink: 0; width: 18px; height: 18px; align-items: center; justify-content: center; }
  .hit-icon :global(svg), .hit-icon .mi { display: block; width: 16px; height: 16px; }
  .hit-text { display: flex; flex-direction: column; min-width: 0; }
  .hit-title {
    font-size: 0.82rem;
    line-height: 1.2;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hit-sub {
    font-size: 0.68rem;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
