<script lang="ts">
  import { onMount } from "svelte";
  import { listData } from "$lib/api.js";
  import type { DataRow } from "$lib/api.js";
  import Spinner from "$lib/components/Spinner.svelte";

  // NOTE (wb-c4hs.2): GET /v1/data/{catalog|ads|briefs} is not yet implemented.

  type Tab = "catalog" | "ads" | "briefs";

  const TABS: { id: Tab; label: string }[] = [
    { id: "catalog", label: "catalog crawls" },
    { id: "ads", label: "ads" },
    { id: "briefs", label: "briefs" },
  ];

  let activeTab = $state<Tab>("catalog");

  type TabState = {
    items: DataRow[];
    nextCursor?: string;
    loading: boolean;
    loadingMore: boolean;
    apiDown: boolean;
    loaded: boolean;
  };

  function emptyTabState(): TabState {
    return {
      items: [],
      nextCursor: undefined,
      loading: false,
      loadingMore: false,
      apiDown: false,
      loaded: false,
    };
  }

  let tabState = $state<Record<Tab, TabState>>({
    catalog: emptyTabState(),
    ads: emptyTabState(),
    briefs: emptyTabState(),
  });

  async function loadTab(tab: Tab, cursor?: string) {
    const s = tabState[tab];
    if (cursor) {
      s.loadingMore = true;
    } else {
      s.loading = true;
      s.apiDown = false;
    }

    try {
      const res = await listData(tab, { limit: 50, cursor });
      if (!cursor) {
        s.items = res.items;
      } else {
        s.items = [...s.items, ...res.items];
      }
      s.nextCursor = res.next_cursor;
      s.loaded = true;
      if (res.items.length === 0 && !cursor) {
        s.apiDown = true;
      }
    } finally {
      s.loading = false;
      s.loadingMore = false;
    }
  }

  function switchTab(tab: Tab) {
    activeTab = tab;
    if (!tabState[tab].loaded) {
      loadTab(tab);
    }
  }

  onMount(() => {
    loadTab("catalog");
  });

  function fmtDate(ts: string): string {
    try {
      return new Date(ts).toLocaleString("en-US", {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      });
    } catch {
      return ts;
    }
  }

  function fmtDuration(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    return `${(ms / 60_000).toFixed(1)}m`;
  }
</script>

<svelte:head>
  <title>Data — brandnana portal</title>
</svelte:head>

<div class="flex flex-col gap-4">
  <div class="flex flex-col gap-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">data</h2>
    <p class="text-fg-muted text-xs">
      Paginated tables of catalog crawls, ad pulls, and brief outputs stored in R2.
    </p>
  </div>

  <!-- Tabs -->
  <div class="flex gap-0 border-b border-border-warm">
    {#each TABS as tab (tab.id)}
      <button
        class="bg-transparent border-none border-b-2 px-3.5 py-1.5 text-fg-muted text-xs cursor-pointer mb-[-1px] transition-colors hover:text-fg"
        class:tab-active={activeTab === tab.id}
        onclick={() => switchTab(tab.id)}
        type="button"
      >
        {tab.label}
      </button>
    {/each}
  </div>

  <!-- Tab content -->
  {#each TABS as tab (tab.id)}
    {#if activeTab === tab.id}
      {@const s = tabState[tab.id]}
      {#if s.loading}
        <div class="flex items-center gap-2 text-fg-muted text-xs py-4">
          <Spinner size={16} /> loading {tab.label}…
        </div>
      {:else if s.apiDown}
        <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
          <span class="muted">// {tab.label}</span>
          <span class="chip warn">[coming soon — endpoint not yet wired]</span>
          <p class="subtle">
            Planned endpoint: <code class="font-mono">GET /v1/data/{tab.id}?limit=50&amp;cursor=&lt;cursor&gt;</code>
          </p>
        </div>
      {:else if s.items.length === 0}
        <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
          <span class="muted">no {tab.label} yet</span>
          <p class="subtle">run a verb to see results here.</p>
        </div>
      {:else}
        <div class="overflow-x-auto border border-border-warm rounded-sm">
          <table>
            <thead>
              <tr>
                <th>run id</th>
                <th>target</th>
                <th>started</th>
                <th>duration</th>
                <th>status</th>
                <th>download</th>
              </tr>
            </thead>
            <tbody>
              {#each s.items as row (row.id)}
                <tr>
                  <td class="font-mono muted text-xs max-w-28 overflow-hidden text-ellipsis whitespace-nowrap">{row.id}</td>
                  <td class="font-mono text-xs max-w-48 overflow-hidden text-ellipsis whitespace-nowrap">{row.target}</td>
                  <td class="font-mono muted text-xs">{fmtDate(row.started_at)}</td>
                  <td class="font-mono muted text-xs">{fmtDuration(row.duration_ms)}</td>
                  <td>
                    {#if row.status === "ok"}
                      <span class="chip ok">[ok]</span>
                    {:else if row.status === "running"}
                      <span class="chip warn">[running]</span>
                    {:else}
                      <span class="chip error">[error]</span>
                    {/if}
                  </td>
                  <td>
                    {#if row.r2_url}
                      <a href={row.r2_url} class="text-xs text-fg-muted no-underline hover:text-fg" target="_blank" rel="noreferrer">[download]</a>
                    {:else}
                      <span class="subtle">—</span>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>

        {#if s.nextCursor}
          <div class="flex justify-start">
            <button
              class="btn"
              onclick={() => loadTab(tab.id, s.nextCursor)}
              disabled={s.loadingMore}
              type="button"
            >
              {#if s.loadingMore}<Spinner />{/if}
              [load more]
            </button>
          </div>
        {/if}
      {/if}
    {/if}
  {/each}
</div>

<style>
  .tab-active {
    color: var(--color-fg);
    border-bottom-color: var(--color-banana-deep);
  }
</style>
