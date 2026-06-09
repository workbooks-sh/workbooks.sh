<script lang="ts">
  /**
   * FolderIcon — a folder glyph (single tint) with the chosen icon dropped
   * bare into the bottom-left corner (no chip/container), sized ~1/3 of the
   * folder. Icon model matches the app and is resolved by the shared
   * Icon component: "" = no badge, lucide:<Name> = Lucide glyph,
   * data:image/ = image, else emoji.
   */
  import Icon from "./Icon.svelte";

  let {
    icon = "",
    color = "#9a9a9e",
    size = 40,
  }: { icon?: string; color?: string; size?: number } = $props();

  const hasBadge = $derived(!!icon);
  /** Lucide glyph sized to ~the emoji badge footprint (0.46 of folder). */
  const badgePx = $derived(Math.round(size * 0.46));
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
    <span class="badge" style="--bs:{badgePx}px;">
      <Icon value={icon} size={badgePx} strokeWidth={1.75} />
    </span>
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

  /* Bare badge — bottom-left corner, no background, ~1/3 of the folder.
     Content is rendered by the shared Icon component (emoji span / img /
     lucide svg); we just position + size the slot here. */
  .badge {
    position: absolute;
    left: 2%;
    bottom: -3%;
    display: inline-flex;
    align-items: flex-end;
    line-height: 1;
    /* emoji glyph scale */
    font-size: var(--bs);
    /* The folder front (--c-front) is ALWAYS a light tint (color mixed
       toward white) in both light and dark themes, so the badge glyph
       must be DARK to be legible — NOT the theme foreground (which is
       white in dark mode → white-on-white, invisible). Fixed near-black
       reads on every folder color. Emoji carry their own colors and
       ignore this. */
    color: #1c1d22;
    /* soft dark drop so the glyph separates from the folder regardless
       of its tint */
    filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.35));
  }
  .badge :global(img) {
    width: var(--bs);
    height: var(--bs);
    object-fit: contain;
  }
</style>

