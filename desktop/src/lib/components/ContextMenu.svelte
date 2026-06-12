<script lang="ts">
  /**
   * Tiny context menu primitive (wb-i38o.7). Caller controls open/closed
   * via `open` + `x`/`y` props; the menu auto-closes on backdrop click,
   * Escape, or scroll. Items are passed as a snippet so the call site
   * gets full styling control without inventing a Type for them.
   */
  import type { Snippet } from "svelte";

  let {
    open = $bindable(false),
    x,
    y,
    children,
  }: {
    open: boolean;
    x: number;
    y: number;
    children: Snippet;
  } = $props();

  let menuEl: HTMLDivElement | undefined = $state();

  // Clamp to viewport so the menu doesn't render off the right edge
  // (common when right-clicking a row near the rail's right side).
  const clamped = $derived.by(() => {
    if (!open) return { left: x, top: y };
    const w = menuEl?.offsetWidth ?? 180;
    const h = menuEl?.offsetHeight ?? 120;
    const maxX = window.innerWidth - w - 8;
    const maxY = window.innerHeight - h - 8;
    return {
      left: Math.min(x, Math.max(8, maxX)),
      top: Math.min(y, Math.max(8, maxY)),
    };
  });

  function close() {
    open = false;
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") close();
  }
</script>

<svelte:window onkeydown={onKey} onscroll={close} />

{#if open}
  <button
    class="backdrop"
    aria-label="Close menu"
    onclick={close}
    oncontextmenu={(e) => {
      e.preventDefault();
      close();
    }}
  ></button>
  <div
    bind:this={menuEl}
    class="menu"
    role="menu"
    style="left: {clamped.left}px; top: {clamped.top}px"
  >
    {@render children()}
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: transparent;
    border: 0;
    padding: 0;
    margin: 0;
    cursor: default;
    z-index: 999;
  }
  .menu {
    position: fixed;
    z-index: 1000;
    min-width: 180px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-pop);
    padding: 4px;
    font-size: 12.5px;
    color: var(--color-fg);
  }
  /* Items are styled by callers using :global(.ctx-item) to keep
   * the markup flexible. Caller wraps each row in a <button class="ctx-item"> */
  :global(.ctx-item) {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    width: 100%;
    padding: 6px 10px;
    border: 0;
    background: transparent;
    color: var(--color-fg);
    text-align: left;
    cursor: pointer;
    border-radius: 8px;
    font: inherit;
    transition: background 0.15s, color 0.15s;
  }
  :global(.ctx-item:hover:not(:disabled)) {
    background: var(--color-surface-soft);
  }
  :global(.ctx-item:disabled) {
    color: var(--color-fg-subtle);
    cursor: default;
  }
  :global(.ctx-sep) {
    height: 1px;
    background: var(--color-border);
    margin: 4px 2px;
  }
</style>
