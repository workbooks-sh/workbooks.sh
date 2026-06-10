<script lang="ts">
  /**
   * BookmarksPopover — anchored next to the titlebar's Bookmark icon.
   *
   * Shows every saved bookmark; each row has its assigned command
   * slot (⌘1..⌘9 badge) when set. Click a row → open as a tab via
   * the tabs store. Per-row actions:
   *   - Assign slot (number picker dropdown)
   *   - Delete
   *
   * Footer button bookmarks the currently-active tab (if any).
   * Picking from the file tree → "Bookmark this file" via the
   * existing right-click context menu is a follow-up.
   */
  import { BookmarkSimple as BookmarkIcon, Plus, Trash as Trash2, X } from "phosphor-svelte";
  import { bookmarks, type Bookmark } from "$lib/bridge/bookmarks.svelte";
  import { tabs as tabsStore } from "$lib/tabs/store.svelte";
  import Dropdown from "./ui/Dropdown.svelte";
  import type { DropdownItem } from "./ui/Dropdown.types";

  let {
    anchor,
    open = $bindable(false),
  }: {
    anchor: HTMLElement | null;
    open: boolean;
  } = $props();

  let popoverEl: HTMLDivElement | undefined = $state();

  function basename(p: string): string {
    const parts = p.split(/[\\/]/).filter(Boolean);
    return parts[parts.length - 1] ?? p;
  }

  async function openBookmark(b: Bookmark) {
    open = false;
    try {
      await tabsStore.open(b.path);
    } catch (e) {
      console.warn("[bookmarks] open failed", e);
    }
  }

  async function addCurrentTab() {
    const active = tabsStore.active;
    if (!active) return;
    try {
      await bookmarks.create(active.title, active.path, null);
    } catch (e) {
      console.warn("[bookmarks] create failed", e);
    }
  }

  async function setSlot(b: Bookmark, slot: number | null) {
    try {
      await bookmarks.setSlot(b.id, slot);
    } catch (e) {
      console.warn("[bookmarks] setSlot failed", e);
    }
  }

  async function remove(b: Bookmark) {
    try {
      await bookmarks.delete(b.id);
    } catch (e) {
      console.warn("[bookmarks] delete failed", e);
    }
  }

  function onDocClick(e: MouseEvent) {
    if (!open) return;
    const t = e.target as Node;
    if (popoverEl && popoverEl.contains(t)) return;
    if (anchor && anchor.contains(t)) return;
    open = false;
  }

  function onKey(e: KeyboardEvent) {
    if (open && e.key === "Escape") open = false;
  }

  const slotItems = $derived<DropdownItem<number>[]>(
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((s) => ({
      value: s,
      label: s === 0 ? "None" : `⌘${s}`,
    })),
  );

  // Position relative to anchor (below + right-aligned).
  let style = $derived.by(() => {
    if (!anchor) return "";
    const r = anchor.getBoundingClientRect();
    const top = Math.round(r.bottom + 6);
    const left = Math.max(8, Math.round(r.left - 100));
    return `top: ${top}px; left: ${left}px;`;
  });
</script>

<svelte:window onmousedown={onDocClick} onkeydown={onKey} />

{#if open}
  <div
    class="popover"
    bind:this={popoverEl}
    role="dialog"
    aria-label="Bookmarks"
    {style}
  >
    <header class="head">
      <BookmarkIcon weight="fill" size={13} />
      <span class="title">Bookmarks</span>
      <span class="spacer"></span>
      {#if tabsStore.active}
        <button
          type="button"
          class="add-current"
          title="Bookmark current tab ({tabsStore.active.title})"
          onclick={addCurrentTab}
        >
          <Plus weight="bold" size={11} /> Add
        </button>
      {/if}
    </header>

    <div class="list">
      {#if bookmarks.bookmarks.length === 0}
        <div class="empty">
          <p>No bookmarks yet.</p>
          <p class="hint">
            Open a tab and click <strong>+ Add</strong> above to save it.
          </p>
        </div>
      {:else}
        {#each bookmarks.bookmarks as b (b.id)}
          {@const slotValue = b.command_slot ?? 0}
          <article class="row">
            <button
              type="button"
              class="row-body"
              onclick={() => openBookmark(b)}
              title={b.path}
            >
              {#if b.command_slot}
                <kbd class="slot">⌘{b.command_slot}</kbd>
              {:else}
                <span class="slot ghost">·</span>
              {/if}
              <span class="row-text">
                <span class="row-title">{b.title}</span>
                <span class="row-leaf">{basename(b.path)}</span>
              </span>
            </button>
            <div class="row-actions">
              <div class="slot-picker">
                <Dropdown
                  value={slotValue}
                  items={slotItems}
                  onchange={(v) => setSlot(b, v === 0 ? null : v)}
                  triggerClass="slot-trigger"
                />
              </div>
              <button
                type="button"
                class="icon-btn danger"
                title="Delete"
                aria-label="Delete bookmark"
                onclick={() => remove(b)}
              >
                <Trash2 weight="fill" size={12} />
              </button>
            </div>
          </article>
        {/each}
      {/if}
    </div>
  </div>
{/if}

<style>
  .popover {
    position: fixed;
    z-index: 500;
    width: 360px;
    max-width: calc(100vw - 16px);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 10px;
    box-shadow: var(--shadow-pop);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    max-height: 70vh;
  }
  .head {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.5rem 0.7rem;
    border-bottom: 1px solid var(--color-border);
    color: var(--color-fg);
  }
  .title { font-size: 0.85rem; font-weight: 600; }
  .spacer { flex: 1 1 auto; }
  .add-current {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    height: 22px;
    padding: 0 0.55rem;
    border-radius: 6px;
    background: var(--color-fg);
    color: var(--color-page);
    border: 0;
    font: inherit;
    font-size: 0.74rem;
    font-weight: 500;
    cursor: pointer;
  }
  .add-current:hover { opacity: 0.88; }

  .list {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 4px;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .empty {
    padding: 1.5rem 1rem;
    text-align: center;
    color: var(--color-fg-muted);
    font-size: 0.82rem;
  }
  .empty p { margin: 0; }
  .empty .hint { margin-top: 0.3rem; color: var(--color-fg-subtle); font-size: 0.78rem; }

  .row {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.2rem 0.35rem;
    border-radius: 6px;
  }
  .row:hover { background: var(--color-surface-soft); }
  .row-body {
    flex: 1 1 auto;
    display: flex;
    align-items: center;
    gap: 0.55rem;
    background: transparent;
    border: 0;
    padding: 0.35rem 0.45rem;
    cursor: pointer;
    color: var(--color-fg);
    font: inherit;
    font-size: 0.84rem;
    text-align: left;
    min-width: 0;
    border-radius: 5px;
  }
  .row-text { display: flex; flex-direction: column; min-width: 0; gap: 1px; }
  .row-title {
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-leaf {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.72rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .slot {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 32px;
    height: 20px;
    padding: 0 5px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 11px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 4px;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }
  .slot.ghost {
    background: transparent;
    border-style: dashed;
    color: var(--color-fg-subtle);
  }
  .row-actions { display: flex; gap: 2px; flex-shrink: 0; align-items: center; }
  .slot-picker :global(.slot-trigger) { height: 22px; padding: 0 0.4rem; font-size: 0.72rem; }
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 5px;
    cursor: pointer;
  }
  .icon-btn:hover { background: var(--color-surface); color: var(--color-fg); }
  .icon-btn.danger:hover {
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
  }
</style>
