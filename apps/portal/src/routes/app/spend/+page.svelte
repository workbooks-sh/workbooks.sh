<script lang="ts">
  import { onMount } from "svelte";
  import { getSpend } from "$lib/api.js";
  import type { SpendBucket } from "$lib/api.js";
  import Spinner from "$lib/components/Spinner.svelte";

  // NOTE (wb-c4hs.2): GET /v1/spend is not yet implemented on the API side.

  let loading = $state(true);
  let apiDown = $state(false);

  let dayBuckets = $state<SpendBucket[]>([]);
  let dayTotal = $state(0);

  let providerBuckets = $state<SpendBucket[]>([]);
  let verbBuckets = $state<SpendBucket[]>([]);

  let thisMonth = $state(0);
  let today = $state(0);
  let thisHour = $state(0);

  function isoDate(d: Date): string {
    return d.toISOString().slice(0, 10);
  }

  async function load() {
    loading = true;
    apiDown = false;

    const now = new Date();
    const monthStart = isoDate(new Date(now.getFullYear(), now.getMonth(), 1));
    const todayStr = isoDate(now);

    try {
      const [dayRes, provRes, verbRes] = await Promise.all([
        getSpend({ from: monthStart, to: todayStr, group_by: "day" }),
        getSpend({ from: monthStart, to: todayStr, group_by: "provider" }),
        getSpend({ from: monthStart, to: todayStr, group_by: "verb" }),
      ]);

      dayBuckets = dayRes.buckets;
      dayTotal = dayRes.total_usd;
      providerBuckets = provRes.buckets;
      verbBuckets = verbRes.buckets;

      thisMonth = dayBuckets.reduce((s, b) => s + b.cost_usd, 0);
      const todayBucket = dayBuckets.find((b) => b.key === todayStr);
      today = todayBucket?.cost_usd ?? 0;
      thisHour = 0;

      if (dayBuckets.length === 0 && providerBuckets.length === 0) {
        apiDown = true;
      }
    } finally {
      loading = false;
    }
  }

  onMount(load);

  function fmtUsd(v: number, decimals = 2): string {
    return "$" + v.toFixed(decimals);
  }

  let chartRows = $derived(() => {
    const now = new Date();
    const rows: { label: string; value: number }[] = [];
    for (let i = 29; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
      const key = isoDate(d);
      const bucket = dayBuckets.find((b) => b.key === key);
      rows.push({ label: key.slice(5), value: bucket?.cost_usd ?? 0 });
    }
    return rows;
  });

  let maxBarValue = $derived(() => {
    const rows = chartRows();
    return Math.max(...rows.map((r) => r.value), 0.001);
  });

  const BAR_WIDTH = 32;

  function barStr(value: number, max: number): string {
    const filled = Math.round((value / max) * BAR_WIDTH);
    return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled);
  }
</script>

<svelte:head>
  <title>Spend — brandnana portal</title>
</svelte:head>

<div class="flex flex-col gap-5">
  <div class="flex flex-col gap-1">
    <h2 class="font-serif text-base font-normal text-fg tracking-tight">spend</h2>
    <p class="text-fg-muted text-xs">Cost breakdown across calls, providers, and verbs.</p>
  </div>

  {#if loading}
    <div class="flex items-center gap-2 text-fg-muted text-xs py-4">
      <Spinner size={16} /> loading spend data…
    </div>
  {:else if apiDown}
    <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
      <span class="muted">// spend analytics</span>
      <span class="chip warn">[coming soon — endpoint not yet wired]</span>
      <p class="subtle">
        Planned endpoint: <code class="font-mono">GET /v1/spend?from=YYYY-MM-DD&amp;to=YYYY-MM-DD&amp;group_by=day|provider|verb</code>
      </p>
    </div>
  {:else}
    <!-- Summary big numbers -->
    <div class="flex flex-wrap gap-4">
      <div class="bg-bg-cream border border-border-warm rounded-sm px-5 py-3.5 flex flex-col gap-1 min-w-36">
        <span class="text-fg-muted text-xs uppercase tracking-wider">this month</span>
        <span class="text-2xl text-fg tracking-tight">{fmtUsd(thisMonth)}</span>
      </div>
      <div class="bg-bg-cream border border-border-warm rounded-sm px-5 py-3.5 flex flex-col gap-1 min-w-36">
        <span class="text-fg-muted text-xs uppercase tracking-wider">today</span>
        <span class="text-2xl text-fg tracking-tight">{fmtUsd(today)}</span>
      </div>
      <div class="bg-bg-cream border border-border-warm rounded-sm px-5 py-3.5 flex flex-col gap-1 min-w-36">
        <span class="text-fg-muted text-xs uppercase tracking-wider">this hour</span>
        <span class="text-2xl text-fg tracking-tight">{fmtUsd(thisHour, 4)}</span>
      </div>
    </div>

    <!-- 30-day ASCII bar chart -->
    <div class="section">
      <div class="section-title">30-day cost chart</div>
      {#if dayBuckets.length === 0}
        <p class="subtle text-xs">no data yet</p>
      {:else}
        <div class="flex flex-col gap-px text-xs overflow-x-auto font-mono">
          {#each chartRows() as row (row.label)}
            <div class="flex items-baseline gap-2 whitespace-nowrap">
              <span class="text-fg-muted w-10 shrink-0">{row.label}</span>
              <span class="text-fg-subtle tracking-tighter">{barStr(row.value, maxBarValue())}</span>
              <span class="text-fg-muted w-16 text-right shrink-0">{fmtUsd(row.value, 3)}</span>
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <!-- Provider breakdown -->
    {#if providerBuckets.length > 0}
      <div class="section">
        <div class="section-title">by provider</div>
        <table>
          <thead>
            <tr>
              <th>provider</th>
              <th>calls</th>
              <th>total</th>
              <th>avg / call</th>
            </tr>
          </thead>
          <tbody>
            {#each providerBuckets as b (b.key)}
              <tr>
                <td class="font-mono text-xs">{b.key}</td>
                <td class="font-mono muted text-xs">{b.calls.toLocaleString()}</td>
                <td class="font-mono text-xs">{fmtUsd(b.cost_usd, 3)}</td>
                <td class="font-mono muted text-xs">{fmtUsd(b.avg_cost_usd, 4)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    <!-- Verb breakdown -->
    {#if verbBuckets.length > 0}
      <div class="section">
        <div class="section-title">by verb</div>
        <table>
          <thead>
            <tr>
              <th>verb</th>
              <th>calls</th>
              <th>total</th>
              <th>avg / call</th>
            </tr>
          </thead>
          <tbody>
            {#each verbBuckets as b (b.key)}
              <tr>
                <td class="font-mono text-xs">{b.key}</td>
                <td class="font-mono muted text-xs">{b.calls.toLocaleString()}</td>
                <td class="font-mono text-xs">{fmtUsd(b.cost_usd, 3)}</td>
                <td class="font-mono muted text-xs">{fmtUsd(b.avg_cost_usd, 4)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if providerBuckets.length === 0 && verbBuckets.length === 0}
      <div class="bg-bg-cream border border-border-warm rounded-sm p-4 flex flex-col gap-2 text-xs">
        <span class="muted">no spend recorded yet</span>
        <p class="subtle">make some API calls first.</p>
      </div>
    {/if}
  {/if}
</div>
