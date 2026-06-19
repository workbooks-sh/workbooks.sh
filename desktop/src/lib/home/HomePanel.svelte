<script lang="ts">
  /**
   * HomePanel — the create surface AND the foreground text-chat thread.
   *
   * Conceptual model: this is where you land when you want to start
   * something. The visual anchor is the composer, centered on empty calm.
   *
   * Sending from the composer turns the PAGE itself into the conversation
   * (demo TASK 2): the composer animates to the bottom, the thread renders
   * in the main area, and the agent's reply streams in-session. Text chat
   * does NOT open the Waldo side panel — the page IS the thread.
   *
   * Voice (demo TASK 3) is reached from the composer's "+" menu (a Waveform
   * entry). Starting voice opens the Waldo dock panel on the right — voice
   * lives in the panel, not on this page.
   */
  import { onMount } from "svelte";
  import { fade, fly } from "svelte/transition";
  import { ArrowUp, ArrowUUpLeft as Undo2, Waveform, Plus, ChatCircle } from "phosphor-svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import { keys } from "$lib/bridge/keys.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import PaletteModal from "$lib/palette/PaletteModal.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { features } from "$lib/bridge/features";
  import { dock } from "$lib/bridge/dock.svelte";
  import ChatThread from "$lib/chat/ChatThread.svelte";
  import { chatBackdrop } from "./chatBackdrop.svelte";
  import { onDestroy } from "svelte";
  import { openChatTab } from "$lib/tabs/chatTab";

  const WALDO_SLUG = "waldo";

  // Multi-agent chrome (the agents catalog + its picker) is gated by
  // WB_FF_AGENTS (wb-aakl.2) and lazily imported so a flags-off build
  // excludes the catalog store.
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

  let prompt = $state("");
  let textareaEl: HTMLTextAreaElement | null = $state(null);
  let threadEl: HTMLDivElement | null = $state(null);
  let sending = $state(false);
  let error = $state<string | null>(null);

  // ── Foreground conversation (demo TASK 2) ──
  //
  // The page is a thread once the user has sent at least one message. We
  // read the user's echoes + the agent blocks straight off the shared
  // chatSession store (the same store WaldoPanel uses), so opening the
  // dock panel later shows the identical conversation.
  // Home is a launcher — the conversation lives in its chat:// tab, never inline.
  const inConversation = $derived(false);

  // Invert the background vignette while the page is a thread (FIX 3):
  // clear centre behind the conversation, faint grid only at the edges.
  // GridShader (root layout) reads this singleton and eases both ways.
  $effect(() => {
    chatBackdrop.active = inConversation;
  });

  const userLines = $derived(chatSession.userEchoes);

  // "Thinking" dots between send and the first agent output.
  const thinking = $derived(
    (sending ||
      chatSession.session?.status === "pending" ||
      chatSession.session?.status === "running") &&
      !chatSession.blocks.some(
        (b) => b.kind === "message" && (b.text || b.pending),
      ),
  );

  // Auto-scroll the thread to the newest line.
  $effect(() => {
    void chatSession.blocks.length;
    void userLines.length;
    void thinking;
    if (threadEl) {
      queueMicrotask(() => { threadEl!.scrollTop = threadEl!.scrollHeight; });
    }
  });

  // ── "+" create/voice menu ──
  let menuOpen = $state(false);
  function toggleMenu() { menuOpen = !menuOpen; }
  function closeMenu() { menuOpen = false; }

  async function startVoiceFromMenu() {
    closeMenu();
    if (sidecar.status.state !== "ready") return;
    // Voice lives in the Waldo panel — open it on the right, then start the
    // session wired to the shared store the panel renders.
    dock.open("waldo");
    try {
      await chatSession.startVoice();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  // ── AI palette (wb-5hc0.2/.3/.4) ──
  let paletteOpen = $state(false);
  let paletteWizardMode = $state<{ id: string; title: string } | null>(null);
  let priorPrompt = $state<string | null>(null);

  function openPalette() {
    priorPrompt = null;
    paletteWizardMode = null;
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
  function onPromptInput() {
    if (priorPrompt !== null) priorPrompt = null;
  }

  // Global ⌘/ shortcut — opens the palette from anywhere on the start surface.
  function onWindowKey(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "/") {
      e.preventDefault();
      openPalette();
    }
  }

  // Close the work-intent loop. A <work-gen-block> button/share fires a
  // `work-intent` CustomEvent (bubbles + composed, so it reaches window even
  // from inside the element's shadow root). Two dispositions:
  //   • `open` (carries a target path) → open the workbook chat-left /
  //     workbook-right deterministically — no round-trip needed (FIX 2, the
  //     same split `work app open-tab` drives).
  //   • everything else (e.g. a button :action, a share invite) → forward
  //     `{action, detail}` back into the SESSION as a follow-up user turn, so
  //     the agent re-enters the loop on a button press (was a dead-end before).
  function describeIntent(d: Record<string, unknown>): string {
    const action = String(d.action ?? "button");
    if (action === "share") {
      const members = Array.isArray(d.members) ? (d.members as string[]).join(", ") : "";
      const role = d.role ? ` as ${d.role}` : "";
      const target = d.target ? ` to ${d.target}` : "";
      return `Send the invite${target}${members ? ` for ${members}` : ""}${role}.`;
    }
    const label = d.label ? ` "${d.label}"` : "";
    const target = d.target ? ` (${d.target})` : "";
    return `I clicked the${label} action${target}. Please continue.`;
  }

  async function onWorkIntent(e: Event) {
    const detail = (e as CustomEvent).detail as
      | { action?: string; target?: string; [k: string]: unknown }
      | null;
    if (!detail) return;
    if (detail.action === "open") {
      const target = (detail.target ?? "").trim();
      if (!target) return;
      void import("$lib/tabs/agentOpen").then((m) => m.openFromAgent(target));
      return;
    }
    // Re-enter the agent loop: echo a follow-up turn and send it, mirroring
    // submit() (the composer's own send path).
    if (sending || sidecar.status.state !== "ready") return;
    const followUp = describeIntent(detail);
    sending = true;
    chatSession.pushEcho(followUp);
    try {
      await chatSession.send(followUp, { agentSlug: WALDO_SLUG });
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      sending = false;
    }
  }

  onMount(() => {
    chatSession.init();
    void keys.init().catch(() => {});
    window.addEventListener("work-intent", onWorkIntent);
    queueMicrotask(() => textareaEl?.focus());
  });
  onDestroy(() => {
    window.removeEventListener("work-intent", onWorkIntent);
    // Leaving the create surface must not strand the inverted backdrop.
    chatBackdrop.active = false;
  });

  // Waldo's text brain runs on OpenRouter. Ready runtime + no model key = the
  // composer would silently fail; surface a "wake Waldo" CTA instead.
  const hasModelKey = $derived(keys.keys.some((k) => k.provider === "openrouter"));
  const needsKey = $derived(sidecar.status.state === "ready" && !hasModelKey);
  const ready = $derived(sidecar.status.state === "ready");

  const canSend = $derived(
    !sending && prompt.trim().length > 0 && ready && hasModelKey,
  );

  async function submit() {
    const t = prompt.trim();
    if (!t || sending) return;
    if (!ready) {
      error = "Agent isn't ready yet.";
      return;
    }
    sending = true;
    error = null;
    priorPrompt = null;
    // The home composer is a LAUNCHER: the first message opens a returnable chat
    // tab bound to the live session (the tab + this page share the chatSession
    // singleton), and the composer stays a fresh launcher. (Same pattern as
    // WaldoPanel.) Revisit past chats from the chat tab's "Chats" view.
    const firstMessage = chatSession.userEchoes.length === 0;
    chatSession.pushEcho(t);
    prompt = "";
    if (firstMessage) void openChatTab(WALDO_SLUG);
    try {
      await chatSession.send(t, { agentSlug: WALDO_SLUG });
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      sending = false;
    }
  }

  function newChat() {
    chatSession.clearTranscript();
    error = null;
    queueMicrotask(() => textareaEl?.focus());
  }

  function onKey(e: KeyboardEvent) {
    // ⌘↵ / Ctrl↵ submits.
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      void submit();
    }
  }
</script>

<svelte:window onkeydown={onWindowKey} />

<div class="home" class:conversing={inConversation}>
  {#if inConversation}
    <!-- The page IS the thread (TASK 2). Composer is pinned to the bottom. -->
    <div class="thread" bind:this={threadEl}>
      <div class="thread-inner">
        <ChatThread userLines={userLines} blocks={chatSession.blocks} {thinking} />
      </div>
    </div>
  {/if}

  <div class="hero" class:docked={inConversation}>
    {#if inConversation}
      <button type="button" class="new-chat" onclick={newChat} transition:fade={{ duration: 140 }}>
        <ChatCircle weight="fill" size={13} /> New chat
      </button>
    {/if}

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
        rows={inConversation ? 1 : 3}
        spellcheck="false"
        disabled={sending}
      ></textarea>
      <div class="composer-foot">
        <div class="foot-left">
          <div class="plus-wrap">
            <button
              type="button"
              class="btn plus-btn"
              onclick={toggleMenu}
              title="Create or talk by voice"
              aria-label="Open create menu"
              aria-expanded={menuOpen}
            >
              <Plus weight="bold" size={15} />
            </button>
            {#if menuOpen}
              <div class="plus-menu" transition:fly={{ y: 6, duration: 140 }}>
                <button
                  type="button"
                  class="plus-item"
                  onclick={startVoiceFromMenu}
                  disabled={!ready}
                >
                  <Waveform weight="fill" size={15} />
                  <span>Talk by voice</span>
                </button>
              </div>
              <!-- click-away -->
              <button type="button" class="plus-scrim" aria-hidden="true" tabindex="-1" onclick={closeMenu}></button>
            {/if}
          </div>
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
        <button type="submit" class="btn primary" disabled={!canSend}>
          {#if sending}…{:else}<ArrowUp weight="fill" size={16} />{/if}
        </button>
      </div>
    </form>

    {#if error}<div class="err">{error}</div>{/if}

    {#if priorPrompt !== null}
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
    overflow: hidden;
    background: transparent;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    padding: 4rem 2rem 8rem;
    transition: padding 0.25s ease;
  }
  /* Conversation mode: thread fills the canvas, composer pins to the bottom. */
  .home.conversing {
    justify-content: flex-end;
    padding: 0;
  }

  .hero {
    width: 100%;
    max-width: 640px;
    display: flex;
    flex-direction: column;
    align-items: stretch;
  }
  /* Docked composer: anchored to the bottom of the canvas, full-width band. */
  .hero.docked {
    position: relative;
    max-width: 760px;
    margin-inline: auto;
    padding: 0.75rem 1rem 1.25rem;
    flex: 0 0 auto;
  }

  /* ── thread (foreground text chat) ── */
  .thread {
    flex: 1 1 auto;
    width: 100%;
    min-height: 0;
    overflow-y: auto;
    display: flex;
    justify-content: center;
  }
  .thread-inner {
    width: 100%;
    max-width: 760px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 1.5rem 1rem 1rem;
  }
  /* ── new-chat chip ── */
  .new-chat {
    align-self: center;
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    margin-bottom: 0.5rem;
    padding: 0.25rem 0.6rem;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    background: var(--color-surface);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.72rem;
    cursor: pointer;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .new-chat:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
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
    min-height: 32px;
  }
  .conversing .composer textarea { min-height: 32px; }
  .home:not(.conversing) .composer textarea { min-height: 84px; }
  .composer textarea::placeholder { color: var(--color-fg-subtle); }
  .composer-foot {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .foot-left {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 0.35rem;
  }
  .hint {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-subtle);
  }
  .muted { color: var(--color-fg-muted); }
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
  .btn :global(svg) { flex: none; }
  .btn.primary { background: var(--color-fg); isolation: isolate; }
  .btn.primary :global(svg) { color: #fff; fill: currentColor; mix-blend-mode: difference; }
  .btn.primary:not(:disabled):hover { filter: brightness(1.08); }

  /* "+" create/voice menu */
  .plus-wrap { position: relative; display: inline-flex; }
  .plus-btn {
    width: 30px;
    height: 30px;
    background: transparent;
    color: var(--color-fg-muted);
  }
  .plus-btn:hover {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .plus-menu {
    position: absolute;
    bottom: calc(100% + 6px);
    left: 0;
    z-index: 20;
    min-width: 168px;
    padding: 4px;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    background: var(--color-surface);
    box-shadow: var(--shadow-pop);
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .plus-item {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 0.45rem 0.55rem;
    border: 0;
    border-radius: 7px;
    background: transparent;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    cursor: pointer;
    text-align: left;
    transition: background 0.1s, color 0.1s;
  }
  .plus-item:hover:not(:disabled) { background: var(--color-surface-soft); }
  .plus-item:disabled { opacity: 0.4; cursor: default; }
  .plus-item :global(svg) { color: var(--color-brand, #3fe081); flex: none; }
  .plus-scrim {
    position: fixed;
    inset: 0;
    z-index: 10;
    background: transparent;
    border: 0;
    cursor: default;
  }

  .err {
    margin-top: 0.6rem;
    color: var(--color-err);
    font-size: 0.8rem;
    text-align: center;
  }

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

  /* Tighten the AgentPickerDropdown when embedded in the composer footer. */
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
</style>
