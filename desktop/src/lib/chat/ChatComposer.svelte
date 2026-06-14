<script lang="ts">
  /**
   * ChatComposer — the standard chat-input form across the app.
   *
   * One textarea + three action buttons in fixed order:
   *   [mic] [live] [send|cancel]
   *
   * Mic and live are stubs in v1: they render disabled unless the parent
   * passes handlers. Functionality lands in wb-xxbm.2 (Moonshine STT) and
   * wb-xxbm.5 (Gemini Live adapter).
   *
   * Submission: Cmd/Ctrl+Enter sends, plain Enter inserts newline.
   */

  import { Waveform as AudioWaveform, CircleNotch as Loader2, Microphone as Mic, PaperPlaneRight as Send, Stop as Square } from "phosphor-svelte";
  import type { Snippet } from "svelte";

  let {
    value = $bindable(""),
    placeholder = "",
    disabled = false,
    sending = false,
    canCancel = false,
    onSubmit,
    onCancel,
    onMicToggle,
    micActive = false,
    micDisabled = true,
    onLiveToggle,
    liveActive = false,
    liveDisabled = true,
    leading,
    actions,
  }: {
    value?: string;
    placeholder?: string;
    disabled?: boolean;
    sending?: boolean;
    canCancel?: boolean;
    onSubmit: (text: string) => void | Promise<void>;
    onCancel?: () => void;
    onMicToggle?: () => void;
    micActive?: boolean;
    micDisabled?: boolean;
    onLiveToggle?: () => void;
    liveActive?: boolean;
    liveDisabled?: boolean;
    leading?: Snippet;
    // Rendered at the start of the action row (left of mic/live/send) — e.g. a
    // compact model picker so the user can switch Waldo's model right by send.
    actions?: Snippet;
  } = $props();

  let textareaEl = $state<HTMLTextAreaElement | undefined>(undefined);

  export function focus() {
    textareaEl?.focus();
  }

  function autoGrow() {
    if (!textareaEl) return;
    textareaEl.style.height = "auto";
    const max = 160;
    textareaEl.style.height = Math.min(textareaEl.scrollHeight, max) + "px";
  }

  // Resize when the value changes externally (e.g. recallPrompt).
  $effect(() => {
    void value;
    queueMicrotask(autoGrow);
  });

  async function handleSubmit(e?: Event) {
    e?.preventDefault();
    const text = value.trim();
    if (!text || disabled) return;
    value = "";
    if (textareaEl) textareaEl.style.height = "";
    await onSubmit(text);
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      void handleSubmit();
    }
  }
</script>

<form class="composer" onsubmit={handleSubmit}>
  {#if leading}
    <div class="composer-leading">
      {@render leading()}
    </div>
  {/if}
  <div class="composer-row">
    <div class="composer-input-wrap">
      <textarea
        bind:this={textareaEl}
        bind:value
        {placeholder}
        rows={1}
        {disabled}
        oninput={autoGrow}
        onkeydown={onKey}
      ></textarea>
    </div>

    <div class="composer-actions">
    {#if actions}
      <div class="composer-actions-lead">{@render actions()}</div>
    {/if}
    <button
      type="button"
      class="composer-action"
      class:active={micActive}
      disabled={micDisabled}
      onclick={() => onMicToggle?.()}
      aria-label={micActive ? "Stop dictation" : "Start dictation"}
      aria-pressed={micActive}
      title="Dictate (Moonshine)"
    >
      <Mic weight="fill" size={13} aria-hidden="true" />
    </button>

    <button
      type="button"
      class="composer-action"
      class:active={liveActive}
      disabled={liveDisabled}
      onclick={() => onLiveToggle?.()}
      aria-label={liveActive ? "End live session" : "Start live session"}
      aria-pressed={liveActive}
      title="Live (Gemini)"
    >
      <AudioWaveform weight="fill" size={13} aria-hidden="true" />
    </button>

    {#if canCancel}
      <button
        type="button"
        class="composer-send stop"
        onclick={() => onCancel?.()}
        aria-label="Cancel session"
        title="Cancel"
      >
        <Square weight="fill" size={12} aria-hidden="true" />
      </button>
    {:else}
      <button
        type="submit"
        class="composer-send"
        disabled={disabled || value.trim().length === 0}
        aria-label="Send"
        title="Send (Cmd+Enter)"
      >
        {#if sending}
          <Loader2 weight="bold" size={13} class="spin" />
        {:else}
          <Send weight="fill" size={13} />
        {/if}
      </button>
    {/if}
    </div>
  </div>
</form>

<style>
  .composer {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    padding: 0.4rem 0.4rem 0.4rem 0.65rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 18px;
    box-shadow: var(--shadow-soft);
    transition:
      border-color 140ms ease,
      box-shadow 140ms ease;
  }
  .composer:focus-within {
    border-color: var(--color-border-strong);
    box-shadow: var(--shadow-card);
  }
  .composer-leading {
    display: flex;
    flex-wrap: wrap;
    gap: 0.3rem;
    padding: 0.2rem 0 0.1rem;
  }
  .composer-leading:empty {
    display: none;
  }
  .composer-row {
    display: flex;
    align-items: flex-end;
    gap: 0.25rem;
  }
  .composer-input-wrap {
    position: relative;
    flex: 1;
    display: flex;
  }
  .composer textarea {
    flex: 1;
    min-height: 28px;
    max-height: 160px;
    resize: none;
    padding: 0.4rem 0.25rem;
    font: inherit;
    font-size: 13.5px;
    line-height: 1.45;
    background: transparent;
    border: 0;
    color: var(--color-fg);
    overflow-y: auto;
  }
  .composer textarea:focus {
    outline: none;
  }
  .composer textarea:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
  .composer-actions {
    display: flex;
    align-items: center;
    gap: 0.25rem;
    align-self: flex-end;
  }
  .composer-actions-lead {
    display: flex;
    align-items: center;
    margin-right: 0.15rem;
  }
  .composer-action {
    flex: 0 0 28px;
    width: 28px;
    height: 28px;
    border-radius: 999px;
    background: transparent;
    color: var(--color-fg-subtle);
    border: 0;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    transition:
      background 140ms ease,
      color 140ms ease;
  }
  .composer-action:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }
  .composer-action:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .composer-action.active {
    background: var(--color-fg);
    color: var(--color-page);
  }
  .composer-send {
    flex: 0 0 28px;
    width: 28px;
    height: 28px;
    border-radius: 999px;
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
  }
  .composer-send:disabled {
    background: var(--color-surface-soft);
    color: var(--color-fg-subtle);
    cursor: not-allowed;
  }
  .composer-send.stop {
    background: #b91c1c;
    color: #fff;
  }
  .composer-send.stop:hover {
    background: #991b1b;
  }
  :global(.spin) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
