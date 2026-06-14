<script lang="ts">
  /**
   * HomePanel — the locked-in create surface (wb-5hc0.1).
   *
   * Conceptual model: this is where you land when you want to start
   * or create something but haven't picked which thing yet. The visual
   * anchor is the composer. Above it, an "Ask the workspace" chip
   * opens a minimalist AI palette (wb-5hc0.2). The agent picker lives
   * in the composer footer so the active agent is always visible.
   * Below, a short row of explicit "+ X" create entry points for
   * things the palette can't disambiguate quickly (boards, packages,
   * workbooks, skills).
   *
   * No bookmarks. No recents. No suggestions grid. Empty calm.
   *
   * Submit behavior: pushes the prompt into chatSession.send() AND
   * opens the right-side AgentPanel so the user immediately sees the
   * thread their input started.
   */
  import { onMount, onDestroy } from "svelte";
  import { fade, fly } from "svelte/transition";
  import { ArrowUp, ArrowUUpLeft as Undo2, Waveform as AudioLines, Microphone as Mic, MicrophoneSlash as MicOff, PhoneSlash as PhoneOff, WarningCircle as AlertCircle, Wrench, CircleNotch as Loader2, Check, XCircle } from "phosphor-svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { keys } from "$lib/bridge/keys.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { features } from "$lib/bridge/features";
  import { dock } from "$lib/bridge/dock.svelte";

  // Multi-agent chrome (the agents catalog + its picker) is gated by
  // WB_FF_AGENTS (wb-aakl.2) and lazily imported so a flags-off build
  // excludes the catalog store. The single Workhorse chatSession + voice
  // below are NOT gated — they're the transport Waldo (wb-aakl.21) lifts.
  let agents = $state<typeof import("$lib/bridge/agents.svelte").agents | null>(null);
  let AgentPickerDropdown =
    $state<typeof import("$lib/chat/AgentPickerDropdown.svelte").default | null>(null);
  $effect(() => {
    if (!features.agents || agents) return;
    void import("$lib/bridge/agents.svelte").then((m) => {
      agents = m.agents;
      m.agents.init();
    });
    void import("$lib/chat/AgentPickerDropdown.svelte").then(
      (m) => (AgentPickerDropdown = m.default),
    );
  });
  import { createPackage } from "./createPackage.svelte";
  import {
    geminiLive,
    type ExtraFunctionDecl,
  } from "$lib/live/gemini.svelte";

  let prompt = $state("");
  let textareaEl: HTMLTextAreaElement | null = $state(null);
  let sending = $state(false);
  let error = $state<string | null>(null);

  // ── Voice mode (wb-nlts) ──
  //
  // Toggling voice morphs the composer in place: textarea hides, the
  // status strip + transcript take its place. The session runs against
  // Workhorse with the brainstorming skill attached — same Gemini Live
  // transport that used to live in the palette.
  type Bubble =
    | { kind: "msg"; id: number; who: "user" | "agent"; text: string }
    | {
        kind: "chip";
        id: number;
        tool: "drop_into_composer" | "set_active_agent";
        args: Record<string, unknown>;
        status: "open" | "accepted";
      }
    | {
        kind: "tool";
        id: number;
        callId: string;
        /** The terminal command Workhorse is running (the `bash`
         *  tool's `command` arg). Shown verbatim so the user can
         *  read exactly what was executed. */
        command: string;
        status: "running" | "ok" | "error";
        /** Tool output once the exec returns. exit=<n> head; full
         *  output rendered when the user expands the tool block. */
        output: string | null;
      };
  let voiceMode = $state(false);
  let bubbles = $state<Bubble[]>([]);
  let bubbleSeq = 0;
  let transcriptEl: HTMLDivElement | null = $state(null);
  let voiceError = $state<string | null>(null);
  /** Per-tool-call expand state — tap a tool block to toggle the
   *  full output drawer. Keyed by the Gemini Live call id. */
  let toolExpanded = $state<Record<string, boolean>>({});

  function pushTool(callId: string, command: string) {
    bubbles = [
      ...bubbles,
      {
        kind: "tool",
        id: ++bubbleSeq,
        callId,
        command,
        status: "running",
        output: null,
      },
    ];
  }

  function completeTool(callId: string, output: string) {
    bubbles = bubbles.map((b) => {
      if (b.kind !== "tool" || b.callId !== callId) return b;
      const status: "ok" | "error" = output.startsWith("exit=0") ? "ok" : "error";
      return { ...b, status, output };
    });
  }

  /** Chip tools the brainstorming agent can call (drop a composer
   *  prompt; switch the active agent). `start_wizard` deliberately
   *  absent — wizards don't open wizards (wb-nlts). */
  const VOICE_CHIP_TOOLS: ExtraFunctionDecl[] = [
    {
      name: "drop_into_composer",
      description:
        "Propose text the user can drop into the chat composer. Use when the conversation has converged on a specific actionable task. Keep text 1–4 sentences, declarative, ready to send.",
      parameters: {
        type: "object",
        properties: {
          text: {
            type: "string",
            description:
              "The proposed composer text — a concrete prompt the user could send next.",
          },
        },
        required: ["text"],
      },
    },
    {
      name: "set_active_agent",
      description:
        "Propose switching the host's active agent to a different slug from the catalog. Use when the user's described work fits a specialist agent better than the current Workhorse.",
      parameters: {
        type: "object",
        properties: {
          slug: {
            type: "string",
            description: "Slug of the agent to switch to (kebab-case).",
          },
        },
        required: ["slug"],
      },
    },
  ];

  function appendChunk(who: "user" | "agent", chunk: string) {
    const last = bubbles[bubbles.length - 1];
    if (last && last.kind === "msg" && last.who === who) {
      bubbles = [
        ...bubbles.slice(0, -1),
        { ...last, text: last.text + chunk },
      ];
    } else {
      bubbles = [
        ...bubbles,
        { kind: "msg", id: ++bubbleSeq, who, text: chunk },
      ];
    }
  }

  function pushChip(
    tool: "drop_into_composer" | "set_active_agent",
    args: Record<string, unknown>,
  ) {
    bubbles = [
      ...bubbles,
      { kind: "chip", id: ++bubbleSeq, tool, args, status: "open" },
    ];
  }

  function acceptChip(chip: Extract<Bubble, { kind: "chip" }>) {
    if (chip.status !== "open") return;
    if (chip.tool === "drop_into_composer") {
      const text = typeof chip.args.text === "string" ? chip.args.text : "";
      if (text) {
        priorPrompt = prompt;
        prompt = text;
        queueMicrotask(() => textareaEl?.focus());
      }
    } else if (chip.tool === "set_active_agent") {
      const slug = typeof chip.args.slug === "string" ? chip.args.slug : "";
      if (slug) agents?.select(slug);
    }
    bubbles = bubbles.map((b) =>
      b.kind === "chip" && b.id === chip.id ? { ...b, status: "accepted" } : b,
    );
  }

  async function startVoice() {
    if (voiceMode || geminiLive.present) return;
    voiceMode = true;
    bubbles = [];
    voiceError = null;
    const workdir = packageStore.active?.folders?.[0] ?? null;
    await geminiLive.start(
      "workhorse",
      workdir,
      {
        onUserTranscript: (t) => appendChunk("user", t),
        onAgentTranscript: (t) => appendChunk("agent", t),
        onChip: (_id, name, args) => {
          if (name === "drop_into_composer" || name === "set_active_agent") {
            pushChip(name, args);
          }
        },
        onToolCallStart: (id, command) => pushTool(id, command),
        onToolCallEnd: (id, output) => completeTool(id, output),
        onError: (msg) => {
          voiceError = msg;
        },
        onClose: () => {
          voiceMode = false;
        },
      },
      {
        skills: ["brainstorming"],
        extraTools: VOICE_CHIP_TOOLS,
      },
    );
  }

  async function endVoice() {
    await geminiLive.end();
    voiceMode = false;
  }

  // Auto-scroll transcript as new chunks arrive.
  $effect(() => {
    void bubbles.length;
    if (transcriptEl) {
      queueMicrotask(() => {
        transcriptEl!.scrollTop = transcriptEl!.scrollHeight;
      });
    }
  });

  onDestroy(() => {
    if (geminiLive.present) void geminiLive.end();
  });

  // ── AI palette (wb-5hc0.2/.3/.4) ──
  let paletteOpen = $state(false);
  // wb-dj5r — when non-null, the palette opens in wizard mode instead
  // of the ask/enhance Q→A flow. All wizards run through this path
  // now; chips on this surface set the mode and open the palette.
  let paletteWizardMode = $state<{ id: string; title: string } | null>(null);
  // Undo chip state (wb-5hc0.5). When the palette writes to the
  // composer, stash the prior text here so the user can revert.
  // Lifetime: until the user edits the composer themselves OR sends
  // OR opens the palette again. Any of those flips priorPrompt to
  // null and hides the chip.
  let priorPrompt = $state<string | null>(null);

  function openPalette() {
    // Opening the palette invalidates a pending undo — the user is
    // moving past the prior rewrite by initiating a new one.
    priorPrompt = null;
    paletteWizardMode = null;
    paletteOpen = true;
  }

  function openWizardInPalette(id: string, title: string) {
    priorPrompt = null;
    paletteWizardMode = { id, title };
    paletteOpen = true;
  }

  function closePalette() {
    paletteOpen = false;
    paletteWizardMode = null;
  }

  function onPaletteWrite(text: string) {
    priorPrompt = prompt;
    prompt = text;
    queueMicrotask(() => textareaEl?.focus());
  }

  function undoPaletteWrite() {
    if (priorPrompt === null) return;
    prompt = priorPrompt;
    priorPrompt = null;
    queueMicrotask(() => textareaEl?.focus());
  }

  // Edits to the composer dismiss the undo chip — user has signaled
  // they intend to keep the rewrite.
  function onPromptInput() {
    if (priorPrompt !== null) priorPrompt = null;
  }

  // Global ⌘/ shortcut — opens the palette from anywhere on the
  // start surface, peer affordance to clicking the chip.
  function onWindowKey(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "/") {
      e.preventDefault();
      openPalette();
    }
  }

  onMount(() => {
    chatSession.init();
    // Know whether a model key exists so the composer can prompt to wake Waldo
    // instead of silently no-opping (wb-2s09.3/.4). Best-effort; offline → empty.
    void keys.init().catch(() => {});
    // agents.init() fires from the gated $effect above (flag-on only).
    // Wait a tick so the textarea is mounted, then focus.
    queueMicrotask(() => textareaEl?.focus());
  });

  // Waldo's text brain runs on OpenRouter. Ready runtime + no model key = the
  // composer would silently fail; surface a "wake Waldo" CTA instead.
  const hasModelKey = $derived(keys.keys.some((k) => k.provider === "openrouter"));
  const needsKey = $derived(sidecar.status.state === "ready" && !hasModelKey);

  const canSend = $derived(
    !sending && prompt.trim().length > 0 && sidecar.status.state === "ready" && hasModelKey,
  );

  async function submit() {
    const t = prompt.trim();
    if (!t || sending) return;
    if (sidecar.status.state !== "ready") {
      error = "Agent isn't ready yet.";
      return;
    }
    sending = true;
    error = null;
    // Sending = the user is keeping the (possibly palette-enhanced)
    // prompt. Drop the undo chip.
    priorPrompt = null;
    try {
      // Open the agent dock panel so the user sees the thread (wb-aakl.14).
      if (features.agents) dock.open("agent");
      await chatSession.send(t);
      prompt = "";
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      sending = false;
    }
  }

  function onKey(e: KeyboardEvent) {
    // ⌘↵ / Ctrl↵ submits.
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void submit();
    }
  }

  function newPackage(e: MouseEvent) {
    const wsActive = workspaces.active;
    if (!wsActive) return;
    const target = e.currentTarget;
    if (!(target instanceof HTMLElement)) return;
    createPackage.openMenu(target.getBoundingClientRect());
  }


</script>

<svelte:window onkeydown={onWindowKey} />

<div class="home">
  <div class="hero">
    {#if !voiceMode}
      <form
        class="composer"
        onsubmit={(e) => { e.preventDefault(); submit(); }}
        in:fade={{ duration: 180 }}
      >
        <textarea
          bind:this={textareaEl}
          bind:value={prompt}
          onkeydown={onKey}
          oninput={onPromptInput}
          placeholder="What would you like to do?"
          rows="3"
          spellcheck="false"
          disabled={sending}
        ></textarea>
        <div class="composer-foot">
          <div class="foot-left">
            {#if features.agents && AgentPickerDropdown}
              <AgentPickerDropdown oncreate={() => { /* TBD */ }} />
            {/if}
          </div>
          <span class="hint">
            {#if sidecar.status.state !== "ready"}
              <span class="muted">{sidecar.status.state}</span>
            {:else if needsKey}
              <button type="button" class="wake-cta" onclick={() => chrome.navigateTo("settings", "general")}>
                Add a model key to wake Waldo →
              </button>
            {:else}
              <span class="muted">⌘↵</span>
            {/if}
          </span>
          <button
            type="button"
            class="btn voice-toggle"
            onclick={startVoice}
            disabled={sidecar.status.state !== "ready"}
            title="Talk to Workhorse by voice"
            aria-label="Start voice session"
          >
            <AudioLines weight="fill" size={13} />
          </button>
          <button
            type="submit"
            class="btn primary"
            disabled={!canSend}
          >
            {sending ? "…" : ""}
            <ArrowUp weight="fill" size={16} color="var(--color-page)" />
          </button>
        </div>
      </form>
    {:else}
      <!-- Voice mode: the composer morphs into a status strip + the
           quick-chip row below morphs into a transcript pane. Same
           position, same visual anchor — no layout jump. -->
      <div
        class="voice-shell"
        class:errored={geminiLive.state === "error"}
        in:fade={{ duration: 240 }}
      >
        <div class="voice-strip">
          <span class="leading" aria-hidden="true">
            <span class="voice-dot" class:muted={geminiLive.muted}></span>
          </span>
          <span class="voice-status">
            {#if geminiLive.state === "connecting"}
              Connecting…
            {:else if geminiLive.state === "live"}
              {geminiLive.muted ? "Muted" : "Listening"}
            {:else if geminiLive.state === "paused"}
              Paused
            {:else if geminiLive.state === "error"}
              {geminiLive.error ?? "Voice session error"}
            {:else}
              Workhorse
            {/if}
          </span>
          <div class="voice-trailing">
            <button
              type="button"
              class="voice-btn"
              onclick={() => geminiLive.toggleMute()}
              disabled={geminiLive.state !== "live"}
              title={geminiLive.muted ? "Unmute" : "Mute"}
              aria-label={geminiLive.muted ? "Unmute" : "Mute"}
            >
              {#if geminiLive.muted}
                <MicOff weight="fill" size={14} />
              {:else}
                <Mic weight="fill" size={14} />
              {/if}
            </button>
            <button
              type="button"
              class="voice-btn end"
              onclick={endVoice}
              title="End session"
              aria-label="End voice session"
            >
              <PhoneOff weight="fill" size={14} />
            </button>
          </div>
        </div>
      </div>
    {/if}

    {#if error}<div class="err">{error}</div>{/if}

    {#if priorPrompt !== null && !voiceMode}
      <button
        type="button"
        class="undo-chip"
        onclick={undoPaletteWrite}
        title="Revert to your previous prompt"
        aria-label="Undo palette rewrite"
      >
        <Undo2 weight="bold" size={11} aria-hidden="true" />
        <span>Undo</span>
      </button>
    {/if}

    {#if voiceMode}
      <div
        class="voice-transcript"
        bind:this={transcriptEl}
        in:fly={{ y: 8, duration: 220 }}
      >
        {#if bubbles.length === 0 && geminiLive.state !== "error"}
          <div class="voice-empty">
            <span class="dots" aria-hidden="true">
              <span></span><span></span><span></span>
            </span>
            <span class="muted">
              {geminiLive.state === "connecting"
                ? "Opening mic…"
                : "Workhorse is about to speak."}
            </span>
          </div>
        {/if}
        {#each bubbles as b (b.id)}
          {#if b.kind === "msg"}
            <div class="bubble" class:agent={b.who === "agent"}>
              <span class="who">{b.who === "agent" ? "Workhorse" : "You"}</span>
              <span class="text">{b.text}</span>
            </div>
          {:else if b.kind === "tool"}
            <button
              type="button"
              class="tool-block"
              class:running={b.status === "running"}
              class:done={b.status === "ok"}
              class:errored={b.status === "error"}
              onclick={() => (toolExpanded[b.callId] = !toolExpanded[b.callId])}
            >
              <span class="tool-head">
                <Wrench weight="fill" size={11} aria-hidden="true" />
                <span class="tool-name">terminal</span>
                {#if b.status === "running"}
                  <Loader2 weight="bold" size={11} aria-hidden="true" class="spin" />
                {:else if b.status === "ok"}
                  <Check weight="bold" size={11} aria-hidden="true" />
                {:else}
                  <XCircle weight="fill" size={11} aria-hidden="true" />
                {/if}
              </span>
              <code class="tool-cmd">{b.command}</code>
              {#if toolExpanded[b.callId] && b.output}
                <pre class="tool-output">{b.output}</pre>
              {/if}
            </button>
          {:else}
            <button
              type="button"
              class="voice-chip"
              class:accepted={b.status === "accepted"}
              disabled={b.status !== "open"}
              onclick={() => acceptChip(b)}
            >
              <span class="voice-chip-label">
                {#if b.tool === "drop_into_composer"}
                  Drop into composer
                {:else}
                  Switch to @{String(b.args.slug ?? "")}
                {/if}
              </span>
              {#if b.tool === "drop_into_composer" && typeof b.args.text === "string"}
                <span class="voice-chip-detail">{b.args.text}</span>
              {/if}
              {#if b.status === "accepted"}
                <span class="voice-chip-check">✓</span>
              {/if}
            </button>
          {/if}
        {/each}
        {#if voiceError}
          <div class="voice-err">
            <AlertCircle weight="fill" size={12} />
            <span>{voiceError}</span>
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<PaletteModal
  open={paletteOpen}
  composerText={prompt}
  workdir={packageStore.active?.folders?.[0] ?? null}
  wizardMode={paletteWizardMode}
  onclose={closePalette}
  onwrite={onPaletteWrite}
/>

<style>
  .home {
    flex: 1 1 auto;
    overflow: auto;
    /* No surface of its own — the create page shows the graph-paper shader
     * backdrop, with the composer + chips floating on top. */
    background: transparent;
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 4rem 2rem 8rem;
  }
  .hero {
    width: 100%;
    max-width: 640px;
    display: flex;
    flex-direction: column;
    align-items: stretch;
  }

  /* The AI palette chip — minimalist, inviting, NOT a button that
   * looks like an action. Visually a soft pill that says "you can
   * ask me about this workspace." Disabled state for now (wb-5hc0.2
   * wires the modal). */
  .palette-chip {
    align-self: center;
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.45rem 0.85rem;
    margin-bottom: 1rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.78rem;
    cursor: pointer;
    transition: background 0.15s, color 0.15s, border-color 0.15s;
  }
  .palette-chip:hover:not(:disabled) {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .palette-chip:disabled {
    cursor: default;
    opacity: 0.55;
  }
  .palette-chip kbd {
    font-family: var(--font-mono);
    font-size: 0.68rem;
    padding: 0.1rem 0.35rem;
    border: 1px solid var(--color-border);
    border-radius: 4px;
    background: var(--color-surface);
    color: var(--color-fg-subtle);
  }

  .composer {
    width: 100%;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    padding: 0.85rem 0.85rem 0.55rem;
    display: flex;
    flex-direction: column;
    gap: 0.55rem;
    box-shadow: var(--shadow-pop);
  }
  .composer:focus-within { border-color: var(--color-border-strong); }
  .composer textarea {
    width: 100%;
    background: transparent;
    border: 0;
    outline: 0;
    font-family: inherit;
    font-size: 1rem;
    color: var(--color-fg);
    resize: none;
    line-height: 1.5;
    min-height: 84px;
  }
  .composer textarea::placeholder { color: var(--color-fg-subtle); }
  .composer-foot {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .foot-left { flex: 1 1 auto; min-width: 0; }
  .hint {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-subtle);
  }
  .muted { color: var(--color-fg-muted); }
  /* Missing-key prompt — a quiet inline CTA that jumps to settings so the user
     can wake Waldo instead of hitting a dead send button (wb-2s09.3/.4). */
  .wake-cta {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-brand);
    background: none;
    border: 0;
    padding: 0;
    cursor: pointer;
    white-space: nowrap;
  }
  .wake-cta:hover { text-decoration: underline; }

  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.35rem;
    width: 32px;
    height: 32px;
    border-radius: 8px;
    font-size: 0.85rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 0;
    transition: opacity 0.15s, filter 0.15s, background 0.15s, color 0.15s;
  }
  .btn:disabled { opacity: 0.35; cursor: default; }
  /* Send: monochrome — fg fill with a page-colored glyph. Inverts cleanly in
     both themes (white button/dark glyph in dark mode, and vice-versa). */
  .btn.primary { background: var(--color-fg); color: var(--color-page); }
  .btn.primary :global(svg) { color: var(--color-page); fill: currentColor; }
  .btn.primary:not(:disabled):hover { filter: brightness(1.08); }

  .err {
    margin-top: 0.6rem;
    color: var(--color-err);
    font-size: 0.8rem;
    text-align: center;
  }

  /* Undo chip — appears between the composer and the quick-action
   * chips when the palette has written to the composer. Soft,
   * non-shouty; it's an "if you didn't want this" affordance, not
   * a primary action. Lifetime is bounded by HomePanel.svelte's
   * priorPrompt state (cleared on edit / send / next-palette-open). */
  .undo-chip {
    align-self: flex-end;
    margin-top: 0.55rem;
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.25rem 0.55rem;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.72rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .undo-chip:hover {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }

  .quick {
    margin-top: 1rem;
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
    justify-content: center;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 26px;
    padding: 0 0.65rem;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    background: transparent;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s;
  }
  .chip:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .chip:disabled { opacity: 0.5; cursor: default; }

  /* Tighten the AgentPickerDropdown when embedded in the composer
   * footer (override its default chip styling so it doesn't look
   * like a primary action). The selector reaches into the rendered
   * child via :global. */
  .foot-left :global(.agent-picker) {
    font-size: 0.74rem;
    padding: 0.2rem 0.5rem !important;
    background: transparent !important;
    border-color: transparent !important;
    color: var(--color-fg-muted) !important;
  }
  .foot-left :global(.agent-picker:hover) {
    background: var(--color-surface-soft) !important;
    border-color: var(--color-border) !important;
    color: var(--color-fg) !important;
  }

  /* ── Voice mode (wb-nlts) ──
   *
   * The voice strip takes the composer's place when voiceMode is on,
   * with the same shell dimensions so the page doesn't reflow. Border
   * is the aurora gradient flowing slowly — same visual language as
   * the global LiveBar but scoped to the home composer. */
  .voice-toggle {
    /* Sits next to the send button in text mode. Subtle until live. */
    padding: 0 0.55rem;
    background: transparent;
    color: var(--color-fg-muted);
  }
  .voice-toggle:not(:disabled):hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  .voice-shell {
    display: flex;
    flex-direction: column;
    border: 1.5px solid transparent;
    border-radius: 10px;
    background:
      linear-gradient(var(--color-surface), var(--color-surface)) padding-box,
      linear-gradient(
        90deg,
        var(--gradient-aurora-a),
        var(--gradient-aurora-b),
        var(--gradient-aurora-c),
        var(--gradient-aurora-d),
        var(--gradient-aurora-a)
      ) border-box;
    background-size: 100% 100%, 200% 100%;
    animation: voice-aurora-flow 12s linear infinite;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
  }
  @keyframes voice-aurora-flow {
    from { background-position: 0% 0%, 0% 0%; }
    to   { background-position: 0% 0%, 200% 0%; }
  }
  @media (prefers-reduced-motion: reduce) {
    .voice-shell { animation: none; }
  }
  .voice-shell.errored {
    border: 1.5px solid color-mix(in srgb, var(--color-err) 50%, var(--color-border-strong));
    background: var(--color-surface);
    animation: none;
  }

  .voice-strip {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    padding: 0.65rem 0.7rem 0.65rem 0.95rem;
  }
  .voice-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--color-brand);
    box-shadow: 0 0 0 0 var(--color-ring);
    animation: voice-dot-pulse 1.6s ease-out infinite;
  }
  .voice-dot.muted {
    background: var(--color-warn);
    box-shadow: none;
    animation: none;
  }
  @keyframes voice-dot-pulse {
    0%   { box-shadow: 0 0 0 0 var(--color-ring); }
    70%  { box-shadow: 0 0 0 5px transparent; }
    100% { box-shadow: 0 0 0 0 transparent; }
  }
  .voice-status {
    flex: 1 1 auto;
    color: var(--color-fg);
    font-size: 0.92rem;
    line-height: 1.4;
  }
  .voice-trailing {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
  }
  .voice-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 7px;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, opacity 0.1s;
  }
  .voice-btn:not(:disabled):hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .voice-btn:disabled { opacity: 0.35; cursor: default; }
  .voice-btn.end {
    background: color-mix(in srgb, var(--color-err) 14%, var(--color-surface));
    color: var(--color-err);
  }
  .voice-btn.end:hover {
    background: color-mix(in srgb, var(--color-err) 22%, var(--color-surface));
  }

  .voice-transcript {
    display: flex;
    flex-direction: column;
    gap: 0.55rem;
    margin-top: 0.6rem;
    padding: 0.55rem 0;
    max-height: 40vh;
    overflow-y: auto;
  }
  .voice-empty {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.4rem 0;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
  .dots {
    display: inline-flex;
    align-items: center;
    gap: 3px;
  }
  .dots span {
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: var(--color-fg-muted);
    animation: voice-dot 1.1s ease-in-out infinite;
  }
  .dots span:nth-child(2) { animation-delay: 0.18s; }
  .dots span:nth-child(3) { animation-delay: 0.36s; }
  @keyframes voice-dot {
    0%, 80%, 100% { opacity: 0.25; transform: translateY(0); }
    40% { opacity: 1; transform: translateY(-2px); }
  }
  .muted {
    color: var(--color-fg-muted);
  }

  .bubble {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }
  .bubble .who {
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .bubble.agent .who { color: var(--color-fg-muted); }
  .bubble .text {
    color: var(--color-fg);
    line-height: 1.55;
    white-space: pre-wrap;
    font-size: 0.92rem;
  }

  .voice-chip {
    display: inline-flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.2rem;
    padding: 0.55rem 0.75rem;
    border: 1px solid var(--color-border-strong);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    border-radius: 9px;
    cursor: pointer;
    text-align: left;
    font: inherit;
    transition: background 0.1s, border-color 0.1s, opacity 0.12s;
    max-width: 100%;
    position: relative;
    align-self: flex-start;
  }
  .voice-chip:hover:not(:disabled) {
    background: var(--color-surface);
    border-color: var(--color-fg-muted);
  }
  .voice-chip:disabled { cursor: default; }
  .voice-chip.accepted {
    opacity: 0.65;
    border-color: var(--color-border);
  }
  .voice-chip-label {
    font-size: 0.82rem;
    font-weight: 600;
  }
  .voice-chip-detail {
    font-size: 0.82rem;
    color: var(--color-fg-muted);
    line-height: 1.45;
    white-space: pre-wrap;
  }
  .voice-chip-check {
    position: absolute;
    top: 0.4rem;
    right: 0.55rem;
    font-size: 0.78rem;
    color: var(--color-ok);
    font-weight: 700;
  }

  .voice-err {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.4rem 0.55rem;
    font-size: 0.82rem;
    color: var(--color-err);
    background: color-mix(in srgb, var(--color-err) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--color-err) 30%, var(--color-border));
    border-radius: 7px;
  }

  /* Tool-call block — each terminal command Workhorse runs gets a
   * card with status icon. Tap to expand the full output. */
  .tool-block {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 0.35rem;
    padding: 0.5rem 0.7rem;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    border-radius: 8px;
    cursor: pointer;
    text-align: left;
    font: inherit;
    transition: background 0.1s, border-color 0.1s;
    align-self: flex-start;
    max-width: 100%;
  }
  .tool-block:hover {
    background: var(--color-surface);
    border-color: var(--color-fg-muted);
  }
  .tool-block.running {
    border-color: color-mix(in srgb, var(--color-warn) 50%, var(--color-border-strong));
  }
  .tool-block.done {
    border-color: color-mix(in srgb, var(--color-ok) 35%, var(--color-border-strong));
  }
  .tool-block.errored {
    border-color: color-mix(in srgb, var(--color-err) 50%, var(--color-border-strong));
    background: color-mix(in srgb, var(--color-err) 5%, var(--color-surface-soft));
  }
  .tool-head {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .tool-block.done .tool-head { color: var(--color-ok); }
  .tool-block.errored .tool-head { color: var(--color-err); }
  .tool-name { color: inherit; }
  :global(.tool-head .spin) {
    animation: tool-spin 1s linear infinite;
  }
  @keyframes tool-spin {
    to { transform: rotate(360deg); }
  }
  .tool-cmd {
    font-family: var(--font-mono);
    font-size: 0.8rem;
    color: var(--color-fg);
    background: transparent;
    white-space: pre-wrap;
    word-break: break-all;
    line-height: 1.45;
  }
  .tool-output {
    margin: 0.4rem 0 0;
    padding: 0.55rem 0.7rem;
    background: var(--color-page);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    font-family: var(--font-mono);
    font-size: 0.74rem;
    color: var(--color-fg-muted);
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 240px;
    overflow-y: auto;
  }
</style>
