<script lang="ts">
  /**
   * FolderIcon — the composable folder: solid folder base (tintable
   * color) + an optional BADGE from the universal icon library
   * (mi:<def>, lobe:<slug>, emoji, data-URL) sitting in the bottom-right
   * corner. Picking an "icon" for a folder swaps the badge — it never
   * stops being a folder. (Material's pre-baked folder variants aren't
   * used here; we compose instead so any icon and any color combine.)
   */
  import Icon from "$lib/ui/Icon.svelte";

  let {
    color = "var(--color-brand, #149157)",
    badge = "",
    name = "",
    size = 18,
  }: { color?: string; badge?: string; name?: string; size?: number } =
    $props();

  const badgePx = $derived(Math.max(9, Math.round(size * 0.62)));
  /** Material's own folder construction: glyph in a light tint ON the
   *  colored folder, never a full-color logo (red rocket on blue folder
   *  reads as a clash). Non-emoji badges render as a WHITE silhouette —
   *  works on every folder color in both themes. Emoji keep their own
   *  colors; they're designed to read on anything. */
  const silhouette = $derived(/^(mi|lobe|lucide):|^data:image\//.test(badge));
</script>

<span class="folder" style="--c:{color}; --s:{size}px;">
  <svg viewBox="0 0 48 40" class="glyph" aria-hidden="true">
    <path
      d="M3 7.5C3 5.6 4.6 4 6.5 4h10.2c.9 0 1.8.36 2.5 1l2.3 2.3c.66.63 1.55 1 2.47 1H41.5C43.4 8.3 45 9.9 45 11.8V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z"
    />
  </svg>
  {#if badge}
    <span class="badge" class:silhouette style="--bs:{badgePx}px;">
      <Icon value={badge} {name} size={badgePx} />
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
    flex-shrink: 0;
  }
  .glyph {
    width: 100%;
    height: 100%;
    /* Deepen whatever tint comes in — white badges need a folder dark
       enough to sit on (a light teal folder swallowed the silhouette).
       72% tint over deep navy keeps the hue but guarantees contrast. */
    fill: color-mix(in srgb, var(--c) 72%, #141c30);
  }
  /* Badge — tucked in the bottom-right corner, sitting on the folder
     with a hint of overflow. */
  .badge {
    position: absolute;
    right: -4%;
    bottom: -6%;
    display: inline-flex;
    align-items: flex-end;
    justify-content: center;
    line-height: 1;
    font-size: var(--bs);
  }
  /* White silhouette for svg/image badges — any icon on any folder
     color, both themes. ~90% opacity reads as material's pale-tint
     glyph rather than stark white. */
  .badge.silhouette {
    filter: brightness(0) invert(1) drop-shadow(0 0.5px 0.5px rgba(15, 20, 40, 0.4));
    opacity: 0.95;
  }
  .badge :global(img) {
    width: var(--bs);
    height: var(--bs);
    object-fit: contain;
  }
</style>
