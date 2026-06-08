<script lang="ts">
  /**
   * EmptyState — a consistent "nothing here yet" affordance.
   *
   * Two slots:
   *   - icon: large muted glyph (lucide component passed via prop)
   *   - cta: optional action snippet shown beneath the prompt
   *
   * Used by every settings panel + chat / kanban empty states so the
   * "before you've done anything" surface feels intentional, not
   * accidentally blank.
   */
  import type { Snippet } from "svelte";

  let {
    icon,
    title,
    description,
    cta,
  }: {
    icon?: typeof import("@lucide/svelte").Check;
    title: string;
    description?: string;
    cta?: Snippet;
  } = $props();
</script>

<div class="empty-state" role="status">
  {#if icon}
    {@const Icon = icon}
    <div class="icon"><Icon size={20} strokeWidth={1.6} /></div>
  {/if}
  <h3>{title}</h3>
  {#if description}<p>{description}</p>{/if}
  {#if cta}<div class="cta">{@render cta()}</div>{/if}
</div>

<style>
  .empty-state {
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
  .icon {
    width: 40px;
    height: 40px;
    border-radius: 10px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    color: var(--color-fg-muted);
    margin-bottom: 0.2rem;
  }
  h3 {
    margin: 0;
    font-size: 0.92rem;
    font-weight: 600;
    color: var(--color-fg);
    letter-spacing: -0.005em;
  }
  p {
    margin: 0;
    font-size: 0.82rem;
    line-height: 1.5;
    max-width: 42ch;
  }
  .cta {
    margin-top: 0.55rem;
    display: flex;
    align-items: center;
    gap: 0.4rem;
  }
</style>
