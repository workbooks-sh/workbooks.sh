<script lang="ts">
  /**
   * EditNameModal — small centered dialog with a single text input.
   * Used by the right-click context menus on workspaces / packages to
   * rename in place without forcing a trip through Settings.
   *
   * Click outside or press Escape to cancel.
   */
  import { Check } from "phosphor-svelte";

  let {
    title,
    initial = "",
    placeholder = "Name",
    busy = false,
    error = null,
    onsubmit,
    oncancel,
  }: {
    title: string;
    initial?: string;
    placeholder?: string;
    busy?: boolean;
    error?: string | null;
    onsubmit: (name: string) => void;
    oncancel: () => void;
  } = $props();

  let value = $state(initial);
  let cardEl: HTMLDivElement | undefined = $state();

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Escape") oncancel();
  }

  function submit() {
    const v = value.trim();
    if (!v) return;
    onsubmit(v);
  }
</script>

<svelte:window onkeydown={key} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <h3>{title}</h3>
    <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
      <input
        type="text"
        bind:value
        placeholder={placeholder}
        autofocus
        disabled={busy}
      />
      <div class="row">
        <button
          type="button"
          class="btn ghost"
          disabled={busy}
          onclick={oncancel}
        >
          Cancel
        </button>
        <button
          type="submit"
          class="btn primary"
          disabled={busy || !value.trim()}
        >
          <Check weight="bold" size={13} /> Save
        </button>
      </div>
    </form>
    {#if error}<div class="err">{error}</div>{/if}
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.32);
    z-index: 1200;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card {
    width: 100%;
    max-width: 340px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem 1.25rem 1rem;
  }
  h3 {
    margin: 0 0 0.85rem;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  form { display: flex; flex-direction: column; gap: 0.55rem; }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.5rem 0.65rem;
    font-size: 0.88rem;
    font-family: inherit;
    color: var(--color-fg);
    outline: 0;
    transition: border-color 0.15s;
  }
  input:focus { border-color: var(--color-border-strong); }
  .row { display: flex; gap: 0.4rem; justify-content: flex-end; }
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 30px;
    padding: 0 0.85rem;
    border-radius: 8px;
    font-size: 0.82rem;
    font-weight: 500;
    font-family: var(--font-mono);
    cursor: pointer;
    border: 1px solid transparent;
    transition:
      color 0.15s,
      background 0.15s,
      border-color 0.15s,
      filter 0.15s,
      transform 0.35s cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary { background: var(--color-fg); color: var(--color-page); }
  .btn.primary:hover:not(:disabled) {
    filter: brightness(1.08);
    transform: translateY(-1px);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover:not(:disabled) {
    border-color: var(--color-border-strong);
    color: var(--color-fg);
  }
  .err {
    margin-top: 0.5rem;
    font-size: 0.76rem;
    color: var(--color-err);
    word-break: break-word;
  }
</style>
