<script lang="ts">
  /**
   * WaldoPanel — the browser's ONE resident agent (the canonical chat surface).
   *
   * A single voice you summon to set up + work the system: text via OpenRouter
   * (chatSession) + voice via geminiLive. Talks to the "waldo" slug. The older
   * multi-agent ChatPanel/ChatHeader chrome is flagged off; the good pieces
   * (session history, rich org/component render, typing) live HERE now.
   *
   * Pitch guard: a communicator you summon, never a self-running manager.
   */
  import {
    PaperPlaneRight,
    MagnifyingGlass,
    Wrench,
    Compass,
    ClockCounterClockwise,
    Plus,
    CaretLeft,
    CaretRight,
    ArrowsOut,
    ArrowsIn,
  } from "phosphor-svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { dock } from "$lib/bridge/dock.svelte";
  import { sessionHistory, type SavedSession } from "$lib/chat/session_history.svelte";
  import AssistantMessageView from "$lib/chat/AssistantMessageView.svelte";

  const WALDO_SLUG = "waldo";

  // When popped out into a full tab the panel owns the whole canvas; the
  // top bar swaps its dock affordance (pop-out → dock-back) accordingly.
  let { fullscreen = false }: { fullscreen?: boolean } = $props();

  const SUGGESTIONS = [
    { icon: MagnifyingGlass, label: "Search my files", text: "Search my files for " },
    { icon: Wrench, label: "Set up my agents", text: "Help me connect Claude Code to this workspace" },
    { icon: Compass, label: "What can you do?", text: "What can you do in this browser?" },
  ];

  let prompt = $state("");
  let sending = $state(false);
  let composerEl = $state<HTMLTextAreaElement | null>(null);
  let view = $state<"chat" | "history">("chat");
  let viewing = $state<SavedSession | null>(null); // a past session opened read-only
  let myLines = $state<{ text: string; ts: number }[]>([]);
  let lastSavedId: string | null = null;

  const ready = $derived(sidecar.status.state === "ready");

  // Merge user echoes + agent blocks into one time-ordered transcript.
  type Line = { who: "you" | "waldo"; text: string; ts: number; kind: string; pending?: boolean; error?: boolean };
  const transcript = $derived.by<Line[]>(() => {
    const mine: Line[] = myLines.map((m) => ({ who: "you", text: m.text, ts: m.ts, kind: "msg" }));
    const theirs = chatSession.blocks
      .map((b): Line | null => {
        if (b.kind === "message") return { who: "waldo", text: b.text, ts: b.ts, kind: "msg", pending: b.pending, error: b.error };
        if (b.kind === "tool") return { who: "waldo", text: `${b.toolName}${b.pending ? "…" : ""}`, ts: b.ts, kind: "tool" };
        if (b.kind === "status") return { who: "waldo", text: b.label, ts: b.ts, kind: "status" };
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
        .filter((m) => m.kind === "msg" || m.kind === "tool")
        .map((m) => ({ who: m.who, text: m.text, kind: m.kind }));
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
    myLines = [];
    chatSession.blocks = [];
    chatSession.session = null;
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
    myLines = [...myLines, { text: t, ts: Date.now() }];
    prompt = "";
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
    {#if view === "chat" && !viewing && (transcript.length > 0 || sending)}
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

  {#if view === "history"}
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
        <div class="bubble {m.who}" class:tool={m.kind === "tool"}>
          {#if m.who === "waldo" && m.kind === "msg"}
            <span class="tag">Waldo</span><AssistantMessageView text={m.text} />
          {:else}
            <span class="text">{m.text}</span>
          {/if}
        </div>
      {/each}
    </div>
  {:else if transcript.length > 0}
    <div class="thread">
      {#each transcript as m, i (m.ts + "-" + i)}
        <div class="bubble {m.who}" class:tool={m.kind === "tool"} class:err={m.error}>
          {#if m.who === "waldo" && m.kind === "msg"}
            <span class="tag">Waldo</span>
            {#if m.text}<AssistantMessageView text={m.text} />{:else if m.pending}<span class="text dim">…</span>{/if}
          {:else}
            <span class="text">{m.text}</span>
          {/if}
        </div>
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

  {#if view !== "history"}
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
</style>
