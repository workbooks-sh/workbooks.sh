<script lang="ts">
  /**
   * SettingsPanel — the shared card wrapper for every settings tab:
   * a title + lede header, an optional actions slot, and the body.
   */
  import type { Snippet } from "svelte";

  let {
    title,
    lede,
    actions,
    children,
  }: {
    title: string;
    lede?: string;
    actions?: Snippet;
    children: Snippet;
  } = $props();
</script>

<section class="panel">
  <header>
    <div class="text">
      <h2>{title}</h2>
      {#if lede}<p>{lede}</p>{/if}
    </div>
    {#if actions}<div class="actions">{@render actions()}</div>{/if}
  </header>
  <div class="body">{@render children()}</div>
</section>

<style>
  .panel {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  header {
    display: flex;
    align-items: flex-start;
    gap: 1rem;
  }
  .text {
    flex: 1 1 auto;
    min-width: 0;
  }
  h2 {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
  }
  p {
    margin: 0.25rem 0 0;
    font-size: 0.8rem;
    color: var(--color-fg-muted);
    line-height: 1.45;
  }
  .actions {
    flex-shrink: 0;
  }
</style>
