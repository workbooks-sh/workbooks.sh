<script lang="ts">
  /**
   * Share button for the workbook tab title strip (wb-v9ys.3).
   *
   * Pure trigger — opens the drawer, surfaces a tiny status dot for
   * shared / off / error so the user knows the state at a glance
   * without opening the drawer.
   */
  import { onMount } from "svelte";
  import { shareStore } from "$lib/share/store.svelte";
  import ShareDrawer from "$lib/share/ShareDrawer.svelte";

  let { path }: { path: string } = $props();

  let open = $state(false);
  // Don't name this `state` — collides with the `$state` rune token in
  // Svelte 5 and svelte-check trips over the shadowing.
  const share = $derived(shareStore.get(path));

  onMount(() => {
    void shareStore.hydrate(path);
  });

  // Re-hydrate if the tab swaps to a different workbook in-place
  // (rare, but the rest of the codebase rebinds bindings via path
  // changes rather than remount).
  $effect(() => {
    void shareStore.hydrate(path);
  });

  const dotKind = $derived(
    share.status === "shared" && share.rooms.some((r) => r.enabled) ? "on"
    : share.status === "shared" ? "off"
    : share.status === "error" ? "err"
    : null,
  );

  const label = $derived(
    share.status === "sharing" ? "Sharing…"
    : share.status === "shared" && share.rooms.some((r) => r.enabled) ? "Shared"
    : share.status === "shared" ? "Share off"
    : "Share",
  );
</script>

<button class="share" onclick={() => (open = true)} aria-label="Share workbook">
  {#if dotKind}<span class="dot" data-kind={dotKind}></span>{/if}
  <span class="text">{label}</span>
</button>

{#if open}
  <ShareDrawer {path} onclose={() => (open = false)} />
{/if}

<style>
  .share {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: 6px;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    color: var(--color-fg);
    font-size: 0.78rem;
    cursor: pointer;
    font: inherit;
  }
  .share:hover { background: var(--color-surface-soft); }
  .text { line-height: 1; }
  .dot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--color-fg-muted);
  }
  .dot[data-kind="on"]  { background: #10b981; }  /* emerald — ok */
  .dot[data-kind="off"] { background: #f59e0b; }  /* amber — paused */
  .dot[data-kind="err"] { background: #ef4444; }  /* rose — error */
</style>
