<script lang="ts">
  /**
   * FolderIcon — a folder glyph (single tint) with the chosen icon dropped
   * bare into the bottom-left corner (no chip/container), sized ~1/3 of the
   * folder. Icon model matches the app: "" = no badge, data:image/ = image,
   * else emoji.
   */
  let {
    icon = "",
    color = "#9a9a9e",
    size = 40,
  }: { icon?: string; color?: string; size?: number } = $props();

  const isImage = $derived(!!icon && icon.startsWith("data:image/"));
  const hasBadge = $derived(!!icon);
</script>

<span class="folder" style="--c:{color}; --s:{size}px;">
  <svg viewBox="0 0 48 40" class="glyph" aria-hidden="true">
    <path
      class="back"
      d="M3 7.5C3 5.6 4.6 4 6.5 4h10.2c.9 0 1.8.36 2.5 1l2.3 2.3c.66.63 1.55 1 2.47 1H41.5C43.4 8.3 45 9.9 45 11.8V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z"
    />
    <path
      class="front"
      d="M3 15.5C3 13.6 4.6 12 6.5 12h35c1.9 0 3.5 1.6 3.5 3.5V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z"
    />
  </svg>

  {#if hasBadge}
    {#if isImage}
      <img class="badge" src={icon} alt="" />
    {:else}
      <span class="badge emoji">{icon}</span>
    {/if}
  {/if}
</span>

<style>
  .folder {
    position: relative;
    display: inline-grid;
    place-items: center;
    width: var(--s);
    height: calc(var(--s) * 0.84);
    --c-front: color-mix(in srgb, var(--c) 80%, white);
    --c-back: color-mix(in srgb, var(--c) 100%, black 8%);
    --c-edge: color-mix(in srgb, var(--c) 100%, black 14%);
  }
  .glyph {
    width: 100%;
    height: 100%;
    overflow: visible;
    filter: drop-shadow(0 1px 1.5px rgba(15, 15, 15, 0.16));
  }
  .back {
    fill: var(--c-back);
  }
  .front {
    fill: var(--c-front);
    stroke: var(--c-edge);
    stroke-width: 0.5;
  }

  /* Bare badge — bottom-left corner, no background, ~1/3 of the folder. */
  .badge {
    position: absolute;
    left: 2%;
    bottom: -3%;
    line-height: 1;
  }
  .badge.emoji {
    font-size: calc(var(--s) * 0.46);
    /* thin light halo + soft drop so the glyph separates from the folder
       regardless of its own colors */
    filter: drop-shadow(0 0 1px rgba(255, 255, 255, 0.9))
      drop-shadow(0 1px 1.5px rgba(0, 0, 0, 0.3));
  }
  img.badge {
    width: calc(var(--s) * 0.46);
    height: calc(var(--s) * 0.46);
    object-fit: contain;
    filter: drop-shadow(0 0 1px rgba(255, 255, 255, 0.9))
      drop-shadow(0 1px 1.5px rgba(0, 0, 0, 0.3));
  }
</style>

