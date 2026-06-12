<script lang="ts">
  /**
   * EditIconModal — centered modal wrapper around IconPickerMenu for
   * context-menu-driven icon edits. The IconPickerMenu's trigger tile
   * is the only thing here; user clicks it to open the emoji / image
   * / initials popover, picks, and we fire `onchange` then close.
   */
  import IconPickerMenu from "./IconPickerMenu.svelte";

  let {
    title,
    name,
    initial,
    busy = false,
    error = null,
    onchange,
    oncancel,
  }: {
    title: string;
    name: string;
    initial: string;
    busy?: boolean;
    error?: string | null;
    onchange: (icon: string) => void;
    oncancel: () => void;
  } = $props();

  let value = $state(initial);
  let cardEl: HTMLDivElement | undefined = $state();

  // Forward every pick to the parent. Parent decides whether to close.
  $effect(() => {
    if (value !== initial) onchange(value);
  });

  function backdrop(e: MouseEvent) {
    const t = e.target as Node;
    if (cardEl && cardEl.contains(t)) return;
    oncancel();
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Escape") oncancel();
  }
</script>

<svelte:window onkeydown={key} />

<div class="backdrop" onmousedown={backdrop} role="presentation">
  <div class="card" bind:this={cardEl}>
    <h3>{title}</h3>
    <p class="sub">Click the tile to choose an emoji or upload an image.</p>
    <div class="tile-host">
      <IconPickerMenu bind:value {name} size={72} />
    </div>
    <div class="row">
      <button type="button" class="btn ghost" onclick={oncancel} disabled={busy}>
        Close
      </button>
    </div>
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
    max-width: 320px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem 1.25rem 1rem;
    text-align: center;
  }
  h3 {
    margin: 0 0 0.35rem;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  .sub {
    margin: 0 0 1rem;
    font-size: 0.78rem;
    color: var(--color-fg-muted);
  }
  .tile-host {
    display: flex;
    justify-content: center;
    margin-bottom: 1rem;
  }
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
    transition: color 0.15s, border-color 0.15s;
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover { border-color: var(--color-border-strong); color: var(--color-fg); }
  .err {
    margin-top: 0.5rem;
    font-size: 0.76rem;
    color: var(--color-err);
  }
</style>
