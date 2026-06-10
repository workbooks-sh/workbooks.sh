<script lang="ts">
  /**
   * SearchDrawer — left-side pop-out search panel.
   *
   * Sibling to PackageTreeDrawer. Custom search input with the search
   * icon inline, fuzzy results list underneath. Click a result to open
   * as a tab; drag a result to spawn a drag operation other surfaces
   * can consume (the main editor will wire drop targets later — for
   * now the drag carries text/uri-list + text/plain so external apps
   * accept it too).
   *
   * Searches every file across every Package in the active Workspace.
   */
  import { MagnifyingGlass as Search, File as FileIcon, X } from "phosphor-svelte";
  import { fileTree, type FsEntry } from "$lib/bridge/fs_tree.svelte";
  import {
    packageStore,
    type Package as PackageDef,
  } from "$lib/bridge/package.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";

  let { onclose }: { onclose?: () => void } = $props();

  let query = $state("");
  let inputEl: HTMLInputElement | null = $state(null);
  let highlighted = $state(0);
  let packageData = $state<Record<string, PackageDef>>({});

  // Lazy-load full Package records for every name in the active
  // workspace so we can compute folders across all of them. Mirrors
  // the same pattern in FileTreePanel — they could share a helper
  // later, but for now duplication is fine while shape stabilises.
  $effect(() => {
    const names = workspaces.active?.package_names ?? [];
    for (const name of names) {
      if (!packageData[name]) {
        packageStore
          .load(name)
          .then((p) => (packageData = { ...packageData, [name]: p }))
          .catch(() => {});
      }
    }
  });

  function pkgFor(name: string): PackageDef | null {
    if (packageStore.active?.name === name) return packageStore.active;
    return packageData[name] ?? null;
  }

  // Collect (package, root, entry) for every file in every package in
  // the active workspace. Skips directories.
  type Hit = { pkg: string; root: string; entry: FsEntry };
  const allEntries = $derived.by<Hit[]>(() => {
    const out: Hit[] = [];
    const names = workspaces.active?.package_names ?? [];
    for (const name of names) {
      const p = pkgFor(name);
      if (!p) continue;
      for (const root of p.folders) {
        const tree = fileTree.trees[root];
        if (!tree) continue;
        for (const e of tree.entries) {
          if (!e.is_dir) out.push({ pkg: name, root, entry: e });
        }
      }
    }
    return out;
  });

  const results = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q) return allEntries.slice(0, 200);
    const ranked = allEntries
      .map((h) => {
        const name = h.entry.name.toLowerCase();
        const rel = h.entry.rel.toLowerCase();
        let score = 0;
        if (name === q) score = 1000;
        else if (name.startsWith(q)) score = 800;
        else if (name.includes(q)) score = 600;
        else if (rel.includes(q)) score = 400;
        else return null;
        score -= rel.length;
        return { ...h, score };
      })
      .filter((x): x is Hit & { score: number } => !!x)
      .sort((a, b) => b.score - a.score)
      .slice(0, 200);
    return ranked.map(({ pkg, root, entry }) => ({ pkg, root, entry }));
  });

  $effect(() => {
    void query;
    highlighted = 0;
  });

  // Focus the input on mount — the drawer only mounts when open.
  $effect(() => {
    queueMicrotask(() => inputEl?.focus());
  });

  async function openResult(idx: number) {
    const r = results[idx];
    if (!r) return;
    try {
      await tabsStore.open(r.entry.path);
    } catch (e) {
      console.warn("[search] open failed", e);
    }
  }

  function onKey(e: KeyboardEvent) {
    if (document.activeElement !== inputEl) return;
    if (e.key === "Escape") {
      e.preventDefault();
      if (query) {
        query = "";
      } else {
        onclose?.();
      }
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      highlighted = Math.min(highlighted + 1, Math.max(0, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      highlighted = Math.max(highlighted - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      void openResult(highlighted);
    }
  }

  function onDragStart(e: DragEvent, path: string) {
    if (!e.dataTransfer) return;
    // text/uri-list lets file managers accept it; text/plain is the
    // universal fallback. The path is the raw filesystem path so an
    // in-app drop target can pass it straight to `tabsStore.open`.
    e.dataTransfer.effectAllowed = "copy";
    e.dataTransfer.setData("text/uri-list", `file://${path}`);
    e.dataTransfer.setData("text/plain", path);
    e.dataTransfer.setData(
      "application/x-workbooks-file-path",
      path,
    );
  }

  function relPath(root: string, rel: string): string {
    const parts = root.split(/[\\/]/).filter(Boolean);
    const base = parts[parts.length - 1] ?? "";
    return base ? `${base}/${rel}` : rel;
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
        placeholder="Search workspace files…"
        spellcheck="false"
        autocomplete="off"
      />
      {#if query}
        <button
          type="button"
          class="clear"
          aria-label="Clear search"
          onclick={() => (query = "")}
        >
          <X weight="bold" size={11} />
        </button>
      {/if}
    </div>

    <div class="results" role="listbox" aria-label="Search results">
      {#if !workspaces.active}
        <div class="empty">No active workspace.</div>
      {:else if results.length === 0}
        <div class="empty">
          {query ? "No matches." : "Files will appear here as packages are walked."}
        </div>
      {:else}
        {#each results as r, i (r.entry.path)}
          <button
            type="button"
            class="result"
            class:active={i === highlighted}
            role="option"
            aria-selected={i === highlighted}
            draggable="true"
            ondragstart={(e) => onDragStart(e, r.entry.path)}
            onmouseenter={() => (highlighted = i)}
            onclick={() => openResult(i)}
            title={r.entry.path}
          >
            <FileIcon weight="fill" size={12} />
            <span class="name">{r.entry.name}</span>
            <span class="path">{r.pkg} · {relPath(r.root, r.entry.rel)}</span>
          </button>
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
    background: var(--color-surface);
    border-right: 1px solid var(--color-border);
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
    font-family: inherit;
    font-size: 0.85rem;
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
    border-radius: 6px;
    padding: 0.4rem 0.55rem;
    color: var(--color-fg);
    font-family: inherit;
    font-size: 0.82rem;
    cursor: pointer;
    text-align: left;
    min-width: 0;
  }
  .result.active { background: var(--color-surface-soft); }
  .result:hover { background: var(--color-surface-soft); }
  .result .name {
    font-weight: 500;
    flex-shrink: 0;
  }
  .result .path {
    color: var(--color-fg-muted);
    font-size: 0.72rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    direction: rtl;
    text-align: left;
    flex: 1 1 auto;
    font-family: ui-monospace, SFMono-Regular, monospace;
  }
</style>
