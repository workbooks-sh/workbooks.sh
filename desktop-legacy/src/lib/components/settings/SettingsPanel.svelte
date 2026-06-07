<script lang="ts">
  /**
   * SettingsPanel — shared outer wrapper for every Settings tab body.
   *
   * Establishes consistent spacing + a uniform head shape
   * (title + lede on the left, action slot on the right) so all six
   * panels read as siblings. Body content is rendered via children.
   *
   * Variants:
   *   - default: shows the title + lede header + body
   *   - flush:   no card background — the parent (e.g. SettingsContainer)
   *              already paints the surface. Used by single-purpose
   *              panels that don't want a card-in-a-card look.
   */
  import type { Snippet } from "svelte";

  let {
    title,
    lede,
    actions,
    flush = false,
    children,
  }: {
    title: string;
    lede?: string;
    actions?: Snippet;
    flush?: boolean;
    children: Snippet;
  } = $props();
</script>

<section class="panel" class:flush>
  <header class="head">
    <div class="head-text">
      <h2>{title}</h2>
      {#if lede}<p>{lede}</p>{/if}
    </div>
    {#if actions}<div class="head-actions">{@render actions()}</div>{/if}
  </header>
  <div class="body">
    {@render children()}
  </div>
</section>

<style>
  .panel {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    padding: 1.1rem 1.25rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .panel.flush {
    background: transparent;
    border: 0;
    border-radius: 0;
    padding: 0;
  }
  .head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
  }
  .head-text { min-width: 0; }
  h2 {
    margin: 0;
    font-size: 0.95rem;
    font-weight: 600;
    letter-spacing: -0.005em;
  }
  .head p {
    margin: 0.25rem 0 0;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
    line-height: 1.45;
    max-width: 60ch;
  }
  .head-actions {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    flex-shrink: 0;
  }
  .body {
    display: flex;
    flex-direction: column;
    gap: 0.7rem;
  }
</style>
