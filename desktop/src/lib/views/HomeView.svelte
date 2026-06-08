<script lang="ts">
  /**
   * HomeView (Create) — the landing surface. You come here to start
   * something before you've decided which thing it is. The visual anchor
   * is the composer; above it an "Ask the workspace" chip opens the AI
   * palette (⌘/), and the agent picker lives in the composer foot so the
   * active agent is always visible. Below, a short row of explicit "+ X"
   * create entry points the palette can't disambiguate quickly.
   *
   * Voice mode (wb-nlts) morphs the composer in place: the textarea is
   * swapped for a status strip and the chip row becomes a live transcript
   * — same position, no layout jump. The Gemini Live transport + real
   * chat send are deferred; this is their shape, mock-seeded so the
   * surface reads true. Submit opens the right-side agent drawer so the
   * thread your prompt starts is immediately visible.
   */
  import { onMount } from "svelte";
  import {
    ArrowRight, Plus, Sparkles, BookOpen, Wand2, Kanban,
    Undo2, AudioLines, Mic, MicOff, PhoneOff, Wrench, Check,
  } from "@lucide/svelte";
  import { chrome } from "$lib/chrome.svelte";
  import { commands, type AgentCatalogEntry } from "$lib/ipc";
  import { Dropdown, type DropdownItem } from "$lib/components/ui";
  import PaletteModal from "$lib/components/PaletteModal.svelte";

  let prompt = $state("");
  let priorPrompt = $state<string | null>(null);
  let sending = $state(false);
  let error = $state<string | null>(null);
  let textareaEl = $state<HTMLTextAreaElement | null>(null);

  // ── Agent catalog + active selection (agent_settings) ──
  let agents = $state<AgentCatalogEntry[]>([]);
  let activeAgent = $state<string>("workhorse");
  const agentItems = $derived<DropdownItem[]>(
    agents.map((a) => ({ value: a.slug, label: a.title, description: a.tagline ?? undefined })),
  );

  onMount(async () => {
    try {
      agents = await commands.agentsList();
      const s = await commands.agentSettingsGet();
      activeAgent = s.defaultAgentSlug;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  });

  const canSend = $derived(prompt.trim().length > 0 && !sending);

  async function submit() {
    if (!canSend) return;
    sending = true;
    error = null;
    try {
      // TODO(chat): chatSession.send(prompt, { agent: activeAgent }).
      // Opening the agent drawer surfaces the thread the prompt starts.
      chrome.agentOpen = true;
      prompt = "";
      priorPrompt = null;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      sending = false;
    }
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
    if (priorPrompt !== null) priorPrompt = null;
  }

  // ── Palette (⌘/) ──
  let wizardMode = $state<string | null>(null);
  function openPalette() { wizardMode = null; chrome.paletteOpen = true; }
  function openWizard(kind: string) { wizardMode = kind; chrome.paletteOpen = true; }
  function onPaletteWrite(text: string) {
    priorPrompt = prompt;
    prompt = text;
    queueMicrotask(() => textareaEl?.focus());
  }
  function undo() {
    if (priorPrompt === null) return;
    prompt = priorPrompt;
    priorPrompt = null;
  }
  function onWindowKey(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "/") { e.preventDefault(); openPalette(); }
  }

  // ── Create entry points ──
  async function newPackage() {
    try { await commands.packageCreate({ name: "Untitled", icon: "📦" }); }
    catch (e) { error = e instanceof Error ? e.message : String(e); }
  }

  // ── Voice mode (mock transport) ──
  type Bubble =
    | { kind: "msg"; id: number; who: "user" | "agent"; text: string }
    | { kind: "tool"; id: number; command: string; status: "ok" | "running" }
    | { kind: "chip"; id: number; text: string; status: "open" | "accepted" };
  let voiceMode = $state(false);
  let muted = $state(false);
  let bubbles = $state<Bubble[]>([]);

  function startVoice() {
    voiceMode = true;
    muted = false;
    // TODO(gemini-live): open the audio session against the brainstorming
    // agent; bubbles below are the rendered transcript / tool-call shape.
    bubbles = [
      { kind: "msg", id: 1, who: "agent", text: "What are we making?" },
      { kind: "tool", id: 2, command: "ls ~/Workbooks", status: "ok" },
      { kind: "chip", id: 3, text: "Draft a launch board for Q3", status: "open" },
    ];
  }
  function endVoice() { voiceMode = false; bubbles = []; }
  function acceptChip(b: Extract<Bubble, { kind: "chip" }>) {
    onPaletteWrite(b.text);
    bubbles = bubbles.map((x) => (x.kind === "chip" && x.id === b.id ? { ...x, status: "accepted" } : x));
  }
</script>

<svelte:window onkeydown={onWindowKey} />

<section class="home">
  <div class="hero">
    <button type="button" class="palette-chip" onclick={openPalette} title="Ask the workspace (⌘/)">
      <Sparkles size={12} strokeWidth={2} />
      <span>Ask the workspace anything…</span>
      <kbd>⌘/</kbd>
    </button>

    {#if !voiceMode}
      <form class="composer" onsubmit={(e) => { e.preventDefault(); submit(); }}>
        <textarea
          bind:this={textareaEl}
          bind:value={prompt}
          onkeydown={onKey}
          placeholder="What would you like to do?"
          rows="3"
          spellcheck="false"
          disabled={sending}
        ></textarea>
        <div class="foot">
          <div class="picker">
            <Dropdown bind:value={activeAgent} items={agentItems} placeholder="Agent" />
          </div>
          <span class="hint">⌘↵</span>
          <button type="button" class="btn" onclick={startVoice} title="Talk by voice" aria-label="Start voice">
            <AudioLines size={13} strokeWidth={2} />
          </button>
          <button type="submit" class="btn primary" disabled={!canSend} aria-label="Send">
            <ArrowRight size={13} strokeWidth={2} />
          </button>
        </div>
      </form>

      {#if priorPrompt !== null}
        <button type="button" class="undo-chip" onclick={undo} title="Revert to your previous prompt">
          <Undo2 size={11} strokeWidth={2} /> <span>Undo</span>
        </button>
      {/if}

      <div class="quick">
        <button type="button" class="chip" onclick={newPackage}><Plus size={11} strokeWidth={2} /> Package</button>
        <button type="button" class="chip" onclick={() => openWizard("create-board")}><Kanban size={11} strokeWidth={2} /> Board</button>
        <button type="button" class="chip" onclick={() => openWizard("create-workbook")}><BookOpen size={11} strokeWidth={2} /> Workbook</button>
        <button type="button" class="chip" onclick={() => openWizard("create-skill")}><Wand2 size={11} strokeWidth={2} /> Skill</button>
      </div>
    {:else}
      <div class="voice-strip">
        <span class="voice-dot" class:muted></span>
        <span class="voice-status">{muted ? "Muted" : "Listening"}</span>
        <div class="voice-actions">
          <button type="button" class="voice-btn" onclick={() => (muted = !muted)} aria-label="Mute">
            {#if muted}<MicOff size={14} strokeWidth={2} />{:else}<Mic size={14} strokeWidth={2} />{/if}
          </button>
          <button type="button" class="voice-btn end" onclick={endVoice} aria-label="End session">
            <PhoneOff size={14} strokeWidth={2} />
          </button>
        </div>
      </div>

      <div class="transcript">
        {#each bubbles as b (b.id)}
          {#if b.kind === "msg"}
            <div class="bubble" class:agent={b.who === "agent"}>
              <span class="who">{b.who === "agent" ? "Workhorse" : "You"}</span>
              <span>{b.text}</span>
            </div>
          {:else if b.kind === "tool"}
            <div class="tool">
              <Wrench size={11} strokeWidth={2} />
              <code>{b.command}</code>
              <Check size={11} strokeWidth={2.5} />
            </div>
          {:else}
            <button type="button" class="voice-chip" class:accepted={b.status === "accepted"}
              disabled={b.status !== "open"} onclick={() => acceptChip(b)}>
              Drop into composer<span class="detail">{b.text}</span>
            </button>
          {/if}
        {/each}
      </div>
    {/if}

    {#if error}<div class="err">{error}</div>{/if}
  </div>
</section>

<PaletteModal
  open={chrome.paletteOpen}
  composerText={prompt}
  {wizardMode}
  onclose={() => (chrome.paletteOpen = false)}
  onwrite={onPaletteWrite}
/>

<style>
  .home {
    flex: 1 1 auto; overflow: auto; background: var(--color-page);
    display: flex; justify-content: center; align-items: center;
    padding: 4rem 2rem 8rem;
  }
  .hero { width: 100%; max-width: 640px; display: flex; flex-direction: column; }

  .palette-chip {
    align-self: center; display: inline-flex; align-items: center; gap: 0.45rem;
    padding: 0.45rem 0.85rem; margin-bottom: 1rem; border-radius: 999px;
    background: var(--color-surface-soft); border: 1px solid var(--color-border);
    color: var(--color-fg-muted); font: inherit; font-size: 0.78rem; cursor: pointer;
    transition: background 0.12s, color 0.12s, border-color 0.12s;
  }
  .palette-chip:hover {
    background: var(--color-surface); color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .palette-chip kbd {
    font-family: ui-monospace, SFMono-Regular, monospace; font-size: 0.68rem;
    padding: 0.1rem 0.35rem; border: 1px solid var(--color-border); border-radius: 4px;
    background: var(--color-surface); color: var(--color-fg-subtle);
  }

  .composer {
    background: var(--color-surface); border: 1px solid var(--color-border);
    border-radius: 12px; padding: 0.85rem 0.85rem 0.55rem; display: flex;
    flex-direction: column; gap: 0.55rem; box-shadow: var(--shadow-pop);
  }
  .composer:focus-within { border-color: var(--color-border-strong); }
  .composer textarea {
    width: 100%; background: transparent; border: 0; outline: 0; resize: none;
    font: inherit; font-size: 1rem; color: var(--color-fg); line-height: 1.5;
    min-height: 84px;
  }
  .composer textarea::placeholder { color: var(--color-fg-subtle); }
  .foot { display: flex; align-items: center; gap: 0.5rem; }
  .picker { flex: 1 1 auto; min-width: 0; }
  .hint { font-size: 0.72rem; color: var(--color-fg-subtle); }

  .btn {
    display: inline-flex; align-items: center; justify-content: center;
    width: 32px; height: 32px; border-radius: 8px; border: 0; cursor: pointer;
    background: var(--color-surface-soft); color: var(--color-fg-muted);
    transition: opacity 0.12s, color 0.12s;
  }
  .btn:hover:not(:disabled) { color: var(--color-fg); }
  .btn:disabled { opacity: 0.35; cursor: default; }
  .btn.primary { background: var(--color-fg); color: var(--color-page); }
  .btn.primary:not(:disabled):hover { opacity: 0.88; }

  .undo-chip {
    align-self: flex-end; margin-top: 0.55rem; display: inline-flex; align-items: center;
    gap: 0.3rem; padding: 0.25rem 0.55rem; border: 1px solid var(--color-border);
    border-radius: 999px; background: var(--color-surface-soft); color: var(--color-fg-muted);
    font: inherit; font-size: 0.72rem; cursor: pointer;
  }
  .undo-chip:hover { background: var(--color-surface); color: var(--color-fg); }

  .quick { display: flex; gap: 0.4rem; margin-top: 0.85rem; justify-content: center; flex-wrap: wrap; }
  .chip {
    display: inline-flex; align-items: center; gap: 0.3rem; height: 28px; padding: 0 0.65rem;
    border-radius: 7px; border: 1px solid var(--color-border); background: var(--color-surface-soft);
    color: var(--color-fg-muted); font: inherit; font-size: 0.76rem; cursor: pointer;
    transition: color 0.12s, border-color 0.12s;
  }
  .chip:hover { color: var(--color-fg); border-color: var(--color-border-strong); }

  /* Voice mode */
  .voice-strip {
    display: flex; align-items: center; gap: 0.6rem;
    background: var(--color-surface); border: 1px solid var(--color-border);
    border-radius: 12px; padding: 0.75rem 0.85rem; box-shadow: var(--shadow-pop);
  }
  .voice-dot {
    width: 8px; height: 8px; border-radius: 999px; background: var(--color-ok);
    animation: pulse 1200ms ease-in-out infinite;
  }
  .voice-dot.muted { background: var(--color-fg-subtle); animation: none; }
  .voice-status { flex: 1 1 auto; font-size: 0.84rem; color: var(--color-fg); }
  .voice-actions { display: flex; gap: 0.35rem; }
  .voice-btn {
    display: grid; place-items: center; width: 30px; height: 30px; border-radius: 8px;
    border: 1px solid var(--color-border); background: var(--color-surface-soft);
    color: var(--color-fg-muted); cursor: pointer;
  }
  .voice-btn:hover { color: var(--color-fg); }
  .voice-btn.end:hover { color: var(--color-err); border-color: var(--color-err); }

  .transcript { margin-top: 0.85rem; display: flex; flex-direction: column; gap: 0.5rem; }
  .bubble { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.85rem; color: var(--color-fg); }
  .bubble .who { font-size: 0.68rem; font-weight: 600; color: var(--color-fg-subtle); text-transform: uppercase; letter-spacing: 0.03em; }
  .bubble.agent { align-self: flex-start; }
  .tool {
    display: inline-flex; align-items: center; gap: 0.4rem; align-self: flex-start;
    padding: 0.3rem 0.55rem; border-radius: 7px; background: var(--color-surface-soft);
    border: 1px solid var(--color-border); color: var(--color-fg-muted); font-size: 0.74rem;
  }
  .tool code { font-family: ui-monospace, SFMono-Regular, monospace; color: var(--color-fg); }
  .voice-chip {
    display: flex; flex-direction: column; gap: 0.2rem; align-self: flex-start; text-align: left;
    padding: 0.45rem 0.65rem; border-radius: 8px; border: 1px solid var(--color-border);
    background: var(--color-surface); color: var(--color-fg); font: inherit; font-size: 0.78rem;
    font-weight: 600; cursor: pointer;
  }
  .voice-chip:hover:not(:disabled) { border-color: var(--color-border-strong); }
  .voice-chip:disabled { opacity: 0.6; cursor: default; }
  .voice-chip.accepted { color: var(--color-ok); }
  .voice-chip .detail { font-weight: 400; color: var(--color-fg-muted); }

  .err { margin-top: 0.6rem; color: var(--color-err); font-size: 0.8rem; text-align: center; }

  @keyframes pulse { 0%, 100% { opacity: 0.55; } 50% { opacity: 1; } }
</style>
