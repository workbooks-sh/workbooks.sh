<script lang="ts">
  /**
   * WaldoPanel — the browser's ONE resident agent (the canonical chat surface).
   *
   * A single voice you summon to set up + work the system: text via OpenRouter
   * (chatSession) + voice via inworldLive. Talks to the "waldo" slug. The older
   * multi-agent ChatPanel/ChatHeader chrome is flagged off; the good pieces
   * (session history, rich org/component render, typing) live HERE now.
   *
   * Pitch guard: a communicator you summon, never a self-running manager.
   */
  import {
    PaperPlaneRight,
    Wrench,
    Compass,
    ClockCounterClockwise,
    Plus,
    CaretLeft,
    CaretRight,
    ArrowsOut,
    ArrowsIn,
    Microphone as Mic,
    MicrophoneSlash as MicOff,
    PhoneSlash as PhoneOff,
    Waveform,
    Check,
    XCircle,
    CircleNotch,
    WarningCircle,
  } from "phosphor-svelte";
  import { onMount } from "svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { dock } from "$lib/bridge/dock.svelte";
  import { sessionHistory, type SavedSession } from "$lib/chat/session_history.svelte";
  import AssistantMessageView from "$lib/chat/AssistantMessageView.svelte";
  import ArtifactCard from "$lib/chat/ArtifactCard.svelte";
  import { componentArtifacts } from "$lib/chat/artifacts.svelte";
  import { inworldLive } from "$lib/live/inworld.svelte";
  import { openChatTab } from "$lib/tabs/chatTab";

  const WALDO_SLUG = "waldo";

  // When popped out into a full tab the panel owns the whole canvas; the
  // top bar swaps its dock affordance (pop-out → dock-back) accordingly.
  let { fullscreen = false }: { fullscreen?: boolean } = $props();

  const SUGGESTIONS = [
    { icon: Plus, label: "Create a workbook", text: "Can you create a workbook for me?" },
    { icon: Wrench, label: "Set up an agent", text: "Set me up an agent that summarizes my notes" },
    { icon: Compass, label: "What can you do?", text: "What can you do in this browser?" },
  ];

  let prompt = $state("");
  let sending = $state(false);
  let composerEl = $state<HTMLTextAreaElement | null>(null);
  let view = $state<"chat" | "history">("chat");
  let viewing = $state<SavedSession | null>(null); // a past session opened read-only
  // User-message echoes live on the chatSession store (not local state) so the
  // transcript survives this panel remounting — opening the live chat as a tab
  // and switching back re-mounts WaldoPanel, and the conversation must persist.
  const myLines = $derived(chatSession.userEchoes);
  let lastSavedId: string | null = null;

  const ready = $derived(sidecar.status.state === "ready");

  // Subscribe the chat session to the bridge stream (idempotent). Without
  // this, agent telemetry — including the component_artifact event the
  // component-toolkit emits — never reaches the panel.
  onMount(() => chatSession.init());

  // Merge user echoes + agent blocks into one time-ordered transcript.
  type Line = {
    who: "you" | "waldo";
    text: string;
    ts: number;
    kind: string;
    pending?: boolean;
    error?: boolean;
    artifact?: { path: string; title: string; action: "created" | "updated" };
  };
  const transcript = $derived.by<Line[]>(() => {
    const mine: Line[] = myLines.map((m) => ({ who: "you", text: m.text, ts: m.ts, kind: "msg" }));
    const theirs = chatSession.blocks
      .map((b): Line | null => {
        if (b.kind === "message") return { who: "waldo", text: b.text, ts: b.ts, kind: "msg", pending: b.pending, error: b.error };
        if (b.kind === "tool") return { who: "waldo", text: `${b.toolName}${b.pending ? "…" : ""}`, ts: b.ts, kind: "tool" };
        if (b.kind === "status") return { who: "waldo", text: b.label, ts: b.ts, kind: "status" };
        if (b.kind === "artifact") return { who: "waldo", text: b.title, ts: b.ts, kind: "artifact", artifact: { path: b.path, title: b.title, action: b.action } };
        return null;
      })
      .filter((x): x is Line => x !== null);
    return [...mine, ...theirs].sort((a, b) => (a.ts ?? 0) - (b.ts ?? 0));
  });

  // Show "thinking" between send and the first agent output.
  const thinking = $derived(
    !viewing &&
      (sending || chatSession.session?.status === "pending" || chatSession.session?.status === "running") &&
      !transcript.some((m) => m.who === "waldo" && (m.text || m.pending)),
  );

  // Persist each finished exchange so history can read it back.
  $effect(() => {
    const s = chatSession.session;
    if (s && s.status === "completed" && s.id !== lastSavedId) {
      const lines = transcript
        .filter((m) => m.kind === "msg" || m.kind === "tool" || m.kind === "artifact")
        .map((m) => ({ who: m.who, text: m.text, kind: m.kind, artifact: m.artifact }));
      if (lines.length > 0) {
        sessionHistory.save({
          id: s.id,
          agent: WALDO_SLUG,
          title: (myLines.at(-1)?.text ?? lines[0]?.text ?? "Chat").slice(0, 80),
          ts: s.startedAt ?? Date.now(),
          lines,
        });
        lastSavedId = s.id;
      }
    }
  });

  function useSuggestion(text: string) {
    prompt = text;
    composerEl?.focus();
  }
  function newChat() {
    chatSession.clearTranscript();
    componentArtifacts.reset();
    viewing = null;
    view = "chat";
    composerEl?.focus();
  }
  function openHistory() {
    sessionHistory.ensureLoaded();
    view = "history";
  }
  function openSession(s: SavedSession) {
    viewing = s;
    view = "chat";
  }

  async function send() {
    const t = prompt.trim();
    if (!t || sending || !ready) return;
    sending = true;
    viewing = null;
    const firstMessage = myLines.length === 0;
    chatSession.pushEcho(t);
    prompt = "";
    // First message of a conversation opens a returnable tab bound to this
    // chat (Feature 2). The dock panel + the tab share the chatSession
    // singleton, so the user can switch tabs and come back to the live thread.
    if (firstMessage && !fullscreen) void openChatTab(WALDO_SLUG);
    try {
      await chatSession.send(t, { agentSlug: WALDO_SLUG });
    } catch (e) {
      console.warn("[waldo] send failed", e);
    } finally {
      sending = false;
    }
  }

  function onKey(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void send();
    }
  }

  // ── Voice mode ─────────────────────────────────────────────────────
  //
  // The mic toggle morphs the chat surface into a live voice
  // conversation: a status strip + a transcript pane carrying both
  // sides of the spoken exchange plus any bash/tool calls Waldo runs.
  // Same Gemini Live transport as the home composer, scoped to the
  // "waldo" slug. Survives tool/bash calls (the breakage that's fixed
  // in gemini.svelte: a failed exec degrades gracefully instead of
  // tearing down the session).
  // Voice transcript + error live on the chatSession store (shared) so a voice
  // conversation started in the dock stays visible in the returnable chat tab,
  // surviving panel remounts. "Voice mode" = a live session is present, so any
  // mount of this panel reflects the same voice state.
  const voiceMode = $derived(inworldLive.present);
  const voiceBubbles = $derived(chatSession.voiceBubbles);
  const voiceError = $derived(chatSession.voiceError);
  let voiceScrollEl = $state<HTMLDivElement | null>(null);
  let toolExpanded = $state<Record<string, boolean>>({});

  async function endVoice() {
    await inworldLive.end();
  }

  // Auto-scroll the voice transcript as chunks arrive.
  $effect(() => {
    void voiceBubbles.length;
    if (voiceScrollEl) {
      queueMicrotask(() => {
        voiceScrollEl!.scrollTop = voiceScrollEl!.scrollHeight;
      });
    }
  });

  // NOTE: do NOT tear the voice session down on unmount. The session is a
  // module singleton shared by the dock panel and the chat tab; unmounting one
  // surface (e.g. popping out into the tab) must not kill a live call. The
  // session ends only via the explicit END control (endVoice).

  const voiceStatus = $derived.by(() => {
    switch (inworldLive.state) {
      case "connecting": return "Connecting…";
      case "live": return inworldLive.muted ? "Muted" : "Listening";
      case "error": return inworldLive.error ?? "Voice session error";
      default: return "Waldo";
    }
  });

  function relTime(ts: number): string {
    const s = Math.max(0, Math.round((Date.now() - ts) / 1000));
    if (s < 60) return "just now";
    if (s < 3600) return `${Math.floor(s / 60)}m ago`;
    if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
    return `${Math.floor(s / 86400)}d ago`;
  }

</script>

<div class="waldo" class:fullscreen>
  <div class="bar">
    {#if view === "history" || viewing}
      <button type="button" class="bar-btn" onclick={() => { view = "chat"; viewing = null; }}>
        <CaretLeft size={13} weight="bold" /> Back
      </button>
    {:else}
      <button type="button" class="bar-btn" onclick={openHistory} title="Past chats">
        <ClockCounterClockwise size={13} weight="bold" /> Chats
      </button>
    {/if}
    <span class="spacer"></span>
    {#if !voiceMode && view === "chat" && !viewing && (transcript.length > 0 || sending)}
      <button type="button" class="bar-btn" onclick={newChat} title="New chat">
        <Plus size={13} weight="bold" /> New
      </button>
    {/if}
    {#if fullscreen}
      <button
        type="button"
        class="bar-btn icon-only"
        onclick={() => dock.dockIn()}
        title="Dock to side panel"
        aria-label="Dock Waldo back into the side panel"
      >
        <ArrowsIn size={15} weight="bold" />
      </button>
    {:else}
      <button
        type="button"
        class="bar-btn icon-only"
        onclick={() => dock.popOut("waldo")}
        title="Open as full tab"
        aria-label="Open Waldo as a full tab"
      >
        <ArrowsOut size={15} weight="bold" />
      </button>
      <button type="button" class="bar-btn icon-only" onclick={() => dock.close()} title="Collapse" aria-label="Collapse panel">
        <CaretRight size={15} weight="bold" />
      </button>
    {/if}
  </div>

  {#if voiceMode}
    <!-- Live voice conversation: status strip + transcript pane. -->
    <div class="voice-shell" class:errored={inworldLive.state === "error"}>
      <div class="voice-strip">
        <span class="voice-dot" class:muted={inworldLive.muted} class:off={inworldLive.state !== "live"}></span>
        <span class="voice-status">{voiceStatus}</span>
        <div class="voice-actions">
          <button
            type="button"
            class="voice-btn"
            onclick={() => inworldLive.toggleMute()}
            disabled={inworldLive.state !== "live"}
            title={inworldLive.muted ? "Unmute" : "Mute"}
            aria-label={inworldLive.muted ? "Unmute" : "Mute"}
          >
            {#if inworldLive.muted}<MicOff size={15} weight="fill" />{:else}<Mic size={15} weight="fill" />{/if}
          </button>
          <button type="button" class="voice-btn end" onclick={endVoice} title="End session" aria-label="End voice conversation">
            <PhoneOff size={15} weight="fill" />
          </button>
        </div>
      </div>
    </div>
    <div class="voice-transcript" bind:this={voiceScrollEl}>
      {#if voiceBubbles.length === 0 && inworldLive.state !== "error"}
        <div class="voice-empty">
          <Waveform size={15} weight="fill" />
          <span>{inworldLive.state === "connecting" ? "Opening mic…" : "Waldo is about to speak."}</span>
        </div>
      {/if}
      {#each voiceBubbles as b (b.id)}
        {#if b.kind === "msg"}
          <div class="bubble {b.who}">
            <span class="tag">{b.who === "waldo" ? "Waldo" : "You"}</span>
            {#if b.who === "waldo"}<AssistantMessageView text={b.text} />{:else}<span class="text">{b.text}</span>{/if}
          </div>
        {:else}
          <button
            type="button"
            class="tool-block"
            class:running={b.status === "running"}
            class:done={b.status === "ok"}
            class:errored={b.status === "error"}
            onclick={() => (toolExpanded[b.callId] = !toolExpanded[b.callId])}
          >
            <span class="tool-head">
              <Wrench size={11} weight="fill" />
              <span class="tool-name">terminal</span>
              {#if b.status === "running"}
                <CircleNotch size={11} weight="bold" class="spin" />
              {:else if b.status === "ok"}
                <Check size={11} weight="bold" />
              {:else}
                <XCircle size={11} weight="fill" />
              {/if}
            </span>
            <code class="tool-cmd">{b.command}</code>
            {#if toolExpanded[b.callId] && b.output}
              <pre class="tool-output">{b.output}</pre>
            {/if}
          </button>
        {/if}
      {/each}
      {#if voiceError}
        <div class="voice-err"><WarningCircle size={12} weight="fill" /><span>{voiceError}</span></div>
      {/if}
    </div>
  {:else if view === "history"}
    <div class="history">
      {#if sessionHistory.sessions.length === 0}
        <p class="empty-note">No past chats yet — your conversations show up here.</p>
      {:else}
        {#each sessionHistory.sessions as s (s.id)}
          <button type="button" class="hist-row" onclick={() => openSession(s)}>
            <span class="hist-title">{s.title}</span>
            <span class="hist-meta">{relTime(s.ts)}</span>
          </button>
        {/each}
      {/if}
    </div>
  {:else if viewing}
    <div class="thread">
      {#each viewing.lines as m, i (i)}
        {#if m.kind === "artifact" && m.artifact}
          <div class="artifact-line">
            <ArtifactCard path={m.artifact.path} title={m.artifact.title} action={m.artifact.action} />
          </div>
        {:else}
          <div class="bubble {m.who}" class:tool={m.kind === "tool"}>
            {#if m.who === "waldo" && m.kind === "msg"}
              <span class="tag">Waldo</span><AssistantMessageView text={m.text} />
            {:else}
              <span class="text">{m.text}</span>
            {/if}
          </div>
        {/if}
      {/each}
    </div>
  {:else if transcript.length > 0}
    <div class="thread">
      {#each transcript as m, i (m.ts + "-" + i)}
        {#if m.kind === "artifact" && m.artifact}
          <div class="artifact-line">
            <ArtifactCard path={m.artifact.path} title={m.artifact.title} action={m.artifact.action} />
          </div>
        {:else}
          <div class="bubble {m.who}" class:tool={m.kind === "tool"} class:err={m.error}>
            {#if m.who === "waldo" && m.kind === "msg"}
              <span class="tag">Waldo</span>
              {#if m.text}<AssistantMessageView text={m.text} />{:else if m.pending}<span class="text dim">…</span>{/if}
            {:else}
              <span class="text">{m.text}</span>
            {/if}
          </div>
        {/if}
      {/each}
      {#if thinking}
        <div class="bubble waldo">
          <span class="tag">Waldo</span>
          <span class="typing"><span></span><span></span><span></span></span>
        </div>
      {/if}
    </div>
  {:else}
    <div class="intro">
      {#if ready}
        <div class="suggestions">
          {#each SUGGESTIONS as s (s.label)}
            {@const SIcon = s.icon}
            <button type="button" class="chip" onclick={() => useSuggestion(s.text)}>
              <SIcon size={13} weight="bold" />
              {s.label}
            </button>
          {/each}
        </div>
      {:else}
        <p class="hint">Connect a nexus and add your OpenRouter key to wake Waldo.</p>
      {/if}
    </div>
  {/if}

  {#if !voiceMode && view !== "history"}
    <form class="composer" onsubmit={(e) => { e.preventDefault(); void send(); }}>
      <textarea
        bind:this={composerEl}
        bind:value={prompt}
        onkeydown={onKey}
        placeholder={ready ? "Ask Waldo…" : "Connect a nexus first"}
        rows="2"
        spellcheck="false"
        disabled={!ready || sending}
      ></textarea>
      <div class="composer-foot">
        <span class="kbd">⌘↵</span>
        <button type="submit" class="send" disabled={!ready || !prompt.trim() || sending} aria-label="Send">
          <PaperPlaneRight size={14} weight="fill" />
        </button>
      </div>
    </form>
  {/if}
</div>

<style>
  .waldo {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
  }

  /* Full-tab mode: the panel owns the whole canvas. Center the thread +
   * composer on a comfortable reading column so a 1400px window doesn't
   * stretch bubbles edge-to-edge. The bar stays full-width. */
  .waldo.fullscreen { background: var(--color-page); }
  .waldo.fullscreen .thread,
  .waldo.fullscreen .composer,
  .waldo.fullscreen .intro,
  .waldo.fullscreen .history {
    width: 100%;
    max-width: 760px;
    margin-inline: auto;
  }
  .waldo.fullscreen .thread { padding-inline: 16px; }

  /* Slim in-panel toolbar — history / back / new. */
  .bar {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding: 6px 8px;
    border-bottom: 1px solid var(--color-border);
    flex-shrink: 0;
  }
  .bar .spacer { flex: 1; }
  .bar-btn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 8px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg-muted);
    font-size: 0.76rem;
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
  }
  .bar-btn:hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .bar-btn.icon-only { padding: 3px 5px; }

  /* ── empty state ─────────────────────────────────────────────────────────── */
  .intro {
    position: relative;
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.7rem;
    padding: 1.5rem;
    text-align: center;
    overflow: hidden;
  }
  .intro .hint {
    font-family: var(--font-mono);
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
    max-width: 32ch;
  }
  .suggestions {
    position: relative;
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 6px;
    margin-top: 4px;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 11px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font-size: 0.78rem;
    cursor: pointer;
    transition: border-color 0.14s, color 0.14s, background 0.14s;
  }
  .chip:hover { border-color: var(--color-border-strong); color: var(--color-fg); background: var(--color-surface); }

  /* ── history list ────────────────────────────────────────────────────────── */
  .history {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 6px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .empty-note {
    margin: auto;
    padding: 2rem 1.5rem;
    text-align: center;
    font-size: 0.8rem;
    color: var(--color-fg-subtle);
    max-width: 28ch;
  }
  .hist-row {
    display: flex;
    align-items: baseline;
    gap: 0.6rem;
    width: 100%;
    padding: 9px 10px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
    transition: background 0.12s;
  }
  .hist-row:hover { background: var(--color-surface-soft); }
  .hist-title {
    flex: 1;
    min-width: 0;
    font-size: 0.84rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .hist-meta {
    flex-shrink: 0;
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
  }

  /* ── thread ──────────────────────────────────────────────────────────────── */
  .thread {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .artifact-line {
    align-self: flex-start;
    max-width: 90%;
  }
  .bubble {
    max-width: 90%;
    padding: 8px 11px;
    border-radius: 12px;
    font-size: 0.85rem;
    line-height: 1.5;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .bubble.you { align-self: flex-end; background: var(--color-fg); color: var(--color-page); }
  .bubble.waldo { align-self: flex-start; background: var(--color-surface-soft); color: var(--color-fg); }
  .bubble.tool {
    font-family: var(--font-mono);
    font-size: 0.74rem;
    color: var(--color-fg-muted);
    background: transparent;
    padding: 2px 11px;
  }
  .bubble.err { color: var(--color-err); }
  .bubble .tag {
    display: block;
    font-family: var(--font-mono);
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--color-fg-subtle);
    margin-bottom: 2px;
  }
  .text.dim { color: var(--color-fg-subtle); }

  .typing { display: inline-flex; gap: 3px; padding: 2px 0; }
  .typing span {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: var(--color-fg-subtle);
    animation: typing-bounce 1.2s infinite ease-in-out both;
  }
  .typing span:nth-child(1) { animation-delay: -0.24s; }
  .typing span:nth-child(2) { animation-delay: -0.12s; }
  @keyframes typing-bounce {
    0%, 80%, 100% { transform: translateY(0); opacity: 0.4; }
    40% { transform: translateY(-3px); opacity: 1; }
  }

  /* ── composer ────────────────────────────────────────────────────────────── */
  .composer {
    flex-shrink: 0;
    border-top: 1px solid var(--color-border);
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .composer textarea {
    width: 100%;
    resize: none;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.85rem;
    outline: none;
  }
  .composer textarea::placeholder { color: var(--color-fg-subtle); }
  .composer-foot { display: flex; align-items: center; gap: 8px; }
  .send {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    background: var(--color-fg);
    color: var(--color-page);
  }
  .kbd { margin-left: auto; font-family: var(--font-mono); font-size: 10px; color: var(--color-fg-subtle); }
  .send:disabled { opacity: 0.45; cursor: default; }

  /* ── voice mode ──────────────────────────────────────────────────────────── */
  .mic-toggle:not(:disabled):hover { color: var(--color-brand, #3fe081); }

  .voice-shell {
    flex-shrink: 0;
    margin: 8px;
    border: 1.5px solid transparent;
    border-radius: 10px;
    background:
      linear-gradient(var(--color-surface), var(--color-surface)) padding-box,
      linear-gradient(
        90deg,
        var(--gradient-aurora-a, #3fe081),
        var(--gradient-aurora-b, #4ecdc4),
        var(--gradient-aurora-c, #7aa2ff),
        var(--gradient-aurora-d, #b794f6),
        var(--gradient-aurora-a, #3fe081)
      ) border-box;
    background-size: 100% 100%, 200% 100%;
    animation: waldo-aurora-flow 12s linear infinite;
  }
  @keyframes waldo-aurora-flow {
    from { background-position: 0% 0%, 0% 0%; }
    to   { background-position: 0% 0%, 200% 0%; }
  }
  .voice-shell.errored {
    border: 1.5px solid color-mix(in srgb, var(--color-err) 55%, var(--color-border-strong));
    background: var(--color-surface);
    animation: none;
  }
  @media (prefers-reduced-motion: reduce) { .voice-shell { animation: none; } }

  .voice-strip {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    padding: 0.6rem 0.6rem 0.6rem 0.85rem;
  }
  .voice-dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--color-brand, #3fe081);
    box-shadow: 0 0 8px color-mix(in srgb, var(--color-brand, #3fe081) 70%, transparent);
    animation: voice-dot-pulse 1.6s ease-out infinite;
    flex-shrink: 0;
  }
  .voice-dot.muted { background: var(--color-warn, #fbbf24); box-shadow: none; animation: none; }
  .voice-dot.off { background: var(--color-fg-subtle); box-shadow: none; animation: none; }
  @keyframes voice-dot-pulse {
    0%   { box-shadow: 0 0 0 0 color-mix(in srgb, var(--color-brand, #3fe081) 60%, transparent); }
    70%  { box-shadow: 0 0 0 6px transparent; }
    100% { box-shadow: 0 0 0 0 transparent; }
  }
  .voice-status { flex: 1; font-size: 0.86rem; color: var(--color-fg); }
  .voice-actions { display: inline-flex; gap: 0.25rem; }
  .voice-btn {
    display: inline-flex; align-items: center; justify-content: center;
    width: 30px; height: 30px; border: 0; border-radius: 7px;
    background: transparent; color: var(--color-fg-muted); cursor: pointer;
    transition: background 0.1s, color 0.1s;
  }
  .voice-btn:not(:disabled):hover { background: var(--color-surface-soft); color: var(--color-fg); }
  .voice-btn:disabled { opacity: 0.4; cursor: default; }
  .voice-btn.end { background: color-mix(in srgb, var(--color-err) 14%, var(--color-surface)); color: var(--color-err); }
  .voice-btn.end:hover { background: color-mix(in srgb, var(--color-err) 24%, var(--color-surface)); }

  .voice-transcript {
    flex: 1; min-height: 0; overflow-y: auto;
    padding: 6px 12px 12px;
    display: flex; flex-direction: column; gap: 8px;
  }
  .voice-empty {
    display: inline-flex; align-items: center; gap: 0.5rem;
    padding: 0.6rem 0; color: var(--color-fg-muted); font-size: 0.84rem;
  }
  .voice-err {
    display: inline-flex; align-items: center; gap: 0.4rem;
    padding: 0.4rem 0.55rem; font-size: 0.8rem; color: var(--color-err);
    background: color-mix(in srgb, var(--color-err) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-err) 30%, var(--color-border));
    border-radius: 7px;
  }

  /* tool-call block in the voice transcript */
  .tool-block {
    display: flex; flex-direction: column; gap: 0.35rem;
    padding: 0.5rem 0.7rem; border: 1px solid var(--color-border);
    background: var(--color-surface-soft); color: var(--color-fg);
    border-radius: 8px; cursor: pointer; text-align: left; font: inherit;
    align-self: flex-start; max-width: 100%;
    transition: background 0.1s, border-color 0.1s;
  }
  .tool-block:hover { background: var(--color-surface); border-color: var(--color-fg-muted); }
  .tool-block.running { border-color: color-mix(in srgb, var(--color-warn, #fbbf24) 50%, var(--color-border-strong)); }
  .tool-block.done { border-color: color-mix(in srgb, var(--color-ok, #3fe081) 35%, var(--color-border-strong)); }
  .tool-block.errored {
    border-color: color-mix(in srgb, var(--color-err) 50%, var(--color-border-strong));
    background: color-mix(in srgb, var(--color-err) 5%, var(--color-surface-soft));
  }
  .tool-head {
    display: inline-flex; align-items: center; gap: 0.4rem;
    font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--color-fg-muted); font-weight: 600;
  }
  .tool-block.done .tool-head { color: var(--color-ok, #3fe081); }
  .tool-block.errored .tool-head { color: var(--color-err); }
  :global(.tool-head .spin) { animation: tool-spin 1s linear infinite; }
  @keyframes tool-spin { to { transform: rotate(360deg); } }
  .tool-cmd {
    font-family: var(--font-mono); font-size: 0.78rem; color: var(--color-fg);
    white-space: pre-wrap; word-break: break-all; line-height: 1.45;
  }
  .tool-output {
    margin: 0.35rem 0 0; padding: 0.5rem 0.65rem;
    background: var(--color-page); border: 1px solid var(--color-border);
    border-radius: 6px; font-family: var(--font-mono); font-size: 0.72rem;
    color: var(--color-fg-muted); white-space: pre-wrap; word-break: break-all;
    max-height: 220px; overflow-y: auto;
  }
</style>
