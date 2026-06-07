<script lang="ts">
  /**
   * RailTooltip — verbatim copy of
   * archive/studio/frontend/src/lib/components/RailTooltip.svelte.
   *
   * No adaptation needed; the component is self-contained and only
   * depends on the design tokens already defined in app.css.
   * Listed in the audit as As-is + COPY.
   */
  import type { Snippet } from "svelte";

  let { label, children }: { label: string; children: Snippet } = $props();
</script>

<div class="wrap">
  {@render children()}
  <span class="tip" role="tooltip">{label}</span>
</div>

<style>
  .wrap {
    position: relative;
    display: inline-flex;
  }
  .tip {
    position: absolute;
    top: 50%;
    left: calc(100% + 0.5rem);
    transform: translateY(-50%) translateX(-4px);
    padding: 0.3rem 0.55rem;
    background: var(--color-fg);
    color: var(--color-page);
    font-size: 0.72rem;
    font-weight: 500;
    letter-spacing: 0.01em;
    border-radius: 4px;
    white-space: nowrap;
    pointer-events: none;
    opacity: 0;
    transition:
      opacity 0.12s ease,
      transform 0.12s ease;
    box-shadow: var(--shadow-pop);
    z-index: 50;
  }
  .wrap:hover .tip,
  .wrap:focus-within .tip {
    opacity: 1;
    transform: translateY(-50%) translateX(0);
  }
</style>
