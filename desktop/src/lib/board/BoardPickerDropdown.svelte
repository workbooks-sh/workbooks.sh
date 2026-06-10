<script lang="ts">
  /**
   * wb-n3a2 — Kanban panel's board picker. Mirrors the chrome of
   * AgentPickerDropdown.svelte so the desktop's "pick a thing from
   * a list of named things with icons" pattern is consistent.
   *
   * The "+ Create board" row at the bottom triggers `oncreate`; the
   * parent panel routes that to the chat compose with a pre-filled
   * prompt scoped to a board-authoring agent.
   */
  import { CaretDown as ChevronDown, Plus } from "phosphor-svelte";
  import { tick } from "svelte";
  import AgentIcon from "$lib/chat/AgentIcon.svelte";
  import type { BoardView } from "./api";

  let {
    views,
    selectedId,
    onselect,
    oncreate,
  }: {
    views: BoardView[];
    selectedId: string | null;
    onselect: (id: string) => void;
    oncreate: () => void;
  } = $props();

  let triggerEl = $state<HTMLButtonElement | null>(null);
  let menuEl = $state<HTMLDivElement | null>(null);
  let open = $state(false);
  let highlight = $state(0);

  const selected = $derived(views.find((v) => v.id === selectedId) ?? null);

  const rows = $derived<BoardView[]>(
    [...views].sort((a, b) => a.name.localeCompare(b.name)),
  );

  async function toggle(e: MouseEvent) {
    e.stopPropagation();
    open = !open;
    if (open) {
      highlight = Math.max(
        0,
        rows.findIndex((v) => v.id === selectedId),
      );
      await tick();
    }
  }

  function pick(v: BoardView) {
    onselect(v.id);
    open = false;
  }

  function pickCreate() {
    open = false;
    oncreate();
  }

  $effect(() => {
    if (!open) return;
    function away(e: MouseEvent) {
      const t = e.target as Node;
      if (menuEl?.contains(t) || triggerEl?.contains(t)) return;
      open = false;
    }
    function key(e: KeyboardEvent) {
      if (!open) return;
      if (e.key === "Escape") {
        open = false;
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        highlight = Math.min(highlight + 1, rows.length);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        highlight = Math.max(highlight - 1, 0);
      } else if (e.key === "Enter") {
        e.preventDefault();
        if (highlight < rows.length) pick(rows[highlight]);
        else pickCreate();
      }
    }
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", key);
    };
  });
</script>

<div class="picker">
  <button
    type="button"
    bind:this={triggerEl}
    class="trigger"
    onclick={toggle}
    aria-haspopup="listbox"
    aria-expanded={open}
    title={selected?.tagline ?? selected?.name ?? ""}
  >
    <span class="t-icon" aria-hidden="true">
      {#if selected}
        <AgentIcon
          icon={selected.icon ?? null}
          title={selected.name}
          slug={selected.id}
          size={16}
        />
      {/if}
    </span>
    <span class="t-title">{selected?.name ?? "Pick a board"}</span>
    <ChevronDown weight="bold" size={12} class="chev" aria-hidden="true" />
  </button>

  {#if open}
    <div
      bind:this={menuEl}
      class="menu"
      role="listbox"
      onclick={(e) => e.stopPropagation()}
    >
      {#if rows.length === 0}
        <div class="empty">No boards yet.</div>
      {:else}
        {#each rows as v, i (v.id)}
          <button
            type="button"
            role="option"
            class="row"
            class:selected={v.id === selectedId}
            class:active={i === highlight}
            aria-selected={v.id === selectedId}
            onclick={() => pick(v)}
            onmouseenter={() => (highlight = i)}
          >
            <span class="row-icon" aria-hidden="true">
              <AgentIcon
                icon={v.icon ?? null}
                title={v.name}
                slug={v.id}
                size={18}
              />
            </span>
            <span class="row-body">
              <span class="row-title">{v.name}</span>
              {#if v.tagline}
                <span class="row-tag">{v.tagline}</span>
              {/if}
            </span>
          </button>
        {/each}
      {/if}
      <div class="add-row">
        <button
          type="button"
          class="row add"
          class:active={highlight === rows.length}
          onclick={pickCreate}
          onmouseenter={() => (highlight = rows.length)}
        >
          <span class="row-icon dashed" aria-hidden="true">
            <Plus weight="bold" size={12} />
          </span>
          <span class="add-label">Create board</span>
        </button>
      </div>
    </div>
  {/if}
</div>

<style>
  .picker {
    position: relative;
    display: inline-block;
  }
  .trigger {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    height: 28px;
    padding: 0 0.5rem 0 0.3rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 5px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
    text-align: left;
    max-width: 260px;
    min-width: 0;
  }
  .trigger:hover {
    border-color: var(--color-fg-subtle);
  }
  .t-icon {
    display: inline-flex;
    width: 20px;
    height: 20px;
    align-items: center;
    justify-content: center;
    border-radius: 4px;
    background: var(--color-surface-soft);
    flex: 0 0 20px;
    font-size: 12px;
    font-weight: 600;
  }
  .t-title {
    font-weight: 600;
    font-size: 12.5px;
    line-height: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1 1 auto;
    min-width: 0;
  }
  :global(.trigger .chev) {
    color: var(--color-fg-subtle);
    margin-left: 0.125rem;
    flex-shrink: 0;
  }
  .menu {
    position: absolute;
    top: calc(100% + 6px);
    left: 0;
    width: 320px;
    max-height: 70vh;
    overflow-y: auto;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    box-shadow: var(--shadow-pop, 0 8px 24px rgba(0, 0, 0, 0.3));
    padding: 0.375rem;
    z-index: 50;
  }
  .empty {
    padding: 0.7rem 0.6rem;
    color: var(--color-fg-muted);
    font-size: 12.5px;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    width: 100%;
    text-align: left;
    padding: 0.4rem 0.5rem;
    border: 0;
    background: transparent;
    border-radius: 5px;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
  }
  .row:hover,
  .row.active {
    background: var(--color-surface-soft);
  }
  .row.selected {
    background: var(--color-surface-soft);
    outline: 1px solid var(--color-border);
  }
  .row-icon {
    display: inline-flex;
    width: 22px;
    height: 22px;
    align-items: center;
    justify-content: center;
    flex: 0 0 22px;
    background: var(--color-surface-soft);
    border-radius: 5px;
    border: 1px solid var(--color-border);
    overflow: hidden;
  }
  .row-body {
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
    gap: 1px;
  }
  .row-title {
    font-size: 13px;
    font-weight: 600;
    line-height: 1.25;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-tag {
    font-size: 11.5px;
    color: var(--color-fg-muted);
    line-height: 1.3;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .add-row {
    margin-top: 0.35rem;
    padding-top: 0.35rem;
    border-top: 1px solid var(--color-border);
  }
  .row.add {
    color: var(--color-fg-muted);
  }
  .row.add:hover,
  .row.add.active {
    color: var(--color-fg);
  }
  .row-icon.dashed {
    background: transparent;
    border: 1px dashed var(--color-border);
    color: var(--color-fg-muted);
  }
  .add-label {
    font-size: 12.5px;
    font-weight: 500;
  }
</style>
