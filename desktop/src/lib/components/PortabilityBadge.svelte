<script lang="ts">
  /**
   * PortabilityBadge — wb-unzn.25 P3.
   *
   * Small inline chip that surfaces a cell's (or workbook's) minimum
   * portability tier. Semantic colors per CLAUDE.md §11 convention:
   *
   *   browser   → emerald (ok / browser-portable)
   *   live-url  → amber   (warn / needs hosted VM)
   *   desktop   → rose    (error / needs recipient's own FS)
   *
   * Read-only display — clicking does nothing. The `title` attribute
   * carries the explanation so the meaning reads on hover.
   */
  import {
    type Tier,
    tierExplanation,
    tierLabel,
  } from "$lib/bridge/portability.svelte";

  let {
    tier,
    compact = false,
  }: {
    tier: Tier;
    compact?: boolean;
  } = $props();

  const tooltip = $derived(`${tierLabel(tier)} — ${tierExplanation(tier)}`);
</script>

<span class="badge {tier}" class:compact title={tooltip}>
  <span class="dot" aria-hidden="true"></span>
  <span class="label">{tierLabel(tier)}</span>
</span>

<style>
  /* Pill chip — same shape as ProvenanceBadge so the two read as siblings
   * when stacked in the sidebar. Fallback hex colors mirror the
   * convention used by SessionsModal / TerminalDrawer (var(--color-X, #hex))
   * so themes can override per CLAUDE.md theming rules. */
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2.5px 8px 2.5px 7px;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    line-height: 1;
    border: 1px solid transparent;
    cursor: help;
    user-select: none;
    white-space: nowrap;
  }
  .badge.compact {
    padding: 2px 7px 2px 6px;
    font-size: 0.66rem;
  }
  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: currentColor;
    flex-shrink: 0;
  }

  /* browser → emerald */
  .badge.browser {
    color: var(--color-emerald, #10b981);
    background: color-mix(in srgb, var(--color-emerald, #10b981) 10%, transparent);
    border-color: color-mix(in srgb, var(--color-emerald, #10b981) 28%, transparent);
  }
  /* live-url → amber */
  .badge.live-url {
    color: var(--color-amber, #d97706);
    background: color-mix(in srgb, var(--color-amber, #d97706) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-amber, #d97706) 32%, transparent);
  }
  /* desktop → rose */
  .badge.desktop {
    color: var(--color-rose, #e11d48);
    background: color-mix(in srgb, var(--color-rose, #e11d48) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-rose, #e11d48) 32%, transparent);
  }

  @media (prefers-color-scheme: dark) {
    .badge.browser {
      color: var(--color-emerald, #34d399);
      background: color-mix(in srgb, var(--color-emerald, #34d399) 18%, transparent);
      border-color: color-mix(in srgb, var(--color-emerald, #34d399) 36%, transparent);
    }
    .badge.live-url {
      color: var(--color-amber, #fbbf24);
      background: color-mix(in srgb, var(--color-amber, #fbbf24) 18%, transparent);
      border-color: color-mix(in srgb, var(--color-amber, #fbbf24) 36%, transparent);
    }
    .badge.desktop {
      color: var(--color-rose, #fb7185);
      background: color-mix(in srgb, var(--color-rose, #fb7185) 18%, transparent);
      border-color: color-mix(in srgb, var(--color-rose, #fb7185) 36%, transparent);
    }
  }
</style>
