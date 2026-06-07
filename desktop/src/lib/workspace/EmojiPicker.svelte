<script lang="ts">
  /**
   * Thin wrapper around `emoji-picker-element` (same component Studio
   * uses, see archive/studio/frontend/src/lib/components/EmojiPicker.svelte).
   * We import client-side only (the package registers a custom element
   * which doesn't exist in SSR), then mount `<emoji-picker>` and listen
   * for `emoji-click`.
   *
   * Styled to fit the desktop's theme via the picker's CSS custom
   * properties — see https://github.com/nolanlawson/emoji-picker-element
   */
  import { onMount } from "svelte";

  let { onpick }: { onpick: (emoji: string) => void } = $props();

  let host = $state<HTMLDivElement | null>(null);
  let mounted = $state(false);

  onMount(() => {
    let picker: HTMLElement | null = null;
    let cancelled = false;

    void import("emoji-picker-element").then(() => {
      if (cancelled || !host) return;
      mounted = true;
      picker = document.createElement("emoji-picker");
      picker.classList.add("wb-emoji-picker");
      picker.addEventListener("emoji-click", (e: Event) => {
        const detail = (e as unknown as CustomEvent).detail as {
          unicode?: string;
        };
        if (detail?.unicode) onpick(detail.unicode);
      });
      host.appendChild(picker);
    });

    return () => {
      cancelled = true;
      picker?.remove();
    };
  });
</script>

<div class="picker-host" bind:this={host}>
  {#if !mounted}
    <p class="loading">Loading emoji picker…</p>
  {/if}
</div>

<style>
  .picker-host :global(emoji-picker) {
    --background: var(--color-surface);
    --border-color: var(--color-border);
    --button-active-background: var(--color-surface-soft);
    --button-hover-background: var(--color-surface-soft);
    --category-emoji-padding: 0.4rem;
    --indicator-color: var(--color-fg);
    --input-border-color: var(--color-border);
    --input-background: var(--color-surface-soft);
    --input-font-color: var(--color-fg);
    --input-placeholder-color: var(--color-fg-subtle);
    --num-columns: 8;
    --outline-color: var(--color-fg-muted);
    width: 100%;
    max-width: 100%;
    border-radius: 8px;
  }
  .loading {
    color: var(--color-fg-muted);
    font-size: 0.85rem;
    padding: 1rem;
  }
</style>
