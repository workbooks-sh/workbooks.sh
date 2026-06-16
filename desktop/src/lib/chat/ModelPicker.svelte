<script lang="ts">
  /**
   * ModelPicker — single dropdown over OpenRouter's full catalog,
   * models grouped by vendor inside the menu. No separate
   * "provider" dropdown — the model ID IS "<vendor>/<model>" and
   * the picker already shows the vendor grouping.
   *
   * Replaces the previous ProviderModelPicker (two cascading
   * dropdowns) per user feedback: 'we don't need to say provider
   * there because everything is always a path of the provider and
   * the model.'
   *
   * Mirrors archive/studio/frontend/src/lib/components/chat/ModelPicker.svelte
   * — same UX shape, scoped to what the desktop already has.
   *
   * Value is the raw OpenRouter model id (e.g.
   * "anthropic/claude-sonnet-4-6"). When the agent eventually
   * routes to a non-OpenRouter provider directly, that consumer
   * will read the same string and route appropriately.
   */
  import { CaretDown as ChevronDown, CircleNotch as Loader2, MagnifyingGlass as Search } from "phosphor-svelte";
  import { onMount } from "svelte";

  interface Model {
    id: string;
    name: string;
    vendor: string;
    contextLength: number | null;
  }

  // Curated recommendations, in priority order — cheaper-but-better + multimodal
  // first. Pinned to the top of the picker (when not searching). Only the ones
  // actually present in the live OpenRouter catalog are shown, so this list can
  // evolve without showing dead entries.
  const RECOMMENDED: { id: string; tag: string }[] = [
    { id: "minimax/minimax-m3", tag: "Best value" },
    { id: "google/gemini-3.5-flash", tag: "Recommended" },
    { id: "google/gemini-3.1-flash-image-preview", tag: "Multimodal" },
    { id: "anthropic/claude-opus-4.8", tag: "Top tier" },
    { id: "openai/gpt-5.5", tag: "Top tier" },
    { id: "x-ai/grok-4.20", tag: "Top tier" },
  ];

  let {
    value = $bindable(""),
    placeholder = "Pick a model",
    onchange,
    compact = false,
  }: {
    value: string;
    placeholder?: string;
    onchange?: (v: string) => void;
    // compact = model-name-only trigger sized for an action row (e.g. the chat
    // composer next to send) — drops the vendor prefix to stay narrow.
    compact?: boolean;
  } = $props();

  let triggerEl = $state<HTMLButtonElement | null>(null);
  let menuEl = $state<HTMLDivElement | null>(null);
  let searchEl = $state<HTMLInputElement | null>(null);

  let open = $state(false);
  let query = $state("");
  let highlight = $state(0);

  // Fixed-position coords for the menu — `position: fixed` escapes
  // any `overflow: hidden` on ancestors (e.g. the AgentEditor modal),
  // which was clipping the dropdown inline. Computed off the
  // trigger's getBoundingClientRect on open + on resize/scroll.
  let pos = $state<{ top: number; left: number; width: number } | null>(null);

  const MENU_WIDTH = 380;
  const MENU_HEIGHT_EST = 420;

  function reposition() {
    if (!triggerEl) return;
    const r = triggerEl.getBoundingClientRect();
    let top = r.bottom + 4;
    let left = r.left;
    if (left + MENU_WIDTH > window.innerWidth - 8) {
      left = Math.max(8, window.innerWidth - MENU_WIDTH - 8);
    }
    // Flip upward when there's no room below the trigger.
    if (top + MENU_HEIGHT_EST > window.innerHeight - 8) {
      top = Math.max(8, r.top - MENU_HEIGHT_EST - 4);
    }
    pos = { top, left, width: MENU_WIDTH };
  }

  let models = $state<Model[]>([]);
  let loading = $state(true);
  let loadError = $state<string | null>(null);

  function vendorLabel(v: string): string {
    if (v === "openai") return "OpenAI";
    if (v === "xai") return "xAI";
    if (v === "deepseek") return "DeepSeek";
    if (v === "meta-llama") return "Meta";
    if (v === "x-ai") return "xAI";
    return v
      .split("-")
      .map((s) => (s ? s[0].toUpperCase() + s.slice(1) : s))
      .join(" ");
  }

  onMount(async () => {
    try {
      const r = await fetch("https://openrouter.ai/api/v1/models");
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const body = (await r.json()) as {
        data: { id: string; name?: string; context_length?: number }[];
      };
      models = (body.data ?? []).map((m) => {
        const slash = m.id.indexOf("/");
        const vendor = slash >= 0 ? m.id.slice(0, slash) : "other";
        return {
          id: m.id,
          name: m.name ?? m.id,
          vendor,
          contextLength: m.context_length ?? null,
        };
      });
    } catch (e) {
      loadError = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  });

  const filtered = $derived<Model[]>(
    (() => {
      const q = query.trim().toLowerCase();
      if (!q) return models;
      return models.filter(
        (m) =>
          m.id.toLowerCase().includes(q) ||
          m.name.toLowerCase().includes(q) ||
          m.vendor.toLowerCase().includes(q),
      );
    })(),
  );

  // Stable vendor-grouped buckets, sorted A→Z.
  const grouped = $derived<[string, Model[]][]>(
    (() => {
      const buckets = new Map<string, Model[]>();
      for (const m of filtered) {
        const arr = buckets.get(m.vendor) ?? [];
        arr.push(m);
        buckets.set(m.vendor, arr);
      }
      return [...buckets.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    })(),
  );

  // Recommended models that exist in the catalog, in RECOMMENDED order. Shown as
  // a pinned section at the top when there's no active search query.
  const recommended = $derived<{ model: Model; tag: string }[]>(
    RECOMMENDED.flatMap(({ id, tag }) => {
      const model = models.find((m) => m.id === id);
      return model ? [{ model, tag }] : [];
    }),
  );
  const showRecommended = $derived(!query.trim() && recommended.length > 0);

  // Keyboard nav order: recommended first (when shown), then the grouped rest.
  const flatVisible = $derived<Model[]>([
    ...(showRecommended ? recommended.map((r) => r.model) : []),
    ...grouped.flatMap(([_v, ms]) => ms),
  ]);

  const selectedModel = $derived(models.find((m) => m.id === value) ?? null);

  function toggle() {
    open = !open;
    if (open) {
      query = "";
      highlight = Math.max(
        0,
        flatVisible.findIndex((m) => m.id === value),
      );
      queueMicrotask(() => {
        reposition();
        searchEl?.focus();
      });
    }
  }

  function pick(m: Model) {
    value = m.id;
    onchange?.(m.id);
    open = false;
  }

  function onKey(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === "Escape") {
      e.preventDefault();
      open = false;
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      highlight = Math.min(highlight + 1, flatVisible.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      highlight = Math.max(highlight - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const m = flatVisible[highlight];
      if (m) pick(m);
    }
  }

  $effect(() => {
    if (!open) return;
    reposition();
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (menuEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    document.addEventListener("mousedown", away);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    return () => {
      document.removeEventListener("mousedown", away);
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  });
</script>

<svelte:window onkeydown={onKey} />

<div class="picker">
  <button
    type="button"
    bind:this={triggerEl}
    class="trigger"
    class:open
    class:compact
    onclick={toggle}
    aria-expanded={open}
    aria-haspopup="listbox"
  >
    {#if value && selectedModel}
      {#if !compact}<span class="vendor">{vendorLabel(selectedModel.vendor)}</span><span class="sep">/</span>{/if}
      <span class="model">{selectedModel.name}</span>
    {:else if value}
      <span class="model">{value}</span>
    {:else}
      <span class="placeholder">{placeholder}</span>
    {/if}
    <ChevronDown weight="bold" size={12} class="chev" aria-hidden="true" />
  </button>

  {#if open && pos}
    <div
      bind:this={menuEl}
      class="menu"
      role="listbox"
      style:top="{pos.top}px"
      style:left="{pos.left}px"
      style:width="{pos.width}px"
    >
      <div class="search">
        <Search weight="bold" size={11} aria-hidden="true" />
        <input
          bind:this={searchEl}
          type="text"
          placeholder={loading
            ? "Loading…"
            : loadError
              ? "Search failed"
              : `Search ${models.length} models`}
          bind:value={query}
          oninput={() => (highlight = 0)}
        />
      </div>
      <div class="list">
        {#if loading}
          <div class="state">
            <Loader2 weight="bold" size={12} class="spin" />
            Loading OpenRouter catalog…
          </div>
        {:else if loadError}
          <div class="state err">{loadError}</div>
        {:else if filtered.length === 0}
          <div class="state">No models match "{query}".</div>
        {:else}
          {#if showRecommended}
            <div class="section-head rec">★ Recommended</div>
            {#each recommended as { model: m, tag } (m.id)}
              {@const i = flatVisible.findIndex((x) => x.id === m.id)}
              <button
                type="button"
                class="row"
                class:selected={m.id === value}
                class:active={i === highlight}
                onclick={() => pick(m)}
                onmouseenter={() => (highlight = i)}
              >
                <span class="row-name">{m.name}</span>
                <span class="row-tag">{tag}</span>
                {#if m.contextLength}
                  <span class="row-ctx">{Math.round(m.contextLength / 1000)}k</span>
                {/if}
              </button>
            {/each}
            <div class="rec-sep"></div>
          {/if}
          {#each grouped as [vendor, ms] (vendor)}
            <div class="section-head">{vendorLabel(vendor)}</div>
            {#each ms as m (m.id)}
              {@const i = flatVisible.findIndex((x) => x.id === m.id)}
              <button
                type="button"
                class="row"
                class:selected={m.id === value}
                class:active={i === highlight}
                onclick={() => pick(m)}
                onmouseenter={() => (highlight = i)}
              >
                <span class="row-name">{m.name}</span>
                {#if m.contextLength}
                  <span class="row-ctx">{Math.round(m.contextLength / 1000)}k</span>
                {/if}
              </button>
            {/each}
          {/each}
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .picker {
    position: relative;
    display: inline-block;
    min-width: 0;
  }
  .trigger {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    height: 28px;
    padding: 0 0.4rem 0 0.5rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    color: var(--color-fg);
    font: inherit;
    font-size: 12.5px;
    cursor: pointer;
    max-width: 320px;
    min-width: 0;
  }
  .trigger.compact {
    height: 28px;
    border-radius: 999px;
    padding: 0 0.5rem;
    max-width: 150px;
    font-size: 12px;
    color: var(--color-fg-subtle);
  }
  .trigger:hover,
  .trigger.open {
    border-color: var(--color-fg-subtle);
  }
  .vendor {
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .sep {
    color: var(--color-fg-subtle);
    flex-shrink: 0;
  }
  .model {
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }
  .placeholder {
    color: var(--color-fg-muted);
  }
  :global(.picker .trigger .chev) {
    color: var(--color-fg-subtle);
    margin-left: 0.15rem;
    flex-shrink: 0;
  }
  .menu {
    /* Fixed positioning so the dropdown escapes the modal's
     * overflow: hidden context. Coords come from getBoundingClientRect
     * via reposition() — kept in sync on resize + scroll. */
    position: fixed;
    z-index: 1300;
    max-height: 420px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    box-shadow: var(--shadow-pop, 0 8px 24px rgba(0, 0, 0, 0.3));
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .search {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.5rem 0.6rem;
    border-bottom: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .search input {
    flex: 1;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 13px;
    outline: none;
  }
  .list {
    overflow-y: auto;
    padding: 0.3rem 0;
  }
  .section-head {
    padding: 0.4rem 0.7rem 0.2rem;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.35rem 0.7rem;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
  }
  .row:hover,
  .row.active {
    background: var(--color-surface-soft);
  }
  .row.selected {
    background: var(--color-surface-soft);
    font-weight: 600;
  }
  .row-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-ctx {
    flex-shrink: 0;
    font-size: 11px;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    padding: 0.05em 0.35em;
    border-radius: 3px;
    font-family:
      ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  }
  .section-head.rec {
    color: var(--color-brand, #13d943);
  }
  .row-tag {
    flex-shrink: 0;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: var(--color-brand, #13d943);
    background: color-mix(in srgb, var(--color-brand, #13d943) 12%, transparent);
    padding: 0.1em 0.45em;
    border-radius: 999px;
  }
  .rec-sep {
    height: 1px;
    background: var(--color-border);
    margin: 0.3rem 0.5rem;
  }
  .state {
    padding: 0.85rem 0.7rem;
    font-size: 12.5px;
    color: var(--color-fg-muted);
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
  }
  .state.err {
    color: #fca5a5;
  }
  :global(.spin) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
