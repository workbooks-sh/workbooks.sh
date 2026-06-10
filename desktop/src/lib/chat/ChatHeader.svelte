<script lang="ts">
  /**
   * ChatHeader — the chrome above the chat thread.
   *
   * Holds:
   *   - Agent picker dropdown (active agent + switch + "Create new")
   *   - Scope chip → click opens AgentScopesModal with parsed metadata
   *     from the :agent: entity binding (model, tools, capabilities,
   *     spawn rules, system-prompt preview)
   *   - "More" menu — Edit (→ Settings → Agents → <slug>) and reset
   *     session. Per-agent session history is deferred (wb-shtl.4).
   *
   * Talks to:
   *   - `agents` store for catalog + selection
   *   - `chrome` for nav into Settings
   *   - emits `oncreate` → host shows the CreateAgentDialog
   *   - emits `onreset` → host clears the active session
   */
  import { Clock, Plus, WarningCircle as AlertCircle, Paperclip } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { agents, type AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import { tabs } from "$lib/tabs/store.svelte";
  import { chatSession } from "./session.svelte";
  import { listSessions } from "$lib/sessions/api";
  import AgentPickerDropdown from "./AgentPickerDropdown.svelte";
  import SessionsModal from "$lib/components/SessionsModal.svelte";

  let {
    oncreate,
    onreset,
    onshowscopes,
    onrecallprompt,
  }: {
    oncreate: () => void;
    onreset: () => void;
    onshowscopes: (agent: AgentCatalogEntry) => void;
    /** Called when the user picks a session from the explorer — the
     *  host drops the prompt back into the composer. v1 doesn't
     *  resume the underlying GenServer (singleton chatSession);
     *  resumable history lands when the server-backed view ships. */
    onrecallprompt: (prompt: string) => void;
  } = $props();

  onMount(() => {
    agents.init();
    refreshSessionCount();
  });

  const selected = $derived(agents.selectedEntry);

  // ── Sessions modal ──
  // The badge shows the count of engine-tracked sessions for the
  // active agent (any status), polled lightly while the chat is
  // mounted. Source of truth is the engine, not localStorage — so
  // sessions started by the board, the CLI, or any other surface
  // show up here too.
  let sessionsOpen = $state(false);
  let historyCount = $state(0);
  let countRefreshTimer: ReturnType<typeof setInterval> | undefined;

  async function refreshSessionCount() {
    const rows = await listSessions();
    const slug = agents.selected;
    historyCount = slug ? rows.filter((r) => r.agent_slug === slug).length : 0;
  }

  // Re-count whenever the active agent changes; also poll every 8s so
  // a freshly-started board run bumps the badge without the user
  // having to open the modal.
  $effect(() => {
    void agents.selected;
    refreshSessionCount();
  });
  $effect(() => {
    countRefreshTimer = setInterval(refreshSessionCount, 8_000);
    return () => {
      if (countRefreshTimer) clearInterval(countRefreshTimer);
    };
  });
</script>

<header class="chat-header">
  <AgentPickerDropdown oncreate={oncreate} />

  {#if selected}
    {@const toolkitCount =
      (selected.toolkits ?? selected.packages ?? []).length}
    {@const capCount = selected.capabilities?.length ?? 0}
    <button
      type="button"
      class="scope-chip"
      title="Scopes & capabilities"
      onclick={() => onshowscopes(selected)}
    >
      <span>{toolkitCount} toolkit{toolkitCount === 1 ? "" : "s"}</span>
      {#if capCount > 0}
        <span class="dot">·</span>
        <span>{capCount} cap{capCount === 1 ? "" : "s"}</span>
      {/if}
    </button>
  {:else if agents.lastError}
    <span class="error-chip" title={agents.lastError}>
      <AlertCircle weight="fill" size={11} aria-hidden="true" />
      <span>catalog error</span>
    </span>
  {/if}

  {#if chatSession.session?.attachments && chatSession.session.attachments.length > 0}
    {#each chatSession.session.attachments as att (att.path)}
      <button
        type="button"
        class="attach-chip"
        title={`${att.label} brief\n${att.path}`}
        onclick={() => tabs.open(att.path)}
      >
        <Paperclip weight="fill" size={10} aria-hidden="true" />
        <span class="att-label">{att.label}</span>
      </button>
    {/each}
  {/if}

  <span class="spacer"></span>

  <button
    type="button"
    class="icon-btn"
    class:active={sessionsOpen}
    title="Sessions"
    aria-label="Sessions"
    aria-expanded={sessionsOpen}
    onclick={() => (sessionsOpen = true)}
  >
    <Clock weight="fill" size={13} />
    {#if historyCount > 0}
      <span class="badge">{historyCount > 99 ? "99+" : historyCount}</span>
    {/if}
  </button>

  <button
    type="button"
    class="icon-btn"
    title="New session"
    aria-label="New session"
    onclick={onreset}
  >
    <Plus weight="bold" size={13} />
  </button>
</header>

<SessionsModal
  open={sessionsOpen}
  agentSlug={agents.selected}
  onclose={() => (sessionsOpen = false)}
  onpick={(session) => {
    if (session.prompt_preview) onrecallprompt(session.prompt_preview);
    sessionsOpen = false;
  }}
/>

<style>
  .chat-header {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.35rem 0.55rem;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
    min-height: 36px;
    background: var(--color-surface);
  }
  .picker-wrap {
    flex: 0 1 auto;
    min-width: 0;
    max-width: 220px;
  }
  /* Override Dropdown's default trigger to fit a chat-header chrome. */
  :global(.agent-picker) {
    font-size: 0.8rem;
    padding: 0.2rem 0.45rem !important;
    background: transparent !important;
    border-color: transparent !important;
  }
  :global(.agent-picker:hover) {
    background: var(--color-surface-soft) !important;
    border-color: var(--color-border) !important;
  }
  .scope-chip,
  .error-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.2rem 0.5rem;
    border-radius: 999px;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    cursor: pointer;
    font: inherit;
    font-size: 0.72rem;
  }
  .scope-chip:hover {
    color: var(--color-fg);
    background: var(--color-border);
  }
  .error-chip {
    color: #fca5a5;
    cursor: default;
  }
  .attach-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.2rem 0.5rem;
    border-radius: 999px;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    cursor: pointer;
    font: inherit;
    font-size: 0.72rem;
  }
  .attach-chip:hover {
    color: var(--color-fg);
    background: var(--color-border);
  }
  .att-label {
    max-width: 8rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .dot {
    opacity: 0.5;
  }
  .spacer {
    flex: 1 1 auto;
  }
  .icon-btn {
    position: relative;
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
  .icon-btn:hover,
  .icon-btn.active {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .badge {
    position: absolute;
    top: -2px;
    right: -4px;
    min-width: 14px;
    height: 14px;
    padding: 0 3px;
    font-size: 0.6rem;
    font-weight: 600;
    background: var(--color-fg);
    color: var(--color-page);
    border-radius: 999px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
  }
</style>
