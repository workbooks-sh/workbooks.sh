<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { listActivity } from "$lib/api.js";
  import type { Activity } from "$lib/api.js";
  import Spinner from "$lib/components/Spinner.svelte";

  // NOTE (wb-c4hs.2): GET /v1/activity is not yet implemented on the API side.

  let items = $state<Activity[]>([]);
  let loading = $state(true);
  let apiDown = $state(false);
  let nextCursor = $state<string | undefined>(undefined);
  let loadingMore = $state(false);

  let filter = $state("");
  let scrollEl = $state<HTMLElement | null>(null);
  let atTop = $state(true);

  let filteredItems = $derived(
    filter.trim()
      ? items.filter((a) =>
          a.verb_id.toLowerCase().includes(filter.trim().toLowerCase()),
        )
      : items,
  );

  async function load(cursor?: string) {
    if (cursor) {
      loadingMore = true;
    } else {
      loading = true;
      apiDown = false;
    }
    try {
      const res = await listActivity({ limit: 100, cursor });
      if (!cursor) {
        items = res.items;
      } else {
        items = [...items, ...res.items];
      }
      nextCursor = res.next_cursor;
      if (res.items.length === 0 && !cursor) {
        apiDown = true;
      }
    } finally {
      loading = false;
      loadingMore = false;
    }
  }

  function handleScroll() {
    if (!scrollEl) return;
    atTop = scrollEl.scrollTop < 40;
  }

  let refreshTimer: ReturnType<typeof setInterval> | undefined;

  function startRefresh() {
    refreshTimer = setInterval(() => {
      if (atTop) load();
    }, 10_000);
  }

  onMount(async () => {
    await load();
    startRefresh();
  });

  onDestroy(() => {
    if (refreshTimer !== undefined) clearInterval(refreshTimer);
  });

  function fmtTime(ts: string): string {
    try {
      return new Date(ts).toLocaleTimeString("en-US", {
        hour12: false,
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
    } catch {
      return ts;
    }
  }

  function fmtDuration(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(1)}s`;
  }

  function fmtCost(usd: number): string {
    if (usd === 0) return "$0.000";
    if (usd < 0.001) return `$${usd.toFixed(5)}`;
    if (usd < 0.01) return `$${usd.toFixed(4)}`;
    return `$${usd.toFixed(3)}`;
  }
</script>

<svelte:head>
  <title>Activity — brandnana portal</title>
</svelte:head>

<div class="flex flex-col gap-4">
  <div class="flex flex-col gap-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">activity</h2>
    <p class="text-fg-muted text-xs">
      Append-only feed of API calls. Auto-refreshes every 10s when scrolled to top.
    </p>
  </div>

  <div class="flex items-center gap-3">
    <input
      class="input max-w-xs"
      type="text"
      placeholder="filter by verb id…"
      bind:value={filter}
    />
    {#if !atTop}
      <span class="chip warn">[paused — scroll to top to resume]</span>
    {:else}
      <span class="chip ok">[live]</span>
    {/if}
  </div>

  {#if loading}
    <div class="flex items-center gap-2 text-fg-muted text-xs py-4">
      <Spinner size={16} /> loading activity…
    </div>
  {:else if apiDown}
    <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
      <span class="muted">// activity feed</span>
      <span class="chip warn">[coming soon — endpoint not yet wired]</span>
      <p class="subtle">
        Planned endpoint: <code class="font-mono">GET /v1/activity?limit=100&amp;cursor=&lt;cursor&gt;</code>
      </p>
    </div>
  {:else if filteredItems.length === 0}
    <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
      <span class="muted">no activity yet</span>
      {#if filter}
        <p class="subtle">no calls matching <code class="font-mono">{filter}</code></p>
      {:else}
        <p class="subtle">make your first API call to see it here.</p>
      {/if}
    </div>
  {:else}
    <div
      class="overflow-auto max-h-[600px] border border-border-warm rounded-sm"
      bind:this={scrollEl}
      onscroll={handleScroll}
    >
      <table>
        <thead>
          <tr>
            <th>time</th>
            <th>verb</th>
            <th>source</th>
            <th>duration</th>
            <th>cost</th>
            <th>status</th>
          </tr>
        </thead>
        <tbody>
          {#each filteredItems as a (a.id)}
            <tr>
              <td class="font-mono muted text-xs">{fmtTime(a.ts)}</td>
              <td class="font-mono text-xs">{a.verb_id}</td>
              <td class="font-mono muted text-xs">{a.source}</td>
              <td class="font-mono muted text-xs">{fmtDuration(a.duration_ms)}</td>
              <td class="font-mono muted text-xs">{fmtCost(a.cost_usd)}</td>
              <td>
                {#if a.status === "ok"}
                  <span class="chip ok">[ok]</span>
                {:else}
                  <span class="chip error" title={a.error ?? "error"}>[error]</span>
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>

    {#if nextCursor}
      <div class="flex justify-start">
        <button
          class="btn"
          onclick={() => load(nextCursor)}
          disabled={loadingMore}
          type="button"
        >
          {#if loadingMore}<Spinner />{/if}
          [load more]
        </button>
      </div>
    {/if}
  {/if}
</div>
