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
  import { MagnifyingGlass as Search, X, Sparkle, FileText, Globe, ArrowUpRight } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import { search, type ProviderResults } from "$lib/search/registry.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { aiAnswer, type AiAnswer } from "$lib/search/aiPreview";
  import { setSearch, type SearchApi } from "$lib/search/context";
  import type { SearchResult } from "$lib/search/types";

  const mode = $derived(search.mode);
  let aiResult = $state<AiAnswer | null>(null);

  let { onclose }: { onclose?: () => void } = $props();

  // Resize by dragging the left edge (it's a right-side panel, like the dock).
  let dragging = $state(false);
  function startResize(e: PointerEvent) {
    dragging = true;
    const startX = e.clientX;
    const startW = chrome.searchWidth;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => {
      if (dragging) chrome.setSearchWidth(startW + (startX - ev.clientX));
    };
    const up = () => {
      dragging = false;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  let query = $state("");
  let inputEl: HTMLInputElement | null = $state(null);
  let highlighted = $state(0);
  let groups = $state<ProviderResults[]>([]);
  let busy = $state(false);

  // Seed a preview query when one was set (e.g. onboarding previewing a mode).
  onMount(() => {
    if (search.demoQuery) {
      query = search.demoQuery;
      if (search.mode === "ai") aiResult = aiAnswer(query);
      search.demoQuery = "";
    }
  });

  // Run providers on query change (debounced). AI mode is a submit flow (no
  // live providers); internal mode drops the web group.
  let runToken = 0;
  $effect(() => {
    const q = query;
    const m = mode;
    if (m === "ai") { groups = []; busy = false; return; }
    const token = ++runToken;
    busy = true;
    const t = setTimeout(() => {
      void search.searchAll(q).then((g) => {
        if (token !== runToken) return; // a newer query superseded this
        let gg = g.filter((x) => x.results.length > 0 || x.error);
        if (m === "internal") gg = gg.filter((x) => x.provider.id !== "web");
        groups = gg;
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
      if (mode === "ai") {
        aiResult = query.trim() ? aiAnswer(query) : null;
        return;
      }
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

  function openSource(s: { url?: string; path?: string }) {
    void tabsStore.open(s.url ?? s.path ?? "").catch(() => {});
  }
  function askRelated(q: string) {
    query = q;
    aiResult = aiAnswer(q);
  }
  const placeholder = $derived(
    mode === "ai" ? "Ask anything, then press Enter…" : mode === "internal" ? "Search your files…" : "Search files, bookmarks, the web…",
  );

  // Index of a result within the flat list, for keyboard highlight.
  function flatIndex(g: ProviderResults, i: number): number {
    let n = 0;
    for (const grp of groups) {
      if (grp === g) return n + i;
      n += grp.results.length;
    }
    return n + i;
  }

  // Search SDK — expose this host's surface so any search UI (and toolkits)
  // can consume the same contract (parallel to the sidebar SDK).
  const api: SearchApi = {
    get mode() { return search.mode; },
    setMode: (m) => search.setMode(m),
    get query() { return query; },
    setQuery: (q) => { query = q; },
    get busy() { return busy; },
    get groups() { return groups; },
    get flat() { return flat; },
    get highlighted() { return highlighted; },
    setHighlighted: (i) => { highlighted = i; },
    get ai() { return aiResult; },
    ask: (q) => { const v = (q ?? query).trim(); aiResult = v ? aiAnswer(v) : null; },
    open: (r) => void open(r),
    openTarget: (t) => openSource(t),
    close: () => onclose?.(),
  };
  setSearch(api);
</script>

<svelte:window onkeydown={onKey} />

<aside class="drawer" class:dragging aria-label="Search" style="width: {chrome.searchWidth}px">
    <button
      type="button"
      class="resize"
      class:dragging
      aria-label="Resize search"
      onpointerdown={startResize}
    ></button>
    <div class="search-row" class:ai={mode === "ai"}>
      {#if mode === "ai"}<Sparkle weight="fill" size={13} />{:else}<Search weight="bold" size={13} />{/if}
      <input
        bind:this={inputEl}
        bind:value={query}
        type="text"
        placeholder={placeholder}
        spellcheck="false"
        autocomplete="off"
      />
      {#if query}
        <button type="button" class="clear" aria-label="Clear search" onclick={() => { query = ""; aiResult = null; }}>
          <X weight="bold" size={11} />
        </button>
      {/if}
    </div>

    {#if mode === "ai"}
      <!-- AI search — prompt → synthesised answer + sources + follow-ups. -->
      <div class="results ai-results">
        {#if !aiResult}
          <div class="empty">Ask anything and press Enter — I'll answer from your files and the web, with sources.</div>
        {:else}
          <div class="ai-answer">{aiResult.answer.replace(/\*\*/g, "")}</div>
          <div class="ai-h">Sources</div>
          {#each aiResult.sources as s, i (i)}
            <button type="button" class="ai-src" onclick={() => openSource(s)} title={s.url ?? s.path}>
              <span class="ai-src-ic">{#if s.url}<Globe size={12} weight="fill" />{:else}<FileText size={12} weight="fill" />{/if}</span>
              <span class="ai-src-tx">
                <span class="ai-src-t">{s.title}</span>
                <span class="ai-src-s">{s.snippet}</span>
              </span>
              <ArrowUpRight size={12} weight="bold" class="ai-src-go" />
            </button>
          {/each}
          <div class="ai-h">Related</div>
          <div class="ai-rel">
            {#each aiResult.related as r, i (i)}
              <button type="button" class="ai-q" onclick={() => askRelated(r)}>{r}</button>
            {/each}
          </div>
        {/if}
      </div>
    {:else}
    <div class="results" role="listbox" aria-label="Search results">
      {#if groups.length === 0}
        <div class="empty">
          {busy ? "Searching…" : query ? "No matches." : mode === "internal" ? "Search across your files + workbooks." : "Search across files, bookmarks, tabs and the web."}
        </div>
      {:else}
        {#each groups as g (g.provider.id)}
          <div class="group-head">
            {#if g.provider.icon}{@const Icon = g.provider.icon}<Icon weight="fill" size={11} />{/if}
            <span>{g.provider.label}</span>
            {#if g.error}<span class="g-err">unavailable</span>{/if}
          </div>

          {#if g.provider.id === "web"}
            <!-- Web — a richer, search-engine-style group: an image strip +
                 cards with thumbnail, source host and snippet. -->
            {@const imgs = g.results.filter((r) => r.image)}
            {#if imgs.length}
              <div class="web-strip">
                {#each imgs as r, i (i)}
                  <button type="button" class="web-img" onclick={() => open(r)} title={r.title}>
                    <img src={r.image} alt="" />
                  </button>
                {/each}
              </div>
            {/if}
            {#each g.results as r, i (g.provider.id + (r.url ?? "") + i)}
              {@const fi = flatIndex(g, i)}
              <button
                type="button"
                class="web-card"
                class:active={fi === highlighted}
                role="option"
                aria-selected={fi === highlighted}
                onmouseenter={() => (highlighted = fi)}
                onclick={() => open(r)}
                title={r.url ?? r.title}
              >
                {#if r.image}<img class="web-thumb" src={r.image} alt="" />{/if}
                <span class="web-tx">
                  <span class="web-host">{r.host ?? r.url}</span>
                  <span class="web-title">{r.title}</span>
                  {#if r.subtitle}<span class="web-snip">{r.subtitle}</span>{/if}
                </span>
              </button>
            {/each}
          {:else}
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
          {/if}
        {/each}
      {/if}
    </div>
    {/if}
</aside>

<style>
  /* Floating rounded card on the right, matching the inset canvas (gaps,
   * radius, hairline border, soft shadow). Width is resizable (chrome). */
  .drawer {
    position: relative;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    margin: 0 8px 8px 0;
    border-radius: 12px;
    border: 1px solid var(--color-border);
    background: color-mix(in srgb, var(--color-surface) 92%, transparent);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    box-shadow:
      0 1px 2px rgba(15, 15, 15, 0.05),
      0 8px 28px rgba(15, 15, 15, 0.10);
  }
  .drawer.dragging { user-select: none; }
  /* Resize handle straddling the left edge. */
  .resize {
    position: absolute;
    top: 0;
    bottom: 0;
    left: -5px;
    width: 10px;
    padding: 0;
    border: 0;
    background: transparent;
    cursor: col-resize;
    z-index: 2;
  }
  .resize::after {
    content: "";
    position: absolute;
    inset: 8px 4px;
    border-radius: 2px;
    background: transparent;
    transition: background 0.15s;
  }
  .resize:hover::after,
  .resize.dragging::after { background: var(--color-border-strong); }

  .search-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin: 8px 8px 6px;
    padding: 0.5rem 0.7rem;
    border-radius: 9px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .search-row:focus-within { border-color: var(--color-border-strong); }
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

  /* AI mode — prompt → answer + sources + follow-ups. */
  .search-row.ai { color: var(--color-brand); }
  .ai-results { padding: 10px 12px 14px; }
  .ai-answer {
    font-size: 0.86rem;
    line-height: 1.55;
    color: var(--color-fg);
    margin-bottom: 14px;
  }
  .ai-h {
    display: block;
    font-family: var(--font-mono);
    font-size: 0.64rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
    margin: 12px 0 6px;
  }
  .ai-src {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    width: 100%;
    padding: 7px 8px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
    margin-bottom: 5px;
    transition: border-color 0.14s, background 0.14s;
  }
  .ai-src:hover { border-color: var(--color-border-strong); }
  .ai-src-ic { flex-shrink: 0; margin-top: 1px; color: var(--color-fg-subtle); }
  .ai-src-tx { display: flex; flex-direction: column; min-width: 0; flex: 1 1 auto; }
  .ai-src-t { font-size: 0.8rem; font-weight: 550; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .ai-src-s { font-size: 0.72rem; color: var(--color-fg-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .ai-src :global(.ai-src-go) { flex-shrink: 0; color: var(--color-fg-subtle); margin-top: 2px; }
  .ai-rel { display: flex; flex-direction: column; gap: 5px; }
  .ai-q {
    text-align: left;
    padding: 7px 10px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: transparent;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
    cursor: pointer;
    transition: border-color 0.14s, color 0.14s, background 0.14s;
  }
  .ai-q:hover { border-color: var(--color-border-strong); color: var(--color-fg); background: var(--color-surface-soft); }

  /* Web — search-engine-style: image strip + thumbnail cards. */
  .web-strip {
    display: flex;
    gap: 6px;
    overflow-x: auto;
    padding: 2px 12px 8px;
    scrollbar-width: none;
  }
  .web-strip::-webkit-scrollbar { display: none; }
  .web-img {
    flex: 0 0 auto;
    width: 84px;
    height: 60px;
    padding: 0;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    overflow: hidden;
    background: var(--color-surface-soft);
    cursor: pointer;
    transition: border-color 0.14s, transform 0.14s;
  }
  .web-img:hover { border-color: var(--color-border-strong); transform: translateY(-1px); }
  .web-img img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .web-card {
    display: flex;
    gap: 10px;
    width: calc(100% - 16px);
    margin: 0 8px 6px;
    padding: 8px;
    border: 1px solid var(--color-border);
    border-radius: 11px;
    background: var(--color-surface-soft);
    text-align: left;
    cursor: pointer;
    transition: border-color 0.14s, background 0.14s;
  }
  .web-card:hover,
  .web-card.active { border-color: var(--color-border-strong); background: var(--color-surface); }
  .web-thumb {
    flex: 0 0 auto;
    width: 56px;
    height: 56px;
    border-radius: 8px;
    object-fit: cover;
    display: block;
  }
  .web-tx { display: flex; flex-direction: column; min-width: 0; gap: 1px; }
  .web-host {
    font-family: var(--font-mono);
    font-size: 0.66rem;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .web-title {
    font-size: 0.85rem;
    font-weight: 550;
    color: var(--color-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .web-snip {
    font-size: 0.74rem;
    line-height: 1.4;
    color: var(--color-fg-muted);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
</style>
