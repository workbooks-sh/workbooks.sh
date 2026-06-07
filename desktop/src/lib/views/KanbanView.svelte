<script lang="ts">
  /**
   * KanbanView — query-driven board editor. A board picker plus a column
   * grid, matching the old BoardPanel's shape. Cards are static mock data;
   * board loading + drag wiring is deferred.
   */
  import { ChevronDown, Plus } from "@lucide/svelte";

  const columns = [
    { id: "todo", title: "To do", cards: ["Draft the brief", "Collect references"] },
    { id: "doing", title: "In progress", cards: ["Wire the rail"] },
    { id: "done", title: "Done", cards: ["Scaffold the SPA"] },
  ];
</script>

<section class="board">
  <header>
    <button class="picker">Default board <ChevronDown size={14} strokeWidth={1.8} /></button>
    <button class="new"><Plus size={13} strokeWidth={2} /> New task</button>
  </header>

  <div class="cols">
    {#each columns as col (col.id)}
      <div class="col">
        <div class="col-head">
          <span>{col.title}</span>
          <span class="count">{col.cards.length}</span>
        </div>
        {#each col.cards as c (c)}
          <article class="card">{c}</article>
        {/each}
      </div>
    {/each}
  </div>
</section>

<style>
  .board {
    padding: 1rem 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
    height: 100%;
  }
  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .picker,
  .new {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 30px;
    padding: 0 0.6rem;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg);
    font-size: 0.82rem;
    cursor: pointer;
  }
  .new {
    margin-left: auto;
    background: var(--color-fg);
    color: var(--color-page);
    border-color: transparent;
  }
  .cols {
    display: flex;
    gap: 0.75rem;
    align-items: flex-start;
    overflow-x: auto;
    flex: 1 1 auto;
  }
  .col {
    flex: 0 0 240px;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    padding: 0.5rem;
  }
  .col-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 0.76rem;
    font-weight: 600;
    color: var(--color-fg-muted);
    padding: 0.1rem 0.2rem;
  }
  .count {
    font-weight: 500;
    color: var(--color-fg-subtle);
  }
  .card {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.55rem 0.6rem;
    font-size: 0.83rem;
  }
</style>
