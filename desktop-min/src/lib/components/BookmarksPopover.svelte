<script lang="ts">
  /**
   * BookmarksPopover — saved file paths, anchored under the titlebar's
   * bookmark button (⌘B). Slots ⌘1..⌘9 open a path directly. Positioned
   * from the anchor's bounding rect, clamped to the viewport. A click
   * opens the path as a document tab; Esc / outside-click closes.
   */
  import { Bookmark } from "@lucide/svelte";
  import { commands, type Bookmark as Bm } from "$lib/bindings";
  import { tabs } from "$lib/tabs.svelte";
  import { chrome } from "$lib/chrome.svelte";

  let items = $state<Bm[]>([]);
  $effect(() => {
    void (async () => { items = await commands.bookmarksList(); })();
  });

  // Position under the anchor button, clamped into the viewport.
  const pos = $derived.by(() => {
    const a = chrome.bookmarksAnchor;
    if (!a) return { left: 8, top: 40 };
    const r = a.getBoundingClientRect();
    return { left: Math.min(r.left, window.innerWidth - 260), top: r.bottom + 6 };
  });

  async function open(b: Bm) {
    chrome.bookmarksOpen = false;
    chrome.mode = "doc";
    await tabs.open(b.path);
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") chrome.bookmarksOpen = false;
  }
  function onClick(e: MouseEvent) {
    const t = e.target as Node;
    if (chrome.bookmarksAnchor?.contains(t)) return;
    if (document.querySelector("[data-bookmarks]")?.contains(t)) return;
    chrome.bookmarksOpen = false;
  }
</script>

<svelte:window onkeydown={onKey} onclick={onClick} />

<div class="pop" data-bookmarks role="menu" style="left: {pos.left}px; top: {pos.top}px">
  {#each items as b, i (b.id)}
    <button type="button" class="row" role="menuitem" onclick={() => open(b)}>
      <Bookmark size={12} strokeWidth={1.8} />
      <span class="name">{b.title}</span>
      {#if i < 9}<kbd>⌘{i + 1}</kbd>{/if}
    </button>
  {:else}
    <p class="empty">No bookmarks yet.</p>
  {/each}
</div>

<style>
  .pop {
    position: fixed; z-index: 1500; min-width: 220px; max-width: 260px; padding: 6px;
    background: var(--color-surface); border: 1px solid var(--color-border);
    border-radius: 10px; box-shadow: var(--shadow-pop);
    display: flex; flex-direction: column; gap: 2px;
    animation: pop-in 0.1s ease-out;
  }
  @keyframes pop-in {
    from { opacity: 0; transform: translateY(-3px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .row {
    display: flex; align-items: center; gap: 8px; padding: 7px 9px;
    border: 0; border-radius: 6px; background: transparent; cursor: pointer;
    color: var(--color-fg); font: inherit; font-size: 0.82rem; text-align: left;
  }
  .row:hover { background: var(--color-surface-soft); }
  .name { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  kbd {
    font-size: 0.66rem; color: var(--color-fg-subtle);
    font-family: ui-monospace, monospace;
  }
  .empty { margin: 6px 9px; font-size: 0.78rem; color: var(--color-fg-subtle); }
</style>
