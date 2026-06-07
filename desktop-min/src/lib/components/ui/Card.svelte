<script lang="ts">
  /**
   * Card — the surface container. Optional `title` + `lede` header
   * (the SettingsPanel pattern) and an optional `actions` snippet
   * pinned top-right. `soft` drops the shadow for inline/list use.
   */
  import type { Snippet } from "svelte";

  let {
    title,
    lede,
    soft = false,
    actions,
    children,
  }: {
    title?: string;
    lede?: string;
    soft?: boolean;
    actions?: Snippet;
    children?: Snippet;
  } = $props();
</script>

<section class="card" class:soft>
  {#if title || actions}
    <header>
      <div class="head-text">
        {#if title}<h3>{title}</h3>{/if}
        {#if lede}<p>{lede}</p>{/if}
      </div>
      {#if actions}<div class="actions">{@render actions()}</div>{/if}
    </header>
  {/if}
  {#if children}<div class="body">{@render children()}</div>{/if}
</section>

<style>
  .card {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 12px;
    box-shadow: var(--shadow-pop);
    padding: 1.25rem;
  }
  .card.soft { box-shadow: none; border-radius: 10px; }
  header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 0.75rem;
    margin-bottom: 1rem;
  }
  .head-text { min-width: 0; }
  h3 {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    color: var(--color-fg);
  }
  p {
    margin: 0.2rem 0 0;
    font-size: 0.78rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
  }
  .actions { display: flex; align-items: center; gap: 0.4rem; flex-shrink: 0; }
</style>
