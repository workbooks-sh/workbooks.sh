<script lang="ts">
  /**
   * WaldoPanel (wb-aakl.21) — the browser's ONE resident agent.
   *
   * Not the multi-agent chat chrome (that stays flagged off); a single
   * voice you summon to set up and work the system. Salvages the existing
   * chatSession transport (text via OpenRouter) + geminiLive (voice). Talks
   * to the "waldo" agent slug — the autopoet (wb-9ae) surfaced in the
   * browser. The runtime agent definition + autopoet file_issue seam + the
   * MCP waldo_ask/do bridge are tracked in wb-aakl.25 (runtime/Rust work).
   *
   * Pitch guard: a communicator you summon, never a self-running manager.
   */
  import { PaperPlaneRight, Sparkle } from "phosphor-svelte";
  import { chatSession } from "$lib/chat/session.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";

  const WALDO_SLUG = "waldo";

  let prompt = $state("");
  let sending = $state(false);
  // Local echo of the user's lines (chatSession.blocks holds the agent's
  // response stream; the prompt is shown here so the thread reads as a chat).
  let myLines = $state<{ text: string; ts: number }[]>([]);

  const ready = $derived(sidecar.status.state === "ready");

  // Merge user echoes + agent blocks into one time-ordered transcript.
  const transcript = $derived.by(() => {
    const mine = myLines.map((m) => ({ who: "you" as const, text: m.text, ts: m.ts, kind: "msg" }));
    const theirs = chatSession.blocks.map((b) => {
      if (b.kind === "message")
        return { who: "waldo" as const, text: b.text, ts: b.ts, kind: "msg", pending: b.pending, error: b.error };
      if (b.kind === "tool")
        return { who: "waldo" as const, text: `⚙ ${b.toolName}${b.pending ? "…" : ""}`, ts: b.ts, kind: "tool" };
      if (b.kind === "status")
        return { who: "waldo" as const, text: b.label, ts: b.ts, kind: "status", level: b.level };
      return null;
    });
    return [...mine, ...theirs.filter(Boolean)].sort((a, b) => (a!.ts ?? 0) - (b!.ts ?? 0)) as Array<{
      who: "you" | "waldo";
      text: string;
      ts: number;
      kind: string;
      pending?: boolean;
      error?: boolean;
      level?: string;
    }>;
  });

  async function send() {
    const t = prompt.trim();
    if (!t || sending || !ready) return;
    sending = true;
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
</script>

<div class="waldo">
  <div class="intro" class:hide={transcript.length > 0}>
    <div class="hero alive"><Sparkle size={22} weight="fill" /></div>
    <h2>Waldo</h2>
    <p>
      The browser's resident agent. Ask a question, search, open tabs, or have
      it debug the system with you — by text or voice. Waldo finds issues and
      works them; it never runs off on its own.
    </p>
    {#if !ready}
      <p class="hint">
        Connect a nexus (engine chip, top-right) and add an OpenRouter key or
        Gemini voice to wake Waldo.
      </p>
    {/if}
  </div>

  {#if transcript.length > 0}
    <div class="thread">
      {#each transcript as m, i (m.ts + "-" + i)}
        <div class="bubble {m.who}" class:tool={m.kind === "tool"} class:err={m.error}>
          {#if m.who === "waldo" && m.kind === "msg"}<span class="tag">Waldo</span>{/if}
          <span class="text">{m.text || (m.pending ? "…" : "")}</span>
        </div>
      {/each}
    </div>
  {/if}

  <form class="composer" onsubmit={(e) => { e.preventDefault(); void send(); }}>
    <textarea
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
</div>

<style>
  .waldo {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    background: var(--color-surface);
  }
  .intro {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.7rem;
    padding: 1.5rem;
    text-align: center;
  }
  .intro.hide { display: none; }
  .hero {
    display: grid;
    place-items: center;
    width: 48px;
    height: 48px;
    border-radius: 14px;
    background: var(--color-brand-soft);
    color: var(--color-brand);
  }
  .intro h2 {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .intro p {
    margin: 0;
    font-size: 0.82rem;
    line-height: 1.55;
    color: var(--color-fg-muted);
    max-width: 32ch;
  }
  .intro .hint {
    font-family: var(--font-mono);
    font-size: 0.72rem;
    color: var(--color-fg-subtle);
  }
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
  .bubble.you {
    align-self: flex-end;
    background: var(--color-brand);
    color: var(--color-brand-ink);
  }
  .bubble.waldo {
    align-self: flex-start;
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
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
  .composer-foot {
    display: flex;
    align-items: center;
    gap: 8px;
  }
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
  .kbd {
    margin-left: auto;
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--color-fg-subtle);
  }
  .send:disabled { opacity: 0.45; cursor: default; }
</style>
