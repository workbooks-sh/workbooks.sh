<script lang="ts">
  /**
   * wb-i38o.33.6 — single headline card on the Kanban board.
   *
   * Read-only for the initial slice (this issue). Drag-and-drop lands
   * with wb-alkb (33.6.1); inline edits with wb-sodw (33.6.2).
   * Live-session cards (wb-rgon) carry a `live` field and render with
   * a pulsing green dot + elapsed timer.
   */
  import type { BoardCardItem } from "./types";

  let { card }: { card: BoardCardItem } = $props();

  const priorityColor = $derived(
    card.priority === "A"
      ? "var(--color-error, #e11d48)"
      : card.priority === "B"
        ? "var(--color-warning, #d97706)"
        : card.priority === "C"
          ? "var(--color-muted, #71717a)"
          : null,
  );
</script>

<div class="card" class:live={!!card.live} role="listitem">
  <div class="title-row">
    {#if card.live}
      <span class="live-dot" aria-label="Live session" title="Running session"></span>
    {/if}
    {#if card.priority}
      <span class="priority" style:color={priorityColor}>[#{card.priority}]</span>
    {/if}
    <span class="title">{card.title}</span>
  </div>
  {#if card.tags.length > 0}
    <div class="tags">
      {#each card.tags as t (t)}
        <span class="tag">{t}</span>
      {/each}
    </div>
  {/if}
  {#if card.live}
    <div class="live-meta">
      running · {Math.floor((Date.now() - card.live.startedAt) / 1000)}s
    </div>
  {/if}
</div>

<style>
  .card {
    background: var(--color-surface, #ffffff);
    border: 1px solid var(--color-border, #e4e4e7);
    border-radius: 6px;
    padding: 0.5rem 0.625rem;
    font-size: 0.8125rem;
    line-height: 1.35;
    color: var(--color-fg, #18181b);
    box-shadow:
      0 1px 1px rgba(0, 0, 0, 0.02),
      0 1px 2px rgba(0, 0, 0, 0.03);
  }

  .title-row {
    display: flex;
    gap: 0.375rem;
    align-items: baseline;
  }

  .priority {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.6875rem;
    font-weight: 600;
    flex-shrink: 0;
  }

  .title {
    flex: 1;
    word-break: break-word;
  }

  .tags {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem;
    margin-top: 0.375rem;
  }

  .tag {
    background: var(--color-muted-bg, #f4f4f5);
    color: var(--color-muted, #71717a);
    font-size: 0.6875rem;
    font-family: var(--font-mono, ui-monospace, monospace);
    padding: 0.0625rem 0.375rem;
    border-radius: 999px;
  }

  /* wb-rgon — live session styling. Subtle but clearly distinct
   * from on-disk task cards. */
  .card.live {
    border-color: rgba(52, 211, 153, 0.5);
    background:
      linear-gradient(
        180deg,
        rgba(52, 211, 153, 0.04),
        rgba(52, 211, 153, 0.01) 30%,
        var(--color-surface, #ffffff)
      );
  }
  .live-dot {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #34d399;
    flex-shrink: 0;
    box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.6);
    animation: live-pulse 1.6s ease-out infinite;
  }
  @keyframes live-pulse {
    0% {
      box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.55);
    }
    70% {
      box-shadow: 0 0 0 8px rgba(52, 211, 153, 0);
    }
    100% {
      box-shadow: 0 0 0 0 rgba(52, 211, 153, 0);
    }
  }
  .live-meta {
    margin-top: 0.375rem;
    font-size: 0.6875rem;
    color: #34d399;
    font-family: var(--font-mono, ui-monospace, monospace);
    text-transform: lowercase;
  }
</style>
