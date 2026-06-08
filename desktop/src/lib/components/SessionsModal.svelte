<script lang="ts">
  /**
   * SessionsModal — the canonical surface for browsing the engine's
   * session ledger. Designed as a reusable core component:
   *
   *   - Chat header opens it scoped to the currently-selected agent
   *   - Board panel can open it scoped to a particular task or agent
   *   - Settings / status surfaces can open it unscoped for the
   *     full-fleet view
   *
   * The modal is information-dense but not crowded — much more
   * vertical room than the old inline SessionExplorer popover so the
   * user can actually browse across runs without scroll-thrash.
   * Backdrop-click + Escape dismiss; the dialog never replaces or
   * overlaps the chat thread, it floats above it.
   *
   * Filter model: an optional agentSlug prop locks the agent filter
   * (use case: opened from a per-agent chat header — "show me MY
   * runs"). When unset, the agent picker is editable and "All agents"
   * is the default.
   */
  import { onDestroy } from "svelte";
  import { Search, X } from "@lucide/svelte";
  import { listSessions, type SessionRow, type SessionStatus } from "$lib/sessions/api";

  let {
    open = false,
    /** Optional initial agent filter. When set, the picker is
     *  pre-selected to this slug — but the user can still change it
     *  or pick "All agents". This is the right shape for the chat
     *  case (open it from a specific agent, but let the user broaden
     *  if they want to see anything else they've run). */
    agentSlug = null,
    onclose,
    /** Optional — when set, clicking a session row calls this with
     *  the session's prompt_preview. The chat uses it to drop the
     *  prompt back into the composer for recall. */
    onpick = null,
  }: {
    open?: boolean;
    agentSlug?: string | null;
    onclose: () => void;
    onpick?: ((session: SessionRow) => void) | null;
  } = $props();

  // Source rows from the engine + UI filter state.
  let rows = $state<SessionRow[]>([]);
  let loading = $state(false);
  let lastFetchAt = $state<number | null>(null);

  let agentFilter = $state<string | "__all__">(agentSlug ?? "__all__");
  let statusFilter = $state<SessionStatus | "__all__">("__all__");
  let searchText = $state("");

  let cardEl: HTMLDivElement | undefined = $state();
  let refreshTimer: ReturnType<typeof setInterval> | undefined;

  // When the caller (chat) passes a fresh agentSlug at open time,
  // pre-select the filter to it. The user is still free to flip the
  // picker to "All agents" or another slug — agentSlug is a hint,
  // not a lock.
  $effect(() => {
    if (open && agentSlug !== null) agentFilter = agentSlug;
  });

  async function refresh() {
    if (loading) return;
    loading = true;
    try {
      rows = await listSessions();
      lastFetchAt = Date.now();
    } finally {
      loading = false;
    }
  }

  // Auto-refresh while open so running sessions show real-time
  // progress (status flips, new sessions appearing). 4s is fast
  // enough to feel alive without hammering the engine.
  $effect(() => {
    if (open) {
      refresh();
      refreshTimer = setInterval(refresh, 4_000);
    } else if (refreshTimer) {
      clearInterval(refreshTimer);
      refreshTimer = undefined;
    }
  });

  onDestroy(() => {
    if (refreshTimer) clearInterval(refreshTimer);
  });

  // Build the agent picker options from the actually-observed slugs
  // in the snapshot, so the dropdown reflects whoever ran sessions
  // rather than the agent catalog (which would include agents that
  // never ran). `$derived.by(fn)` is the function form — the bare
  // `$derived(fn)` would set the value to the function itself rather
  // than the function's return, which is the bug that left the modal
  // visibly empty even though rows was populated.
  const observedAgents = $derived.by<string[]>(() => {
    const set = new Set<string>();
    for (const r of rows) {
      if (r.agent_slug) set.add(r.agent_slug);
    }
    return [...set].sort();
  });

  const filtered = $derived.by<SessionRow[]>(() => {
    const q = searchText.trim().toLowerCase();
    return rows.filter((r) => {
      if (agentFilter !== "__all__" && r.agent_slug !== agentFilter) return false;
      if (statusFilter !== "__all__" && r.status !== statusFilter) return false;
      if (q) {
        const hay = [
          r.prompt_preview ?? "",
          r.agent_slug ?? "",
          r.session_id,
        ]
          .join(" ")
          .toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  });

  // Per-status counts (for the chip badges + empty-state copy).
  const statusCounts = $derived.by<Record<SessionStatus | "__all__", number>>(
    () => {
      const c = { __all__: 0, running: 0, completed: 0, failed: 0, cancelled: 0 };
      for (const r of rows) {
        if (agentFilter !== "__all__" && r.agent_slug !== agentFilter) continue;
        c.__all__++;
        c[r.status]++;
      }
      return c;
    },
  );

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    onclose();
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
  }

  function shortTime(iso: string | null): string {
    if (!iso) return "—";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "—";
    const now = new Date();
    const sameDay =
      d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() &&
      d.getDate() === now.getDate();
    if (sameDay) {
      return d.toLocaleTimeString(undefined, {
        hour: "2-digit",
        minute: "2-digit",
      });
    }
    return d.toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function durationLabel(r: SessionRow): string | null {
    if (!r.started_at) return null;
    const start = new Date(r.started_at).getTime();
    const end = r.finished_at
      ? new Date(r.finished_at).getTime()
      : Date.now();
    const sec = Math.max(0, Math.round((end - start) / 1000));
    if (sec < 60) return `${sec}s`;
    const min = Math.floor(sec / 60);
    const remSec = sec % 60;
    if (min < 60) return remSec ? `${min}m ${remSec}s` : `${min}m`;
    const hr = Math.floor(min / 60);
    return `${hr}h ${min % 60}m`;
  }

  function shortWorkdir(path: string | null): string | null {
    if (!path) return null;
    // Strip the common ~/Workbooks/monorepo/workspaces/<ws>/ prefix
    // so the row shows just the package or path tail.
    const home = "/Users/";
    if (path.startsWith(home)) {
      const tail = path.replace(/^.*\/workspaces\//, "");
      return tail.length < path.length ? tail : path.split("/").slice(-2).join("/");
    }
    return path;
  }
</script>

<svelte:window onkeydown={key} />

{#if open}
  <div class="backdrop" onmousedown={backdrop} role="presentation">
    <div class="card" bind:this={cardEl} role="dialog" aria-label="Sessions">
      <header class="head">
        <div class="head-text">
          <h3>Sessions</h3>
          <p class="sub">
            {#if loading && rows.length === 0}
              Loading…
            {:else}
              {rows.length} total · {statusCounts.running} running ·
              {statusCounts.completed} done · {statusCounts.failed} failed
              {#if statusCounts.cancelled > 0}
                · {statusCounts.cancelled} cancelled
              {/if}
            {/if}
          </p>
        </div>
        <button
          type="button"
          class="icon-btn"
          title="Close"
          aria-label="Close"
          onclick={onclose}
        >
          <X size={14} strokeWidth={2} />
        </button>
      </header>

      <div class="filters">
        <div class="search">
          <Search size={12} strokeWidth={2} aria-hidden="true" />
          <input
            type="text"
            placeholder="Search prompt, agent, id…"
            bind:value={searchText}
            autocomplete="off"
            spellcheck="false"
          />
        </div>

        <!-- Always show the agent picker. agentSlug from the caller
             is a pre-selected default; the user can flip to "All
             agents" or any other observed slug. -->
        <select bind:value={agentFilter}>
          <option value="__all__">All agents</option>
          {#each observedAgents as slug (slug)}
            <option value={slug}>{slug}</option>
          {/each}
        </select>

        <div class="chips">
          {#each ["__all__", "running", "completed", "failed", "cancelled"] as st (st)}
            {@const active = statusFilter === st}
            {@const n = statusCounts[st as SessionStatus | "__all__"]}
            <button
              type="button"
              class="chip"
              class:active
              onclick={() => (statusFilter = st as SessionStatus | "__all__")}
            >
              {st === "__all__" ? "All" : st}
              {#if n > 0}<span class="chip-n">{n}</span>{/if}
            </button>
          {/each}
        </div>
      </div>

      <div class="rows">
        {#if filtered.length === 0}
          <div class="empty">
            {#if rows.length === 0 && !loading}
              No sessions yet. Start one from the chat or run a board.
            {:else if rows.length === 0 && loading}
              &nbsp;
            {:else}
              No sessions match the current filters.
            {/if}
          </div>
        {:else}
          {#each filtered as r (r.session_id)}
            {@const dur = durationLabel(r)}
            {@const wd = shortWorkdir(r.workdir)}
            <button
              type="button"
              class="row"
              onclick={() => onpick?.(r)}
              disabled={!onpick}
            >
              <div class="row-top">
                <span class="status status-{r.status}">{r.status}</span>
                <span class="agent">{r.agent_slug ?? "—"}</span>
                <span class="time">{shortTime(r.started_at)}</span>
                {#if dur}<span class="dur">{dur}</span>{/if}
              </div>
              {#if r.prompt_preview}
                <div class="prompt">{r.prompt_preview}</div>
              {/if}
              {#if wd}
                <div class="workdir" title={r.workdir}>{wd}</div>
              {/if}
            </button>
          {/each}
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.45);
    z-index: 1100;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 3rem 2rem;
  }
  .card {
    width: 100%;
    max-width: 880px;
    min-width: 480px;
    height: 80vh;
    max-height: 720px;
    min-height: 420px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 1rem 1.25rem 0.75rem;
    border-bottom: 1px solid var(--color-border);
  }
  .head-text {
    flex: 1 1 auto;
    min-width: 0;
  }
  h3 {
    margin: 0 0 0.15rem;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  .sub {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.74rem;
  }
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 26px;
    height: 26px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 5px;
    cursor: pointer;
  }
  .icon-btn:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .icon-btn:disabled { opacity: 0.4; cursor: default; }

  .filters {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem;
    padding: 0.65rem 1.25rem;
    border-bottom: 1px solid var(--color-border);
  }
  .search {
    flex: 1 1 220px;
    display: flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.3rem 0.55rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    color: var(--color-fg-muted);
  }
  .search input {
    flex: 1 1 auto;
    background: transparent;
    border: 0;
    outline: 0;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.82rem;
  }
  select, .locked-agent {
    height: 28px;
    padding: 0 0.55rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.78rem;
  }
  .locked-agent {
    display: inline-flex;
    align-items: center;
    color: var(--color-fg-muted);
  }
  .chips {
    display: flex;
    align-items: center;
    gap: 0.25rem;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.25rem 0.55rem;
    border-radius: 999px;
    border: 1px solid var(--color-border);
    background: transparent;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.72rem;
    cursor: pointer;
    text-transform: capitalize;
  }
  .chip:hover { color: var(--color-fg); background: var(--color-surface-soft); }
  .chip.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }
  .chip-n {
    font-size: 0.66rem;
    opacity: 0.75;
  }

  .rows {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 0.5rem 0.75rem 0.75rem;
  }
  .empty {
    padding: 2rem 1rem;
    text-align: center;
    color: var(--color-fg-subtle);
    font-size: 0.82rem;
  }
  .row {
    width: 100%;
    text-align: left;
    display: block;
    padding: 0.55rem 0.65rem;
    margin: 0.25rem 0;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface);
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    transition: background 0.08s, border-color 0.08s;
  }
  .row:hover:not(:disabled) {
    background: var(--color-surface-soft);
    border-color: var(--color-border-strong);
  }
  .row:disabled { cursor: default; }
  .row-top {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.76rem;
  }
  .status {
    display: inline-flex;
    align-items: center;
    padding: 0.08rem 0.4rem;
    border-radius: 999px;
    font-size: 0.66rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  /* Semantic colors per CLAUDE.md convention: emerald / amber / rose. */
  .status-running { background: rgba(16, 185, 129, 0.15); color: #10b981; }
  .status-completed { background: var(--color-surface-soft); color: var(--color-fg-muted); }
  .status-failed { background: rgba(244, 63, 94, 0.15); color: #f43f5e; }
  .status-cancelled { background: rgba(245, 158, 11, 0.15); color: #f59e0b; }

  .agent {
    flex: 1 1 auto;
    min-width: 0;
    color: var(--color-fg);
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .time, .dur {
    color: var(--color-fg-muted);
    font-size: 0.72rem;
    flex-shrink: 0;
  }
  .dur::before { content: "·  "; opacity: 0.5; }
  .prompt {
    margin-top: 0.3rem;
    font-size: 0.78rem;
    color: var(--color-fg-muted);
    line-height: 1.4;
    overflow: hidden;
    text-overflow: ellipsis;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .workdir {
    margin-top: 0.25rem;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.66rem;
    color: var(--color-fg-subtle);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
