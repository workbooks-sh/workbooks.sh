<script lang="ts">
  /**
   * Tip — an immediate, well-designed hover tooltip with a chat-bubble tail.
   *
   * Wraps a target (icon button, rail item) and shows a label the instant the
   * pointer enters — no OS-tooltip delay. Theme-inverted (bg = --color-fg,
   * text = --color-page), so it reads as a black bubble with white text in light
   * mode and flips correctly under any theme. `side` aims the tail at the target;
   * the rail uses "right" so the bubble sits beside the rail, tail pointing back.
   */
  import type { Snippet } from "svelte";

  let {
    label,
    side = "right",
    children,
  }: { label: string; side?: "right" | "left" | "top" | "bottom"; children: Snippet } = $props();
</script>

<span class="wrap">
  {@render children()}
  <span class="tip tip-{side}" role="tooltip" aria-hidden="true">{label}</span>
</span>

<style>
  .wrap {
    position: relative;
    display: inline-flex;
  }
  .tip {
    position: absolute;
    z-index: 50;
    white-space: nowrap;
    pointer-events: none;
    padding: 4px 8px;
    border-radius: 6px;
    font-size: 11.5px;
    font-weight: 500;
    line-height: 1.2;
    letter-spacing: 0.01em;
    background: var(--color-fg);
    color: var(--color-page);
    box-shadow: var(--shadow-pop, 0 4px 14px rgba(0, 0, 0, 0.18));
    opacity: 0;
    transform: scale(0.96);
    transition:
      opacity 0.08s ease,
      transform 0.08s ease;
  }
  /* The bubble tail — a small square rotated 45°, same fill as the bubble. */
  .tip::before {
    content: "";
    position: absolute;
    width: 7px;
    height: 7px;
    background: var(--color-fg);
    transform: rotate(45deg);
  }

  .wrap:hover .tip,
  .wrap:focus-within .tip {
    opacity: 1;
    transform: scale(1);
  }

  /* Right of the target (rail default): tail points left. */
  .tip-right {
    left: calc(100% + 9px);
    top: 50%;
    transform: translateY(-50%) scale(0.96);
  }
  .wrap:hover .tip-right,
  .wrap:focus-within .tip-right {
    transform: translateY(-50%) scale(1);
  }
  .tip-right::before {
    left: -3px;
    top: 50%;
    margin-top: -3.5px;
  }

  .tip-left {
    right: calc(100% + 9px);
    top: 50%;
    transform: translateY(-50%) scale(0.96);
  }
  .wrap:hover .tip-left,
  .wrap:focus-within .tip-left {
    transform: translateY(-50%) scale(1);
  }
  .tip-left::before {
    right: -3px;
    top: 50%;
    margin-top: -3.5px;
  }

  .tip-top {
    bottom: calc(100% + 9px);
    left: 50%;
    transform: translateX(-50%) scale(0.96);
  }
  .wrap:hover .tip-top,
  .wrap:focus-within .tip-top {
    transform: translateX(-50%) scale(1);
  }
  .tip-top::before {
    bottom: -3px;
    left: 50%;
    margin-left: -3.5px;
  }

  .tip-bottom {
    top: calc(100% + 9px);
    left: 50%;
    transform: translateX(-50%) scale(0.96);
  }
  .wrap:hover .tip-bottom,
  .wrap:focus-within .tip-bottom {
    transform: translateX(-50%) scale(1);
  }
  .tip-bottom::before {
    top: -3px;
    left: 50%;
    margin-left: -3.5px;
  }
</style>
