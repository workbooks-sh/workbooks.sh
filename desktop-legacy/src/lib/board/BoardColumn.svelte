<script lang="ts">
  /**
   * wb-i38o.33.6 — one column on the Kanban board.
   *
   * wb-alkb — drag-and-drop drop zone. svelte-dnd-action drives the
   * consider/finalize events; the parent (BoardPanel) owns the
   * cross-column reconciliation + PATCH.
   */
  import { dndzone } from "svelte-dnd-action";
  import BoardCard from "./BoardCard.svelte";
  import type { BoardCardItem, BoardColumn } from "./types";

  let {
    column,
    label,
    onConsider,
    onFinalize,
  }: {
    column: BoardColumn;
    /** Optional display override. When the board groups by agent
     *  (wb-pozn) the parent looks up the agent's title from the
     *  catalog and passes it here; absent → render column.state
     *  raw (TODO/DOING for status mode, slug for assigned mode). */
    label?: string | null;
    onConsider: (state: string, items: BoardCardItem[]) => void;
    onFinalize: (state: string, items: BoardCardItem[]) => void;
  } = $props();

  const DND_TYPE = "board-card";
  const FLIP_DURATION_MS = 180;

  function handleConsider(e: CustomEvent<{ items: BoardCardItem[] }>) {
    onConsider(column.state, e.detail.items);
  }

  function handleFinalize(e: CustomEvent<{ items: BoardCardItem[] }>) {
    onFinalize(column.state, e.detail.items);
  }
</script>

<section class="column" aria-label={column.state}>
  <header class="header">
    <span class="state">{label ?? column.state}</span>
    <span class="count" aria-label="{column.cards.length} cards"
      >{column.cards.length}</span
    >
  </header>
  <div
    class="cards"
    role="list"
    use:dndzone={{
      items: column.cards,
      type: DND_TYPE,
      flipDurationMs: FLIP_DURATION_MS,
      dropTargetStyle: {},
    }}
    onconsider={handleConsider}
    onfinalize={handleFinalize}
  >
    {#each column.cards as c (c.cardId)}
      <div>
        <BoardCard card={c} />
      </div>
    {:else}
      <div class="empty">No cards</div>
    {/each}
  </div>
</section>

<style>
  .column {
    display: flex;
    flex-direction: column;
    background: var(--color-page, #fafafa);
    border: 1px solid var(--color-border, #e4e4e7);
    border-radius: 8px;
    min-width: 16rem;
    max-width: 22rem;
    flex: 1 1 18rem;
    max-height: 100%;
    overflow: hidden;
  }

  .header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.625rem 0.75rem;
    border-bottom: 1px solid var(--color-border, #e4e4e7);
    background: var(--color-surface, #ffffff);
    flex-shrink: 0;
  }

  .state {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-fg, #18181b);
  }

  .count {
    font-size: 0.6875rem;
    font-family: var(--font-mono, ui-monospace, monospace);
    color: var(--color-muted, #71717a);
    background: var(--color-muted-bg, #f4f4f5);
    border-radius: 999px;
    padding: 0.0625rem 0.5rem;
  }

  .cards {
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    padding: 0.5rem;
    overflow-y: auto;
    flex: 1;
  }

  .empty {
    color: var(--color-muted, #71717a);
    font-size: 0.75rem;
    text-align: center;
    padding: 1rem 0.5rem;
    font-style: italic;
  }
</style>
