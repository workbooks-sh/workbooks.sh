<script lang="ts">
  /**
   * Pagination — a stateless page control in the app's monochrome chrome.
   *
   * Renders: a left-side range label ("21–40 of 137"), a windowed page
   * strip (first / … / neighbours / … / last) with prev+next chevrons,
   * and an optional page-size selector. It owns no state — `page` and
   * `pageSize` are props, and it emits `onpage` / `onsize` so the parent
   * stays the single source of truth (and can persist via the store).
   *
   * `page` is 1-based. Buttons disable at the ends; the active page is
   * inverted (fg/page) like the rail's active tabs.
   */
  import { ChevronLeft, ChevronRight } from "@lucide/svelte";

  let {
    page,
    pageSize,
    total,
    sizes = [10, 20, 50],
    onpage,
    onsize,
  }: {
    page: number;
    pageSize: number;
    total: number;
    sizes?: number[];
    onpage: (p: number) => void;
    onsize?: (n: number) => void;
  } = $props();

  const pageCount = $derived(Math.max(1, Math.ceil(total / pageSize)));
  const from = $derived(total === 0 ? 0 : (page - 1) * pageSize + 1);
  const to = $derived(Math.min(page * pageSize, total));

  // Windowed strip: 1, …, p-1, p, p+1, …, N. `0` is an ellipsis marker.
  const strip = $derived.by<number[]>(() => {
    const n = pageCount;
    if (n <= 7) return Array.from({ length: n }, (_, i) => i + 1);
    const out: number[] = [1];
    const lo = Math.max(2, page - 1);
    const hi = Math.min(n - 1, page + 1);
    if (lo > 2) out.push(0);
    for (let i = lo; i <= hi; i++) out.push(i);
    if (hi < n - 1) out.push(0);
    out.push(n);
    return out;
  });

  function go(p: number) {
    const clamped = Math.min(pageCount, Math.max(1, p));
    if (clamped !== page) onpage(clamped);
  }
</script>

<nav class="pager" aria-label="Pagination">
  <span class="range">
    {#if total === 0}No items{:else}{from}–{to} of {total}{/if}
  </span>

  <div class="nav">
    <button class="step" disabled={page <= 1} aria-label="Previous page" onclick={() => go(page - 1)}>
      <ChevronLeft size={15} strokeWidth={1.9} />
    </button>

    {#each strip as p, i (i)}
      {#if p === 0}
        <span class="gap" aria-hidden="true">…</span>
      {:else}
        <button
          class="num"
          class:active={p === page}
          aria-label={`Page ${p}`}
          aria-current={p === page ? "page" : undefined}
          onclick={() => go(p)}
        >{p}</button>
      {/if}
    {/each}

    <button class="step" disabled={page >= pageCount} aria-label="Next page" onclick={() => go(page + 1)}>
      <ChevronRight size={15} strokeWidth={1.9} />
    </button>
  </div>

  {#if onsize}
    <label class="size">
      <span>Per page</span>
      <select value={pageSize} onchange={(e) => onsize?.(Number(e.currentTarget.value))}>
        {#each sizes as s (s)}
          <option value={s}>{s}</option>
        {/each}
      </select>
    </label>
  {/if}
</nav>

<style>
  .pager {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    flex-wrap: wrap;
  }
  .range {
    font-size: 0.74rem;
    color: var(--color-fg-muted);
    min-width: 5.5rem;
  }
  .nav {
    display: flex;
    align-items: center;
    gap: 0.2rem;
    margin-left: auto;
  }
  .step,
  .num {
    min-width: 28px;
    height: 28px;
    padding: 0 0.3rem;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font-size: 0.76rem;
    display: grid;
    place-items: center;
    cursor: pointer;
    transition: background 0.12s ease, color 0.12s ease;
  }
  .step:hover:not(:disabled),
  .num:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .num.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: transparent;
    font-weight: 600;
  }
  .step:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .gap {
    width: 18px;
    text-align: center;
    color: var(--color-fg-subtle);
    font-size: 0.76rem;
    user-select: none;
  }
  .size {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
  }
  .size select {
    height: 28px;
    padding: 0 0.35rem;
    border-radius: 7px;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.74rem;
    cursor: pointer;
  }
</style>
