<script lang="ts">
  /**
   * Button — the canonical action affordance.
   *
   * Variants: primary (inverted fg/page), ghost (bordered, transparent),
   * danger (rose), subtle (no border, hover fill). All share the 34px
   * default height, 8px radius, 140ms opacity transition. `icon` is a
   * leading snippet (lucide glyph); `children` is the label.
   */
  import type { Snippet } from "svelte";

  let {
    variant = "primary",
    size = "md",
    type = "button",
    disabled = false,
    title,
    icon,
    children,
    onclick,
  }: {
    variant?: "primary" | "ghost" | "danger" | "subtle";
    size?: "sm" | "md";
    type?: "button" | "submit";
    disabled?: boolean;
    title?: string;
    icon?: Snippet;
    children?: Snippet;
    onclick?: (e: MouseEvent) => void;
  } = $props();
</script>

<button {type} {title} {disabled} {onclick} class="btn {variant} {size}">
  {#if icon}<span class="ico">{@render icon()}</span>{/if}
  {#if children}<span class="lbl">{@render children()}</span>{/if}
</button>

<style>
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.35rem;
    height: 34px;
    padding: 0 0.85rem;
    border: 1px solid transparent;
    border-radius: 8px;
    font-family: inherit;
    font-size: 0.84rem;
    font-weight: 500;
    cursor: pointer;
    transition: opacity 0.14s ease, background 0.12s ease, border-color 0.12s ease;
  }
  .btn.sm { height: 28px; padding: 0 0.6rem; font-size: 0.78rem; }
  .btn:disabled { opacity: 0.45; cursor: default; }
  .btn .ico { display: inline-flex; flex-shrink: 0; }

  .primary { background: var(--color-fg); color: var(--color-page); }
  .primary:hover:not(:disabled) { opacity: 0.88; }

  .ghost {
    background: transparent;
    color: var(--color-fg);
    border-color: var(--color-border);
  }
  .ghost:hover:not(:disabled) {
    background: var(--color-surface-soft);
    border-color: var(--color-border-strong);
  }

  .subtle { background: transparent; color: var(--color-fg-muted); }
  .subtle:hover:not(:disabled) {
    background: var(--color-surface-soft);
    color: var(--color-fg);
  }

  .danger {
    background: transparent;
    color: var(--color-err);
    border-color: color-mix(in srgb, var(--color-err) 32%, transparent);
  }
  .danger:hover:not(:disabled) {
    background: color-mix(in srgb, var(--color-err) 12%, transparent);
  }
</style>
