<script lang="ts">
  /**
   * wb-i38o.33 — Kanban panel.
   *
   * The user picks a named board from the dropdown; the panel runs that
   * board's query and renders columns. The user never sees a file path —
   * boards are managed by the agent (workhorse) writing to a project's
   * `kanban-views.org` file.
   *
   * Toolbar buttons surface two agent-routed actions:
   *   - "Create board" (in the picker + empty state) drops a "create a
   *     new kanban board" prompt into the chat compose so the user can
   *     describe what they want and the agent scaffolds it.
   *   - "New task" (per-board, label customizable via :ACTION_LABEL:)
   *     drops a "create a new task on this board" prompt scoped to
   *     the active board.
   */
  import { Plus, SquaresFour as LayoutGrid, Play, Pause } from "phosphor-svelte";
  import { onMount, onDestroy } from "svelte";
  import { packageStore as workspace } from "$lib/bridge/package.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { ws } from "$lib/bridge/ws.svelte";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";
  import BoardColumn from "./BoardColumn.svelte";
  import BoardPickerDropdown from "./BoardPickerDropdown.svelte";
  import {
    runQuery,
    groupBy,
    patchHeadline,
    listBoardViews,
    listActiveSessions,
    BoardApiError,
    boardState,
    boardStates,
    boardDispatchWhen,
    setBoardState,
    type BoardView,
    type LiveSession,
  } from "./api";
  import { features } from "$lib/bridge/features";
  import {
    STARTER_COLUMNS,
    type BoardCardItem,
    type BoardColumn as BoardColumnType,
    type BoardHeadline,
  } from "./types";

  // The agents catalog is multi-agent chrome (WB_FF_AGENTS, wb-aakl.2):
  // lazily loaded so a flags-off build excludes it. Only the "assigned"
  // grouping view reads it; with agents off, those columns fall back to
  // raw slugs (graceful — this is the kanban demo surface).
  let agents = $state<typeof import("$lib/bridge/agents.svelte").agents | null>(null);
  $effect(() => {
    if (!features.agents || agents) return;
    void import("$lib/bridge/agents.svelte").then((m) => {
      agents = m.agents;
      m.agents.init();
    });
  });
  const agentCatalog = $derived(agents?.agents ?? []);

  let views = $state<BoardView[]>([]);
  let activeViewId = $state<string | null>(null);
  let headlines = $state<BoardHeadline[]>([]);
  let loading = $state(false);

  type EmptyKind = "no_board" | "no_workspace" | "no_sidecar";
  let emptyKind = $state<EmptyKind | null>(null);
  let lastError = $state<{ code: string; message: string } | null>(null);

  // wb-mx72 — live session set is server-side truth, not derived
  // from this browser's localStorage. Loaded on mount + refreshed
  // when ws session events arrive (any process — chat panel, CLI,
  // background agent — fires the same telemetry).
  let liveSessions = $state<LiveSession[]>([]);

  let columns = $state<BoardColumnType[]>([]);
  $effect(() => {
    const view = views.find((v) => v.id === activeViewId);
    const kind = (view?.group_by ?? "status").trim();
    const base = groupBy(headlines, kind, pinnedColumnsFor(kind, view));
    columns = kind === "assigned" ? injectLiveSessions(base) : base;
  });

  /** Merge the server's active-session snapshot into the column set
   *  (assigned mode only). Live cards carry a `live` field;
   *  BoardCard renders the pulsing-dot "running" badge. DnD for
   *  live cards no-ops in handleFinalize. */
  function injectLiveSessions(cols: BoardColumnType[]): BoardColumnType[] {
    // Touch liveSessions so the effect re-runs when the set changes.
    const sessions = liveSessions;
    if (sessions.length === 0) return cols;

    const buckets: Map<string, BoardCardItem[]> = new Map();
    for (const s of sessions) {
      if (s.status !== "running") continue;
      const slug = s.agent_slug ?? "(unassigned)";
      const startedAtMs = s.started_at
        ? Date.parse(s.started_at)
        : Date.now();
      const card: BoardCardItem = {
        id: null,
        title: s.prompt_preview ?? `session ${s.session_id.slice(0, 8)}`,
        state: "RUNNING",
        priority: null,
        level: 0,
        tags: [],
        assigned: slug,
        properties: undefined,
        cardId: `_live_${s.session_id}`,
        live: {
          sessionId: s.session_id,
          startedAt: isNaN(startedAtMs) ? Date.now() : startedAtMs,
        },
      };
      const arr = buckets.get(slug) ?? [];
      arr.push(card);
      buckets.set(slug, arr);
    }

    return cols.map((c) => {
      const extras = buckets.get(c.state) ?? [];
      return extras.length === 0
        ? c
        : { ...c, cards: [...extras, ...c.cards] };
    });
  }

  /** Refresh the server-side live-session set. Called on mount, on
   *  any ws session lifecycle event, and after a wizard completes
   *  (its follow-on session shows up here too). */
  async function refreshLiveSessions() {
    try {
      liveSessions = await listActiveSessions();
    } catch {
      // Network blip; keep last known state rather than blanking.
    }
  }

  /** Resolve the column set the active view should pin (show even
   *  when empty). Three sources, in priority order:
   *  1. The view's `:COLUMNS:` override (whitespace- or comma-
   *     separated; matches the convention of `:STATES:` /
   *     `:DISPATCH_WHEN:` / `:TOOLKITS:`).
   *  2. For group_by=assigned: the agents catalog — every agent is
   *     a column so empty ones still appear (per wb-8fcg).
   *  3. For group_by=status: the GTD starter set so a fresh board
   *     shows TODO / DOING / DONE even when matching is empty. */
  /** Resolve the human-readable label for a column key. For agent
   *  slugs in assigned mode, look up the title from the catalog;
   *  fall back to the slug for unknown values. Returns null to mean
   *  "use the raw key" — the BoardColumn falls through correctly. */
  function columnLabel(key: string): string | null {
    const view = views.find((v) => v.id === activeViewId);
    const kind = (view?.group_by ?? "status").trim();
    if (kind !== "assigned") return null;
    if (key === "(unassigned)") return "Unassigned";
    const a = agentCatalog.find((x) => x.slug === key);
    return a?.title ?? key;
  }

  function pinnedColumnsFor(kind: string, view: BoardView | undefined): string[] {
    if (view?.columns) {
      return view.columns.split(/[\s,]+/).filter(Boolean);
    }
    if (kind === "assigned") {
      // Every agent in the catalog gets a column, sorted by title.
      const sorted = [...agentCatalog].sort((a, b) =>
        (a.title ?? a.slug).localeCompare(b.title ?? b.slug),
      );
      const cols = sorted.map((a) => a.slug);
      // Always include "(unassigned)" so tasks without :ASSIGNED_AGENT:
      // don't silently disappear — they cluster in the trailing bucket.
      cols.push("(unassigned)");
      return cols;
    }
    if (kind === "status") {
      return [...STARTER_COLUMNS];
    }
    return [];
  }

  const activeView = $derived(views.find((v) => v.id === activeViewId) ?? null);
  const actionLabel = $derived(activeView?.action_label ?? "New task");

  // ── Board lifecycle state (play/pause + custom states) ──
  // The control reads :STATE: / :STATES: / :DISPATCH_WHEN: off the
  // active view (declared in kanban-views.org). Clicking the control
  // PATCHes :STATE: via the oql HTTP write surface; the sidecar
  // broadcasts the doc change; loadViews refetches; the
  // BoardCoordinator (sidecar-side) re-ticks and resumes / pauses
  // dispatch automatically.
  const currentBoardState = $derived(activeView ? boardState(activeView) : null);
  const allBoardStates = $derived(activeView ? boardStates(activeView) : []);
  const dispatchStates = $derived(
    activeView ? boardDispatchWhen(activeView) : [],
  );
  const isDispatching = $derived(
    currentBoardState !== null && dispatchStates.includes(currentBoardState),
  );
  /** Active workspace's kanban-views.org path. Needed for PATCH. */
  const viewsPath = $derived.by(() => {
    const active = workspace.active;
    if (!active || active.folders.length === 0) return null;
    return `${active.folders[0]}/kanban-views.org`;
  });
  let stateMenuOpen = $state(false);
  let stateBusy = $state(false);

  async function toggleBoardState() {
    if (!activeView || !viewsPath || stateBusy) return;
    // 2-state vocabulary → flip to the other one.
    if (allBoardStates.length === 2 && currentBoardState) {
      const next = allBoardStates.find((s) => s !== currentBoardState);
      if (next) await applyBoardState(next);
    } else {
      // N-state vocabulary → open dropdown so the user picks.
      stateMenuOpen = !stateMenuOpen;
    }
  }

  async function applyBoardState(next: string) {
    if (!activeView || !viewsPath || stateBusy) return;
    stateBusy = true;
    stateMenuOpen = false;
    try {
      await setBoardState(viewsPath, activeView.id, next);
      // loadViews refetches; the optimistic mutation will be reflected
      // on the next oql:document:<viewsPath> event.
      views = await loadViews();
    } catch (err) {
      const code = err instanceof BoardApiError ? err.code : "unknown";
      const message = err instanceof Error ? err.message : String(err);
      lastError = { code, message };
    } finally {
      stateBusy = false;
    }
  }

  // ── Live updates (wb-i38o.33.3) ──

  let leaveChannel: (() => void) | null = null;
  let wsUnsub: (() => void) | null = null;

  function attachLiveUpdates(path: string) {
    detachLiveUpdates();
    leaveChannel = ws.joinDocument(path);
    const topic = `oql:document:${path}`;
    wsUnsub = ws.subscribe((evt) => {
      if (evt.topic === topic && evt.name === "changed") {
        load();
      }
    });
  }

  function detachLiveUpdates() {
    leaveChannel?.();
    leaveChannel = null;
    wsUnsub?.();
    wsUnsub = null;
  }

  /** Bundled fallback boards. Surfaced when the workspace has no
   *  `kanban-views.org` yet. The user can override / extend by
   *  writing their own entries through the create-board wizard —
   *  once kanban-views.org has any entries, these step aside.
   *
   *  "Agent activity" dogfoods the boards SDK: one column per agent
   *  in the catalog, cards are TODO + NEXT headlines grouped by
   *  :ASSIGNED_AGENT:. */
  function bundledDefaults(): BoardView[] {
    const active = workspace.active;
    if (!active || active.folders.length === 0) return [];
    const folder = active.folders[0];
    return [
      {
        id: "default-agent-activity",
        name: "Agent activity",
        path: `${folder}/plan.org`,
        query: "(or (todo TODO) (todo NEXT))",
        icon: "lucide:Users",
        tagline: "Every agent and what they're working on",
        action_label: "New task",
        group_by: "assigned",
        columns: null,
      },
      {
        id: "default-all-tasks",
        name: "All tasks",
        path: `${folder}/plan.org`,
        query: "(property ID)",
        icon: null,
        tagline: "Every headline in plan.org",
        action_label: null,
        group_by: "status",
        columns: null,
      },
    ];
  }

  async function loadViews(): Promise<BoardView[]> {
    const active = workspace.active;
    if (!active || active.folders.length === 0) return [];
    const folder = active.folders[0];
    const viewsPath = `${folder}/kanban-views.org`;
    try {
      const fetched = await listBoardViews(viewsPath);
      if (fetched.length > 0) {
        return fetched.map((v) => ({
          ...v,
          path: v.path.startsWith("/") ? v.path : `${folder}/${v.path}`,
        }));
      }
    } catch {
      /* swallow — fallthrough to defaults */
    }
    return bundledDefaults();
  }

  async function load() {
    if (!activeView) return;
    loading = true;
    lastError = null;
    emptyKind = null;
    try {
      const res = await runQuery(activeView.path, activeView.query);
      headlines = res.headlines;
    } catch (err) {
      const code = err instanceof BoardApiError ? err.code : "unknown";
      headlines = [];
      switch (code) {
        case "file_not_found":
          emptyKind = "no_board";
          break;
        case "scope_denied":
          emptyKind = "no_workspace";
          break;
        case "sidecar_down":
          emptyKind = "no_sidecar";
          break;
        default:
          lastError = {
            code,
            message: err instanceof Error ? err.message : String(err),
          };
      }
    } finally {
      loading = false;
    }
  }

  async function selectView(id: string) {
    activeViewId = id;
    if (activeView) attachLiveUpdates(activeView.path);
    await load();
  }

  // ── Chat-routed actions ──

  // wb-dj5r — wizards run inside the palette modal. Both "Create
  // board" and "New task" route through paletteWizardMode here.
  let paletteOpen = $state(false);
  let paletteWizardMode = $state<{ id: string; title: string } | null>(null);

  function openWizard(id: string, title: string) {
    paletteWizardMode = { id, title };
    paletteOpen = true;
  }

  function closePalette() {
    paletteOpen = false;
    paletteWizardMode = null;
  }

  function createBoard() {
    openWizard("create-board", "Create a kanban board");
  }

  function newTask() {
    if (!activeView) return;
    openWizard("create-task", "Create a task");
  }

  async function onWizardFinish(_briefPath: string) {
    // The follow-on agent writes the actual artifact (board entry or
    // task headline). Re-fetch the views so the picker reflects any
    // new board; for the active board, the WS subscriber will refresh
    // headlines automatically when the file is touched.
    views = await loadViews();
    if (activeViewId && !views.some((v) => v.id === activeViewId)) {
      // The active view vanished — pick the first one.
      if (views.length > 0) {
        await selectView(views[0].id);
      } else {
        activeViewId = null;
      }
    }
  }

  // ── Lifecycle ──

  // wb-mx72 — subscribe to global ws telemetry. Any session
  // lifecycle event triggers a refresh of the live set so the
  // board reflects sessions from any client.
  let liveUnsub: (() => void) | null = null;

  onMount(async () => {
    if (workspace.active) {
      await workspace.pushScopeToAgent().catch(() => {});
    }
    views = await loadViews();
    if (views.length > 0) {
      await selectView(views[0].id);
    }
    await refreshLiveSessions();
    liveUnsub = ws.subscribe((evt) => {
      if (
        evt.name === "session_started" ||
        evt.name === "session_completed" ||
        evt.name === "session_failed" ||
        evt.name === "session_cancelled"
      ) {
        // Small delay: the desktop's WS handler and the
        // SessionTrack PubSub subscriber are independent processes.
        // The tracker might not have processed the same event yet
        // when we hit /api/sessions. 60ms is plenty for the GenServer
        // handle_info round-trip + leaves cache-warm latency.
        setTimeout(() => {
          refreshLiveSessions();
        }, 60);
      }
    });
  });

  onDestroy(() => {
    detachLiveUpdates();
    liveUnsub?.();
    liveUnsub = null;
  });

  // ── DnD (wb-alkb) ──

  function setColumnCards(state: string, items: BoardCardItem[]) {
    columns = columns.map((c) =>
      c.state === state ? { ...c, cards: items } : c,
    );
  }

  function handleConsider(state: string, items: BoardCardItem[]) {
    setColumnCards(state, items);
  }

  async function handleFinalize(state: string, items: BoardCardItem[]) {
    const previousCardIds = new Set(
      columns.find((c) => c.state === state)?.cards.map((c) => c.cardId) ?? [],
    );
    setColumnCards(state, items);

    const arrived = items.find((c) => !previousCardIds.has(c.cardId));
    if (!arrived) return;
    if (!activeView) return;
    if (arrived.live) {
      // wb-rgon — live session cards are read-only on the board.
      // The drag visual already happened; just reconcile so the
      // dropped card returns to its source column.
      columns = groupBy(headlines, "assigned", pinnedColumnsFor("assigned", activeView));
      columns = injectLiveSessions(columns);
      return;
    }
    if (!arrived.id) {
      console.warn(
        "[board] Can't update a headline without an :ID:; rolling back",
      );
      await load();
      return;
    }

    // Branch by the active view's grouping kind. status drags become
    // transition_todo; assigned drags become set_property on
    // :ASSIGNED_AGENT:. (unassigned) drops clear the property by
    // writing an empty value — the oql-parse mutation API accepts
    // empty strings; future polish: dedicated "clear property" op.
    const kind = (activeView.group_by ?? "status").trim();

    try {
      if (kind === "status") {
        if (arrived.state === state) return;
        await patchHeadline(activeView.path, arrived.id, "transition_todo", {
          state,
        });
        headlines = headlines.map((h) =>
          h.id === arrived.id ? { ...h, state } : h,
        );
      } else if (kind === "assigned") {
        const newAssignee = state === "(unassigned)" ? "" : state;
        if ((arrived.assigned ?? "") === newAssignee) return;
        await patchHeadline(activeView.path, arrived.id, "set_property", {
          name: "ASSIGNED_AGENT",
          value: newAssignee,
        });
        headlines = headlines.map((h) =>
          h.id === arrived.id ? { ...h, assigned: newAssignee || null } : h,
        );
      } else {
        // Property-based grouping — update the property to the
        // destination column's value.
        const propName = kind.toUpperCase();
        await patchHeadline(activeView.path, arrived.id, "set_property", {
          name: propName,
          value: state,
        });
        await load();
      }
    } catch (err) {
      lastError = {
        code: err instanceof BoardApiError ? err.code : "unknown",
        message: err instanceof Error ? err.message : String(err),
      };
      await load();
    }
  }
</script>

<PaletteModal
  open={paletteOpen}
  workdir={workspace.active?.folders?.[0] ?? null}
  wizardMode={paletteWizardMode}
  onclose={closePalette}
  onwizardfinish={onWizardFinish}
/>

<div class="board">
  <header class="toolbar">
    <BoardPickerDropdown
      {views}
      selectedId={activeViewId}
      onselect={selectView}
      oncreate={createBoard}
    />
    {#if activeView && currentBoardState}
      <div class="state-control">
        {#if allBoardStates.length === 2}
          <button
            type="button"
            class="state-toggle"
            class:running={isDispatching}
            onclick={toggleBoardState}
            disabled={stateBusy}
            title={isDispatching
              ? `Running — click to ${allBoardStates.find((s) => s !== currentBoardState)}`
              : `${currentBoardState} — click to ${allBoardStates.find((s) => s !== currentBoardState)}`}
            aria-label={`Board is ${currentBoardState}. Click to flip.`}
          >
            {#if isDispatching}
              <Pause weight="fill" size={12} />
            {:else}
              <Play weight="fill" size={12} />
            {/if}
            <span class="state-label">{currentBoardState}</span>
          </button>
        {:else}
          <button
            type="button"
            class="state-toggle"
            class:running={isDispatching}
            onclick={toggleBoardState}
            disabled={stateBusy}
            aria-haspopup="listbox"
            aria-expanded={stateMenuOpen}
          >
            {#if isDispatching}
              <Play weight="fill" size={12} />
            {:else}
              <Pause weight="fill" size={12} />
            {/if}
            <span class="state-label">{currentBoardState}</span>
          </button>
          {#if stateMenuOpen}
            <ul class="state-menu" role="listbox">
              {#each allBoardStates as s}
                <li>
                  <button
                    type="button"
                    class:current={s === currentBoardState}
                    onclick={() => applyBoardState(s)}
                  >
                    {s}
                    {#if dispatchStates.includes(s)}
                      <span class="dot" aria-hidden="true"></span>
                    {/if}
                  </button>
                </li>
              {/each}
            </ul>
          {/if}
        {/if}
      </div>
    {/if}
    <div class="spacer"></div>
    {#if activeView}
      <button type="button" class="action" onclick={newTask} title={actionLabel}>
        <Plus weight="bold" size={14} />
        <span>{actionLabel}</span>
      </button>
    {/if}
  </header>

  <div class="body">
    {#if !sidecar.status.url || emptyKind === "no_sidecar"}
      <div class="message">
        <span>Agent server isn't running yet.</span>
        <small>The Kanban needs the workhorse sidecar to be up.</small>
      </div>
    {:else if views.length === 0 || emptyKind === "no_workspace"}
      <div class="message">
        <span>Open a workspace to see boards.</span>
        <small>Boards live inside a workspace's files.</small>
      </div>
    {:else if emptyKind === "no_board"}
      <div class="empty-hero">
        <div class="empty-illustration" aria-hidden="true">
          <LayoutGrid weight="fill" size={28} />
        </div>
        <div class="empty-copy">
          <h2 class="empty-title">No board yet</h2>
          <p class="empty-sub">
            Boards live in a workspace's <code>kanban-views.org</code>.
            Ask an agent to scaffold your first one — describe what
            you want to track and it'll write the file.
          </p>
        </div>
        <button type="button" class="primary" onclick={createBoard}>
          <Plus weight="bold" size={14} />
          <span>Create board</span>
        </button>
      </div>
    {:else if lastError}
      <div class="message error">
        <div class="error-detail">
          <strong>{lastError.code}</strong>
          <pre>{lastError.message}</pre>
        </div>
        <button type="button" onclick={load}>Retry</button>
      </div>
    {:else if loading && headlines.length === 0}
      <div class="message">Loading…</div>
    {:else if headlines.length === 0}
      <div class="empty-hero">
        <div class="empty-illustration" aria-hidden="true">
          <LayoutGrid weight="fill" size={28} />
        </div>
        <div class="empty-copy">
          <h2 class="empty-title">Nothing on this board yet</h2>
          <p class="empty-sub">
            This board's <code>{activeView?.query ?? ""}</code> query
            matched zero headlines. Add one with the button below — or
            run an agent that produces tasks.
          </p>
        </div>
        <button type="button" class="primary" onclick={newTask}>
          <Plus weight="bold" size={14} />
          <span>{actionLabel}</span>
        </button>
      </div>
    {:else}
      <div class="columns" role="list">
        {#each columns as col (col.state)}
          <BoardColumn
            column={col}
            label={columnLabel(col.state)}
            onConsider={handleConsider}
            onFinalize={handleFinalize}
          />
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .board {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--color-page, #fafafa);
  }

  .toolbar {
    display: flex;
    gap: 0.5rem;
    align-items: center;
    padding: 0.5rem 0.75rem;
    border-bottom: 1px solid var(--color-border, #e4e4e7);
    background: var(--color-surface, #ffffff);
    flex-shrink: 0;
  }

  .spacer {
    flex: 1;
  }

  .state-control {
    position: relative;
    display: inline-flex;
    align-items: center;
  }

  .state-toggle {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    height: 26px;
    padding: 0 0.625rem;
    border: 1px solid var(--color-border, #e4e4e7);
    background: var(--color-surface, #ffffff);
    color: var(--color-fg-muted, #71717a);
    border-radius: 5px;
    font-size: 11.5px;
    font-weight: 500;
    cursor: pointer;
    text-transform: capitalize;
  }

  .state-toggle:hover:not(:disabled) {
    background: var(--color-surface-soft, #f4f4f5);
  }

  .state-toggle:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .state-toggle.running {
    color: var(--color-emerald, #10b981);
    border-color: var(--color-emerald, #10b981);
  }

  .state-label {
    letter-spacing: 0;
  }

  .state-menu {
    position: absolute;
    top: calc(100% + 4px);
    left: 0;
    list-style: none;
    margin: 0;
    padding: 4px;
    min-width: 160px;
    border: 1px solid var(--color-border, #e4e4e7);
    background: var(--color-surface, #ffffff);
    border-radius: 6px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
    z-index: 10;
  }

  .state-menu li button {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.4rem 0.5rem;
    background: transparent;
    border: 0;
    color: var(--color-fg, #18181b);
    font-size: 12.5px;
    font-weight: 500;
    border-radius: 4px;
    cursor: pointer;
    text-transform: capitalize;
  }

  .state-menu li button:hover {
    background: var(--color-surface-soft, #f4f4f5);
  }

  .state-menu li button.current {
    background: var(--color-surface-soft, #f4f4f5);
  }

  .state-menu .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-emerald, #10b981);
  }

  .action {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    height: 28px;
    padding: 0 0.625rem;
    border: 1px solid var(--color-border, #e4e4e7);
    background: var(--color-surface, #ffffff);
    color: var(--color-fg, #18181b);
    border-radius: 5px;
    font-size: 12.5px;
    font-weight: 500;
    cursor: pointer;
  }

  .action:hover {
    background: var(--color-surface-soft, #f4f4f5);
  }

  .body {
    flex: 1;
    overflow: hidden;
  }

  .columns {
    display: flex;
    gap: 0.5rem;
    padding: 0.75rem;
    height: 100%;
    overflow-x: auto;
  }

  .message {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    height: 100%;
    color: var(--color-muted, #71717a);
    font-size: 0.875rem;
    padding: 2rem;
    text-align: center;
  }

  .message small {
    font-size: 0.75rem;
    opacity: 0.75;
  }

  .message.error {
    color: var(--color-error, #e11d48);
  }

  .message .error-detail {
    background: var(--color-surface, #ffffff);
    border: 1px solid var(--color-border, #e4e4e7);
    border-radius: 6px;
    padding: 0.75rem;
    max-width: 36rem;
    color: var(--color-fg, #18181b);
  }

  .error-detail strong {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.75rem;
  }

  .error-detail pre {
    margin: 0.25rem 0 0 0;
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.75rem;
    white-space: pre-wrap;
    word-break: break-word;
  }

  .message button {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg);
    padding: 0.375rem 0.75rem;
    border-radius: 5px;
    cursor: pointer;
    font-size: 0.8125rem;
  }

  /* Centered hero empty state used for no_board + zero-tasks. Larger
   * visual presence than the .message blocks so the user feels invited
   * to take the next step. */
  .empty-hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    padding: 3rem 2rem;
    gap: 1.25rem;
    text-align: center;
  }

  .empty-illustration {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 56px;
    height: 56px;
    border-radius: 14px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
  }

  .empty-copy {
    max-width: 28rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .empty-title {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    color: var(--color-fg);
    letter-spacing: -0.01em;
  }

  .empty-sub {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.5;
    color: var(--color-fg-muted);
  }

  .empty-sub code {
    font-family: var(--font-mono, ui-monospace, monospace);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    padding: 0.0625rem 0.3125rem;
    border-radius: 4px;
    font-size: 0.75rem;
    color: var(--color-fg);
  }

  /* Monochrome inverted primary button — flips with the theme so it's
   * always high contrast against the page. Replaces the broken
   * --color-accent + white text combo (the accent is near-white in
   * dark mode, so white-on-white was invisible). */
  button.primary {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
    padding: 0.55rem 1rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: 0.8125rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    box-shadow:
      0 1px 1px rgba(0, 0, 0, 0.04),
      0 4px 14px rgba(0, 0, 0, 0.08);
  }

  button.primary:hover {
    opacity: 0.9;
  }

  button.primary:active {
    transform: translateY(0.5px);
  }
</style>
