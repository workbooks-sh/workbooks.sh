<script lang="ts">
  /**
   * PaletteModal — the minimalist "Ask the workspace" AI palette opened
   * from the home composer (⌘/). It seeds the composer with a concrete
   * prompt rather than running anything itself: pick a quick agent or
   * type an intent, and `onwrite` drops the text back into the composer.
   * `wizardMode` pre-frames it for an explicit create flow (board /
   * workbook / skill) so the same modal doubles as the create wizard.
   *
   * The real palette streams a brainstorming agent (Gemini Live) and can
   * launch wizards; this is the layout + the write-back contract, so the
   * agent transport drops straight in.
   */
  import { Sparkles, Lightbulb, BarChart3, Code2 } from "@lucide/svelte";
  import { Modal } from "./ui";

  let {
    open = false,
    composerText = "",
    wizardMode = null,
    onclose,
    onwrite,
  }: {
    open?: boolean;
    composerText?: string;
    /** When set, the palette frames itself as a create wizard. */
    wizardMode?: string | null;
    onclose?: () => void;
    onwrite?: (text: string) => void;
  } = $props();

  let draft = $state("");

  // Mirror the composer text in when the modal opens.
  $effect(() => {
    if (open) draft = composerText;
  });

  const quick = [
    { id: "brainstorm", label: "Brainstorm", icon: Lightbulb, seed: "Help me brainstorm: " },
    { id: "analyze", label: "Analyze", icon: BarChart3, seed: "Analyze this workspace: " },
    { id: "code", label: "Build", icon: Code2, seed: "Write code that " },
  ];

  function pick(seed: string) {
    onwrite?.(seed + draft);
    onclose?.();
  }
  function commit() {
    if (draft.trim()) onwrite?.(draft.trim());
    onclose?.();
  }
</script>

<Modal {open} {onclose} title={wizardMode ? "Create" : "Ask the workspace"}
  lede={wizardMode ? "Describe what to make — the agent scaffolds it." : "Type an intent or pick a starting point."}>
  <div class="palette">
    <label class="field">
      <Sparkles size={14} strokeWidth={1.8} />
      <input
        bind:value={draft}
        placeholder="What do you want to do?"
        spellcheck="false"
        onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); commit(); } }}
      />
    </label>
    {#if !wizardMode}
      <div class="quick">
        {#each quick as q (q.id)}
          <button type="button" class="row" onclick={() => pick(q.seed)}>
            <q.icon size={14} strokeWidth={1.8} />
            <span>{q.label}</span>
          </button>
        {/each}
      </div>
    {/if}
  </div>
</Modal>

<style>
  .palette { display: flex; flex-direction: column; gap: 0.75rem; }
  .field {
    display: flex; align-items: center; gap: 0.5rem;
    background: var(--color-surface-soft); border: 1px solid var(--color-border);
    border-radius: 8px; padding: 0.55rem 0.7rem; color: var(--color-fg-muted);
  }
  .field:focus-within { border-color: var(--color-border-strong); }
  .field input {
    flex: 1 1 auto; border: 0; outline: 0; background: transparent;
    color: var(--color-fg); font: inherit; font-size: 0.9rem;
  }
  .quick { display: flex; flex-direction: column; gap: 0.25rem; }
  .row {
    display: flex; align-items: center; gap: 0.6rem; height: 36px;
    padding: 0 0.55rem; border: 0; border-radius: 8px; background: transparent;
    color: var(--color-fg); font: inherit; font-size: 0.84rem; cursor: pointer;
    text-align: left;
  }
  .row:hover { background: var(--color-surface-soft); }
</style>
