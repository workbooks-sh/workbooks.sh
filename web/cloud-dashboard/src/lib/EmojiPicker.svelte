<script>
  // Same component the desktop app uses (desktop/src/lib/workspace/EmojiPicker.svelte):
  // a thin wrapper around `emoji-picker-element`. Imported client-side only (it
  // registers a custom element that doesn't exist in SSR), then we mount
  // <emoji-picker> and forward emoji-click → onpick(unicode). Themed via the picker's
  // CSS custom properties to the dashboard palette.
  import { onMount } from 'svelte';

  let { onpick } = $props();

  let host = $state(null);
  let mounted = $state(false);

  onMount(() => {
    let picker = null;
    let cancelled = false;

    void import('emoji-picker-element').then(() => {
      if (cancelled || !host) return;
      mounted = true;
      picker = document.createElement('emoji-picker');
      picker.classList.add('wb-emoji-picker');
      picker.addEventListener('emoji-click', (e) => {
        const unicode = e.detail?.unicode;
        if (unicode) onpick(unicode);
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
    --background: var(--card);
    --border-color: var(--stroke);
    --button-active-background: var(--line);
    --button-hover-background: var(--line);
    --category-emoji-padding: 0.35rem;
    --indicator-color: var(--ink);
    --input-border-color: var(--stroke);
    --input-background: var(--card);
    --input-font-color: var(--ink);
    --input-placeholder-color: var(--dim);
    --num-columns: 8;
    --outline-color: var(--ink);
    --emoji-size: 1.2rem;
    width: 100%;
    max-width: 100%;
    height: 320px;
    border: none;
    border-radius: 8px;
  }
  .loading {
    color: var(--dim);
    font-size: 12px;
    padding: 1rem;
    text-align: center;
  }
</style>
