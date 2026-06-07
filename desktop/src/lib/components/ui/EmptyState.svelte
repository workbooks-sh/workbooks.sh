<script lang="ts">
  /**
   * EmptyState — the consistent "nothing here yet" affordance used by
   * settings panels, chat, and kanban. `icon` is a leading snippet
   * (lucide glyph); `cta` an optional action row beneath the prompt.
   */
  import type { Snippet } from "svelte";

  let {
    icon,
    title,
    description,
    cta,
  }: {
    icon?: Snippet;
    title: string;
    description?: string;
    cta?: Snippet;
  } = $props();
</script>

<div class="empty" role="status">
  {#if icon}<div class="ico">{@render icon()}</div>{/if}
  <h3>{title}</h3>
  {#if description}<p>{description}</p>{/if}
  {#if cta}<div class="cta">{@render cta()}</div>{/if}
</div>

<style>
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.5rem;
    padding: 2rem 1.5rem;
    text-align: center;
    background: var(--color-surface-soft);
    border: 1px dashed var(--color-border);
    border-radius: 10px;
    color: var(--color-fg-muted);
  }
  .ico {
    width: 40px;
    height: 40px;
    margin-bottom: 0.2rem;
    border-radius: 10px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--color-fg-muted);
  }
  h3 {
    margin: 0;
    font-size: 0.92rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    color: var(--color-fg);
  }
  p { margin: 0; font-size: 0.82rem; line-height: 1.5; max-width: 42ch; }
  .cta { margin-top: 0.55rem; display: flex; align-items: center; gap: 0.4rem; }
</style>
