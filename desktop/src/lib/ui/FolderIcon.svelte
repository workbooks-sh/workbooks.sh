<script lang="ts">
  /**
   * FolderIcon — a solid (filled) folder glyph, single tint. No emoji /
   * badge overlay — folders read as plain folders; the name next to the
   * icon carries the identity (Arc-style sidebar model).
   */
  let {
    color = "var(--color-brand, #2f6fe0)",
    size = 18,
  }: { color?: string; size?: number } = $props();
</script>

<span class="folder" style="--c:{color}; --s:{size}px;">
  <svg viewBox="0 0 48 40" class="glyph" aria-hidden="true">
    <path
      d="M3 7.5C3 5.6 4.6 4 6.5 4h10.2c.9 0 1.8.36 2.5 1l2.3 2.3c.66.63 1.55 1 2.47 1H41.5C43.4 8.3 45 9.9 45 11.8V32c0 1.9-1.6 3.5-3.5 3.5h-35C4.6 35.5 3 33.9 3 32z"
    />
  </svg>
</span>

<style>
  .folder {
    display: inline-grid;
    place-items: center;
    width: var(--s);
    height: calc(var(--s) * 0.84);
    flex-shrink: 0;
  }
  .glyph {
    width: 100%;
    height: 100%;
    fill: var(--c);
  }
</style>
