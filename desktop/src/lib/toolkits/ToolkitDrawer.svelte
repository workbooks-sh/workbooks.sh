<script lang="ts">
  /**
   * ToolkitDrawer — the toolkit marketplace.
   *
   * A right-side floating card (mirrors the old search drawer's slot/position)
   * listing the real toolkit catalog (static/toolkits/catalog.json). Each card
   * reflects the org→workspace install lifecycle from toolkitStore: Add to the
   * org, then plug into the active workspace.
   */
  import { Toolbox, X, CircleNotch, Check } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { toolkitStore } from "$lib/toolkits/toolkitStore.svelte";

  let { onclose }: { onclose?: () => void } = $props();

  type Toolkit = {
    slug: string;
    title: string;
    tagline: string;
    description?: string;
    kind?: string;
    status?: string;
    category?: string;
    logo: string;
    tint?: string;
  };

  let toolkits = $state<Toolkit[]>([]);
  let query = $state("");
  let activeCat = $state<string>("All");

  onMount(() => {
    void fetch("/toolkits/catalog.json")
      .then((r) => r.json())
      .then((list: Toolkit[]) => { toolkits = list; })
      .catch((e) => console.warn("[toolkits] catalog load failed", e));
  });

  function titleCase(s: string): string {
    return s.replace(/\b\w/g, (c) => c.toUpperCase());
  }

  const categories = $derived([
    "All",
    ...Array.from(new Set(toolkits.map((t) => t.category).filter(Boolean) as string[])).sort(),
  ]);

  const filtered = $derived(
    toolkits.filter((t) => {
      if (activeCat !== "All" && t.category !== activeCat) return false;
      const q = query.trim().toLowerCase();
      if (!q) return true;
      return (
        t.title.toLowerCase().includes(q) ||
        t.tagline.toLowerCase().includes(q) ||
        (t.category ?? "").toLowerCase().includes(q)
      );
    }),
  );
</script>

<aside class="drawer" aria-label="Toolkits" style="width: {chrome.searchWidth}px">
  <header class="head">
    <span class="glyph"><Toolbox size={16} weight="fill" /></span>
    <div class="head-tx">
      <h2>Toolkits</h2>
      <p>Add to your organization, then plug into a workspace.</p>
    </div>
    <button type="button" class="close" aria-label="Close toolkits" onclick={() => (onclose ? onclose() : chrome.closeLeft())}>
      <X size={13} weight="bold" />
    </button>
  </header>

  <div class="filter-row">
    <input
      bind:value={query}
      type="text"
      placeholder="Filter toolkits…"
      spellcheck="false"
      autocomplete="off"
    />
  </div>

  {#if categories.length > 1}
    <div class="chips" role="tablist" aria-label="Categories">
      {#each categories as c (c)}
        <button
          type="button"
          class="chip"
          class:on={activeCat === c}
          role="tab"
          aria-selected={activeCat === c}
          onclick={() => (activeCat = c)}
        >{c}</button>
      {/each}
    </div>
  {/if}

  <div class="list" role="list">
    {#if filtered.length === 0}
      <div class="empty">{toolkits.length === 0 ? "Loading toolkits…" : "No matches."}</div>
    {:else}
      {#each filtered as t (t.slug)}
        {@const st = toolkitStore.statusOf(t.slug)}
        <div class="card" role="listitem">
          <span class="tile" style="background: color-mix(in srgb, {t.tint ?? '#888'} 22%, var(--color-surface)); border-color: color-mix(in srgb, {t.tint ?? '#888'} 45%, transparent);">
            <img src={t.logo} alt="" loading="lazy" />
          </span>
          <div class="meta">
            <div class="name-row">
              <span class="name">{titleCase(t.title)}</span>
              {#if t.category}<span class="cat">{t.category}</span>{/if}
            </div>
            <p class="tagline">{t.tagline}</p>
          </div>
          <div class="action">
            {#if st === "available"}
              <button type="button" class="btn primary" onclick={() => toolkitStore.addToOrg(t.slug)}>Add</button>
            {:else if st === "installing"}
              <span class="installing"><CircleNotch size={13} weight="bold" class="spin" /> {toolkitStore.isShipped(t.slug) ? "Installing…" : "Downloading…"}</span>
            {:else if st === "in-org"}
              <div class="org-stack">
                <span class="in-org">In org</span>
                <button type="button" class="btn" onclick={() => toolkitStore.addToWorkspace(t.slug)}>Add to workspace</button>
              </div>
            {:else}
              <span class="pill"><Check size={12} weight="bold" /> In workspace</span>
            {/if}
          </div>
        </div>
      {/each}
    {/if}
  </div>
</aside>

<style>
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
      0 8px 28px rgba(15, 15, 15, 0.1);
  }

  .head {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 12px 12px 10px;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
  }
  .glyph {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    flex-shrink: 0;
  }
  .head-tx { flex: 1; min-width: 0; }
  .head-tx h2 { margin: 0; font-size: 0.9rem; font-weight: 650; color: var(--color-fg); }
  .head-tx p { margin: 2px 0 0; font-size: 0.72rem; line-height: 1.4; color: var(--color-fg-muted); }
  .close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 6px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    cursor: pointer;
    flex-shrink: 0;
    transition: color 0.15s, background 0.15s;
  }
  .close:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .filter-row { padding: 10px 12px 0; flex-shrink: 0; }
  .filter-row input {
    width: 100%;
    padding: 0.5rem 0.7rem;
    border-radius: 9px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font-family: var(--font-mono);
    font-size: 13px;
    outline: 0;
    transition: border-color 0.15s;
  }
  .filter-row input:focus { border-color: var(--color-border-strong); }
  .filter-row input::placeholder { color: var(--color-fg-subtle); }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: 5px;
    padding: 8px 12px 2px;
    flex-shrink: 0;
  }
  .chip {
    padding: 3px 9px;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: transparent;
    color: var(--color-fg-muted);
    font-size: 0.7rem;
    font-weight: 500;
    cursor: pointer;
    transition: border-color 0.14s, color 0.14s, background 0.14s;
  }
  .chip:hover { border-color: var(--color-border-strong); color: var(--color-fg); }
  .chip.on {
    color: var(--color-fg);
    border-color: var(--color-border-strong);
    background: var(--color-surface-soft);
  }

  .list {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .empty {
    padding: 1.5rem 1rem;
    text-align: center;
    color: var(--color-fg-muted);
    font-size: 0.8rem;
  }

  .card {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    padding: 9px 10px;
    border: 1px solid var(--color-border);
    border-radius: 11px;
    background: var(--color-surface-soft);
    transition: border-color 0.14s, background 0.14s;
  }
  .card:hover { border-color: var(--color-border-strong); }
  .tile {
    display: grid;
    place-items: center;
    width: 38px;
    height: 38px;
    border-radius: 10px;
    border: 1px solid transparent;
    flex-shrink: 0;
  }
  .tile img { width: 22px; height: 22px; object-fit: contain; }

  .meta { flex: 1 1 auto; min-width: 0; }
  .name-row { display: flex; align-items: center; gap: 7px; }
  .name {
    font-size: 0.82rem;
    font-weight: 600;
    color: var(--color-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cat {
    flex-shrink: 0;
    font-family: var(--font-mono);
    font-size: 0.58rem;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
    padding: 1px 5px;
    border-radius: 5px;
    background: var(--color-surface);
  }
  .tagline {
    margin: 3px 0 0;
    font-size: 0.72rem;
    line-height: 1.4;
    color: var(--color-fg-muted);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .action { flex-shrink: 0; display: flex; align-items: center; }
  .btn {
    padding: 5px 11px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface);
    color: var(--color-fg);
    font-size: 0.74rem;
    font-weight: 600;
    cursor: pointer;
    white-space: nowrap;
    transition: border-color 0.14s, background 0.14s, filter 0.12s;
  }
  .btn:hover { border-color: var(--color-border-strong); }
  .btn.primary {
    border-color: transparent;
    background: var(--color-fg);
    color: var(--color-page);
  }
  .btn.primary:hover { filter: brightness(1.08); }

  .org-stack { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; }
  .in-org {
    font-family: var(--font-mono);
    font-size: 0.6rem;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
  }

  .installing {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    white-space: nowrap;
  }
  :global(.installing .spin) { animation: tk-spin 0.8s linear infinite; }
  @keyframes tk-spin { to { transform: rotate(360deg); } }

  .pill {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 9px;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    white-space: nowrap;
    color: var(--color-ok, var(--color-chip-green));
    background: color-mix(in srgb, var(--color-chip-green) 16%, var(--color-surface));
    border: 1px solid color-mix(in srgb, var(--color-chip-green) 40%, transparent);
  }
</style>
