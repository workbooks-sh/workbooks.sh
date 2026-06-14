<script lang="ts">
  /**
   * ChatPanel (desktop variant).
   *
   * Net-new for wb-i38o.4, but heavily informed by the Studio chat:
   * archive/studio/frontend/src/lib/components/chat/ChatPanel.svelte.
   *
   * Differences vs Studio:
   *   - Event source is the local WS bridge (ws.svelte.ts), not the
   *     broker turn API. Studio's SessionEvent discriminated union was
   *     designed against the wb-nivl B2 event log shape, so the same
   *     mapping principles apply — but the *channel* events the OQL
   *     agent emits (llm_turn_start/stop, tool_call_start/stop,
   *     session_*) are a different (smaller) set than Studio's
   *     normalized message_delta / tool_start / tool_end stream.
   *     So projection lives in $lib/chat/session.svelte.ts and this
   *     view renders the projected ChatBlock[] directly.
   *   - No markdown render. v1 is plain text — `marked` lands when the
   *     desktop adopts BlockRenderer (deferred, see audit).
   *   - No file-attachment surface. Studio uploads to the broker;
   *     desktop file refs come later via Tauri's fs plugin (D7).
   *   - No slash menu / model picker / agent picker. Same reason: the
   *     desktop's agent + skill model is being defined by the
   *     workspace + sub-agent caps story, not by this slice.
   *
   * CSS class names + design tokens (var(--color-fg), var(--radius-*),
   * etc.) match Studio so a future shared `packages/ui/` extraction
   * stays cheap.
   */

  import { WarningCircle as AlertCircle, CheckCircle as CheckCircle2, CaretDown as ChevronDown, CircleNotch as Loader2, Wrench, X } from "phosphor-svelte";
  import { onMount, tick } from "svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { chatSession } from "./session.svelte";
  import type { ChatBlock, ToolCallBlock } from "./types";
  import type { AgentCatalogEntry } from "$lib/bridge/agents.svelte";
  import ChatHeader from "./ChatHeader.svelte";
  import ChatComposer from "./ChatComposer.svelte";
  import AgentScopesModal from "./AgentScopesModal.svelte";
  import AgentEditor from "./AgentEditor.svelte";
  import SkillPicker from "./SkillPicker.svelte";
  import ModelPicker from "./ModelPicker.svelte";
  import AssistantMessageView from "./AssistantMessageView.svelte";
  import { getLlmModel, setLlmModel } from "$lib/bridge/llmModel.svelte";
  import { moonshineStt } from "$lib/stt/moonshine.svelte";
  import { geminiLive } from "$lib/live/gemini.svelte";
  import { agents } from "$lib/bridge/agents.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";

  // TODO(wb-i38o.3): scope chat to active workspace once D3 lands. For
  // now the agent operates in the sidecar's cwd; nothing here cares.

  let {}: Record<string, never> = $props();

  onMount(() => {
    chatSession.init();
  });

  // Header dialog state — owned here so the modals overlay the chat,
  // not the rail. ChatHeader emits events; ChatPanel hosts the actual
  // modal markup.
  let scopesAgent = $state<AgentCatalogEntry | null>(null);
  let editorSlug = $state<string | null | undefined>(undefined); // undefined = closed, null = create-new, string = edit

  function resetSession() {
    // Reset the local session view. The actual session GenServer in
    // the sidecar will be GC'd when its lease expires; we just clear
    // the panel.
    chatSession.session = null;
    chatSession.blocks = [];
    chatSession.userPrompt = null;
    chatSession.sendError = null;
  }

  /** Drop a recalled prompt (from the session explorer) into the
   *  composer. v1 doesn't re-attach to the original session — the
   *  user re-sends, which starts a fresh session. Resumable history
   *  needs server-side state we don't have today. */
  function recallPrompt(prompt: string) {
    draft = prompt;
    queueMicrotask(() => composerRef?.focus());
  }

  let draft = $state("");

  // wb-8285 — skills attached to the next message via the @-picker.
  // Cleared on send. Each chip references a SKILL.md the server
  // resolves + prepends to the system prompt for that turn.
  let attachedSkills = $state<string[]>([]);
  function attachSkill(slug: string) {
    if (!attachedSkills.includes(slug)) {
      attachedSkills = [...attachedSkills, slug];
    }
  }
  function detachSkill(slug: string) {
    attachedSkills = attachedSkills.filter((s) => s !== slug);
  }
  let composerRef = $state<ChatComposer | undefined>(undefined);
  // Waldo's model, switchable right from the composer (next to send).
  let model = $state(getLlmModel());
  let threadEl = $state<HTMLDivElement | undefined>(undefined);
  let openTools = $state<Record<string, boolean>>({});

  const ready = $derived(sidecar.status.state === "ready");
  // Composer's stop button is only meaningful when something is
  // actively stoppable: a live audio turn, or a regular running chat.
  // When the live session is paused (resumable), connecting, or in
  // error, the composer reverts to the normal send button — the
  // LiveBar handles pause/resume/end.
  const canCancel = $derived(
    geminiLive.state === "live" ||
      (geminiLive.state === "idle" &&
        (chatSession.session?.status === "running" ||
          chatSession.session?.status === "pending")),
  );
  const composerDisabled = $derived(!ready || chatSession.sending);
  const blocks: ChatBlock[] = $derived(chatSession.blocks);

  async function handleSubmit(text: string) {
    const skillsForSend = attachedSkills.slice();
    attachedSkills = [];
    await chatSession.send(text, {
      skills: skillsForSend.length > 0 ? skillsForSend : undefined,
    });
  }

  // wb-xxbm.2 — mic button dictates Moonshine-transcribed text into the
  // draft. Committed transcripts (one per utterance with VAD on) get
  // appended to whatever the user has already typed.
  function handleMicToggle() {
    void moonshineStt.toggle((text) => {
      const sep = draft.length === 0 || /\s$/.test(draft) ? "" : " ";
      draft = draft + sep + text;
      queueMicrotask(() => composerRef?.focus());
    });
  }

  // wb-xxbm.5 — live button toggles a Gemini Live audio session. Uses
  // the currently selected agent's slug (default "workhorse" matches
  // chatSession.send fallback). Streams both sides of the conversation
  // into the chat thread as ChatBlocks so screen-readers (and anyone
  // reading the transcript) get the same surface text speech does.
  let liveUserBlockKey: string | null = null;
  let liveAgentBlockKey: string | null = null;

  function appendOrCreateBlock(
    key: string | null,
    label: string,
    text: string,
    isAgent: boolean,
  ): string {
    if (key) {
      const existing = chatSession.blocks.find((b) => b.key === key);
      if (existing && existing.kind === "message") {
        existing.text += text;
        chatSession.blocks = chatSession.blocks; // nudge reactivity
        return key;
      }
    }
    const newKey = `live-${isAgent ? "agent" : "user"}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    chatSession.blocks = [
      ...chatSession.blocks,
      {
        kind: "message",
        key: newKey,
        label,
        text,
        pending: isAgent,
        error: false,
        errorMessage: null,
        ts: Date.now(),
      },
    ];
    return newKey;
  }

  function handleLiveToggle() {
    console.log(
      "[gemini-live] toggle clicked",
      { state: geminiLive.state, selected: agents.selected },
    );
    // Live button is a true on/off toggle — clicking it while a
    // session is present (live, connecting, paused, or errored)
    // destructively ends. The footer (LiveBar) is gated on
    // `geminiLive.present`, which only becomes false when state
    // returns to "idle" — `pause()` would leave it expanded with a
    // Resume button, which is not what the user expects from a
    // toggle. If we want the resume affordance back, that's a
    // separate UI surface (e.g., a context-menu item).
    if (geminiLive.present) {
      void geminiLive.end();
      return;
    }
    const slug = agents.selected ?? "workhorse";
    // Seed a synthetic session so the thread renders. The block-loop
    // in ChatPanel's template gates on chatSession.session truthiness.
    if (!chatSession.session) {
      chatSession.session = {
        id: `live-${Date.now()}`,
        status: "running",
        startedAt: Date.now(),
        finishedAt: null,
        detail: null,
        prompt: "",
      };
    }
    liveUserBlockKey = null;
    liveAgentBlockKey = null;

    // Pass the active package's folder as workdir so the engine's
    // AgentCatalog.resolve hits project-scope agents
    // (<package>/.oql/agents/<slug>.org) — without this, project-
    // scope agents 404 the system_prompt fetch and Gemini Live can't
    // connect. Fallback to null for the global/built-in agents
    // (workhorse and friends in priv/agents/).
    const workdir = packageStore.active?.folders?.[0] ?? null;

    void geminiLive.start(slug, workdir, {
      onUserTranscript: (text) => {
        liveUserBlockKey = appendOrCreateBlock(
          liveUserBlockKey,
          "you",
          text,
          false,
        );
      },
      onAgentTranscript: (text) => {
        liveAgentBlockKey = appendOrCreateBlock(
          liveAgentBlockKey,
          slug,
          text,
          true,
        );
      },
      onToolCallStart: (id, command) => {
        chatSession.blocks = [
          ...chatSession.blocks,
          {
            kind: "tool",
            key: `live-tool-${id}`,
            toolName: "bash",
            args: { command },
            status: null,
            resultSize: null,
            pending: true,
            ts: Date.now(),
          },
        ];
      },
      onToolCallEnd: (id, output) => {
        const blk = chatSession.blocks.find((b) => b.key === `live-tool-${id}`);
        if (blk && blk.kind === "tool") {
          blk.pending = false;
          blk.status = output.startsWith("exit=0") ? "ok" : "error";
          blk.resultSize = output.length;
          chatSession.blocks = chatSession.blocks;
        }
      },
      onTurnComplete: () => {
        // Mark the in-flight agent block as no longer pending, then
        // reset both keys so the next transcript chunk starts fresh.
        if (liveAgentBlockKey) {
          const blk = chatSession.blocks.find(
            (b) => b.key === liveAgentBlockKey,
          );
          if (blk && blk.kind === "message") {
            blk.pending = false;
            chatSession.blocks = chatSession.blocks;
          }
        }
        liveUserBlockKey = null;
        liveAgentBlockKey = null;
      },
      onError: (message) => {
        chatSession.sendError = message;
      },
      onClose: () => {
        liveUserBlockKey = null;
        liveAgentBlockKey = null;
        // Drop the synthetic session marker so the composer's
        // cancel-button revert path picks the regular send icon back up.
        if (chatSession.session?.id.startsWith("live-")) {
          chatSession.session = null;
        }
      },
    });
  }

  // Auto-scroll to bottom on new content. Only if user is already
  // near the bottom (keep them anchored when they scroll up to read).
  let pinnedToBottom = $state(true);
  function onThreadScroll() {
    if (!threadEl) return;
    const d =
      threadEl.scrollHeight - threadEl.scrollTop - threadEl.clientHeight;
    pinnedToBottom = d < 80;
  }
  $effect(() => {
    void blocks.length;
    if (!threadEl || !pinnedToBottom) return;
    void tick().then(() => {
      if (threadEl) threadEl.scrollTop = threadEl.scrollHeight;
    });
  });

  function fmtArgs(args: unknown): string {
    if (args == null) return "";
    if (typeof args === "string") return args;
    try {
      return JSON.stringify(args, null, 2);
    } catch {
      return String(args);
    }
  }

  function shortId(id: string): string {
    return id.length > 12 ? id.slice(0, 8) + "…" : id;
  }
</script>

<section class="chat">
  <ChatHeader
    oncreate={() => (editorSlug = null)}
    onreset={resetSession}
    onshowscopes={(a) => (scopesAgent = a)}
    onrecallprompt={recallPrompt}
  />
  <div class="thread" bind:this={threadEl} onscroll={onThreadScroll}>
    <div class="thread-inner">
      {#if !ready}
        <div class="welcome">
          Waiting for the OQL agent sidecar
          <span class="state">({sidecar.status.state})</span>.
        </div>
      {:else if !chatSession.session}
        <div class="welcome">
          Start the conversation with the local OQL agent.
          <div class="hint">Cmd+Enter to send · Plain Enter for newline</div>
        </div>
      {/if}

      {#if chatSession.userPrompt}
        <div class="msg user">
          <div class="bubble user-bubble">{chatSession.userPrompt}</div>
        </div>
      {/if}

      {#if chatSession.session}
        <div class="msg agent">
          {#each blocks as b (b.key)}
            {#if b.kind === "message"}
              <div
                class="agent-bubble bubble"
                class:pending={b.pending}
                class:errored={b.error}
              >
                <div class="agent-head">
                  <span class="agent-label">{b.label}</span>
                  {#if b.pending}
                    <Loader2 weight="bold"
                      size={11}
                      class="spin"
                      aria-hidden="true"
                    />
                  {/if}
                </div>
                {#if b.text}
                  <AssistantMessageView text={b.text} />
                {:else if !b.pending}
                  <div class="agent-text muted">(no content)</div>
                {/if}
                {#if b.error && b.errorMessage}
                  <div class="agent-error">{b.errorMessage}</div>
                {/if}
              </div>
            {:else if b.kind === "tool"}
              {@const t = b as ToolCallBlock}
              <button
                type="button"
                class="tool-card"
                class:running={t.pending}
                class:done={!t.pending && t.status === "ok"}
                class:errored={!t.pending && t.status === "error"}
                onclick={() => (openTools[t.key] = !openTools[t.key])}
              >
                <span class="tool-head">
                  <Wrench weight="fill" size={11} aria-hidden="true" />
                  <span class="tool-name">{t.toolName}</span>
                  {#if t.pending}
                    <Loader2 weight="bold"
                      size={11}
                      class="spin"
                      aria-hidden="true"
                    />
                  {:else if t.status === "error"}
                    <AlertCircle weight="fill"
                      size={11}
                      aria-hidden="true"
                    />
                  {:else}
                    <CheckCircle2 weight="fill"
                      size={11}
                      aria-hidden="true"
                    />
                  {/if}
                  <ChevronDown weight="bold"
                    size={10}
                    class="tool-chev"
                    aria-hidden="true"
                  />
                </span>
                {#if openTools[t.key]}
                  {#if t.args !== null && t.args !== undefined}
                    <pre class="tool-body">{fmtArgs(t.args)}</pre>
                  {/if}
                  {#if t.resultSize !== null}
                    <div class="tool-meta">
                      result: {t.resultSize} bytes
                    </div>
                  {/if}
                {/if}
              </button>
            {:else if b.kind === "status"}
              <div class="status-row status-{b.level}">
                <span class="status-label">{b.label}</span>
                {#if b.detail}
                  <span class="status-detail">{b.detail}</span>
                {/if}
              </div>
            {:else if b.kind === "raw"}
              <div class="raw-row">
                <code>{b.name}</code>
              </div>
            {/if}
          {/each}
        </div>
      {/if}

      {#if chatSession.sendError}
        <div class="footer-error">
          <AlertCircle weight="fill" size={12} aria-hidden="true" />
          <span>{chatSession.sendError}</span>
        </div>
      {/if}
    </div>
  </div>

  <div class="composer-wrap">
    {#if chatSession.session?.id && !chatSession.session.id.startsWith("live-")}
      <!-- Live sessions get their status from the bottom LiveBar; no
           need to duplicate it in the composer strip. -->
      <div class="session-strip">
        session <code>{shortId(chatSession.session.id)}</code>
        · {chatSession.session.status}
      </div>
    {/if}
    <ChatComposer
      bind:this={composerRef}
      bind:value={draft}
      placeholder={ready ? "Message the agent…" : "Engine not ready yet"}
      disabled={composerDisabled}
      sending={chatSession.sending}
      canCancel={canCancel}
      onSubmit={handleSubmit}
      onCancel={() => {
        // Single end behavior: any "stop" affordance on the chat
        // ends the live session destructively. The pause/resume
        // dance was confusing — clicking the visible stop control
        // and expecting the bar to stay up is unintuitive. Resume
        // can come back as an explicit context-menu item if we
        // need it.
        if (geminiLive.present) {
          void geminiLive.end();
        } else {
          chatSession.cancel();
        }
      }}
      onMicToggle={handleMicToggle}
      micActive={moonshineStt.active}
      micDisabled={moonshineStt.disabled}
      onLiveToggle={handleLiveToggle}
      liveActive={geminiLive.active}
      liveDisabled={geminiLive.busy}
    >
      {#snippet actions()}
        <ModelPicker compact bind:value={model} onchange={(m) => void setLlmModel(m)} />
      {/snippet}
      {#snippet leading()}
        {#each attachedSkills as slug (slug)}
          <span
            class="skill-chip"
            title="Attached skill — removed on send"
          >
            <span>@{slug}</span>
            <button
              type="button"
              class="chip-x"
              onclick={() => detachSkill(slug)}
              aria-label={`Remove ${slug}`}
            >
              <X weight="bold" size={10} />
            </button>
          </span>
        {/each}
        <SkillPicker attached={attachedSkills} onattach={attachSkill} />
      {/snippet}
    </ChatComposer>
  </div>
</section>

{#if scopesAgent}
  <AgentScopesModal
    agent={scopesAgent}
    oncancel={() => (scopesAgent = null)}
  />
{/if}

{#if editorSlug !== undefined}
  <AgentEditor
    slug={editorSlug}
    oncancel={() => (editorSlug = undefined)}
    onsaved={(slug) => {
      editorSlug = undefined;
      // Select the freshly-created agent.
      // (refresh() already ran inside the editor)
      // No-op if already selected.
      void slug;
    }}
  />
{/if}

<style>
  .chat {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    height: 100%;
  }
  .thread {
    flex: 1;
    overflow-y: auto;
    padding: 1.25rem 1.5rem 1.5rem;
  }
  .thread-inner {
    max-width: 760px;
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .welcome {
    color: var(--color-fg-subtle);
    font-size: 13px;
    text-align: center;
    padding: 3rem 1rem;
  }
  .welcome .state {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    color: var(--color-fg-muted);
  }
  .welcome .hint {
    margin-top: 0.6rem;
    font-size: 11.5px;
    color: var(--color-fg-subtle);
  }

  .msg {
    display: flex;
  }
  .msg.user {
    justify-content: flex-end;
  }
  .msg.agent {
    flex-direction: column;
    align-items: stretch;
    gap: 0.6rem;
  }

  .bubble {
    max-width: 720px;
    padding: 0.6rem 0.85rem;
    border-radius: 12px;
    font-size: 13.5px;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .user-bubble {
    background: var(--color-surface-soft);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    border-bottom-right-radius: 4px;
  }
  @media (prefers-color-scheme: dark) {
    .user-bubble {
      background: #15151a;
      border-color: rgba(255, 255, 255, 0.06);
    }
  }
  .agent-bubble {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-bottom-left-radius: 4px;
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .agent-bubble.pending {
    border-color: var(--color-border-strong);
  }
  .agent-bubble.errored {
    border-color: rgba(239, 68, 68, 0.4);
  }
  .agent-head {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 10.5px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .agent-label {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    text-transform: none;
    letter-spacing: 0;
  }
  .agent-text {
    color: var(--color-fg);
  }
  .agent-text.muted {
    color: var(--color-fg-muted);
    font-style: italic;
  }
  .agent-error {
    color: #b91c1c;
    font-size: 12px;
    border-top: 1px solid rgba(239, 68, 68, 0.18);
    padding-top: 0.35rem;
  }

  .tool-card {
    align-self: flex-start;
    max-width: 720px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    font-size: 12px;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-align: left;
    cursor: pointer;
    padding: 0;
    display: flex;
    flex-direction: column;
    width: auto;
  }
  .tool-card:hover {
    border-color: var(--color-border-strong);
  }
  .tool-card.done {
    color: var(--color-fg);
  }
  .tool-card.errored {
    border-color: rgba(239, 68, 68, 0.3);
    color: #b91c1c;
  }
  .tool-head {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.35rem 0.7rem;
  }
  .tool-name {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font-size: 12px;
    color: var(--color-fg);
  }
  :global(.tool-chev) {
    margin-left: 0.4rem;
    color: var(--color-fg-subtle);
  }
  .tool-body {
    margin: 0;
    padding: 0.55rem 0.7rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font-size: 11.5px;
    line-height: 1.45;
    color: var(--color-fg);
    white-space: pre-wrap;
    max-height: 280px;
    overflow-y: auto;
  }
  .tool-meta {
    padding: 0.3rem 0.7rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    font-size: 11px;
    color: var(--color-fg-subtle);
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  }

  .status-row {
    align-self: stretch;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.4rem 0.7rem;
    border-radius: var(--radius-sm);
    font-size: 11.5px;
    border: 1px solid var(--color-border);
  }
  .status-info {
    color: var(--color-fg-subtle);
    background: transparent;
    border: 0;
    justify-content: center;
    padding: 0.2rem 0;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    font-size: 10.5px;
  }
  .status-ok {
    background: rgba(16, 185, 129, 0.06);
    border-color: rgba(16, 185, 129, 0.25);
    color: #047857;
  }
  .status-warn {
    background: rgba(245, 158, 11, 0.07);
    border-color: rgba(245, 158, 11, 0.3);
    color: #92400e;
  }
  .status-error {
    background: rgba(239, 68, 68, 0.06);
    border-color: rgba(239, 68, 68, 0.25);
    color: #b91c1c;
  }
  .status-label {
    font-weight: 600;
  }
  .status-detail {
    color: var(--color-fg-muted);
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  }

  .raw-row {
    align-self: flex-start;
    font-size: 11px;
    color: var(--color-fg-subtle);
    padding: 0.15rem 0;
  }
  .raw-row code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
  }

  .footer-error {
    align-self: stretch;
    display: flex;
    align-items: center;
    gap: 0.4rem;
    background: rgba(239, 68, 68, 0.06);
    border: 1px solid rgba(239, 68, 68, 0.18);
    padding: 0.5rem 0.75rem;
    border-radius: var(--radius-sm);
    color: #b91c1c;
    font-size: 12px;
  }

  .composer-wrap {
    max-width: 720px;
    width: 100%;
    margin: 0 auto;
    padding: 0.5rem 1rem 1rem;
  }
  .session-strip {
    padding: 0 0.5rem 0.4rem;
    font-size: 11px;
    color: var(--color-fg-subtle);
  }
  .session-strip code {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    color: var(--color-fg-muted);
  }
  .skill-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.2rem;
    height: 22px;
    padding: 0 0.4rem 0 0.5rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    color: var(--color-fg);
    font-size: 11.5px;
    font-family: var(--font-mono, ui-monospace, monospace);
  }
  .chip-x {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 14px;
    height: 14px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 50%;
    cursor: pointer;
    padding: 0;
  }
  .chip-x:hover {
    background: var(--color-border);
    color: var(--color-fg);
  }
</style>
