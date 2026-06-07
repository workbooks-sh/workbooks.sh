<script lang="ts">
  /**
   * Badge — the semantic state pill. Monochrome `neutral` by default;
   * `ok`/`warn`/`err` carry the only non-chrome color (emerald/amber/
   * rose), drawn from the --color-ok|warn|err tokens so themes + dark
   * mode track automatically. `dot` prepends a status dot; `compact`
   * tightens padding/size for dense rows.
   */
  import type { Snippet } from "svelte";

  let {
    tone = "neutral",
    dot = false,
    compact = false,
    title,
    children,
  }: {
    tone?: "neutral" | "ok" | "warn" | "err";
    dot?: boolean;
    compact?: boolean;
    title?: string;
    children?: Snippet;
  } = $props();
</script>

<span class="badge {tone}" class:compact {title}>
  {#if dot}<span class="dot" aria-hidden="true"></span>{/if}
  {#if children}<span class="lbl">{@render children()}</span>{/if}
</span>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 2.5px 8px;
    border: 1px solid transparent;
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    line-height: 1;
    letter-spacing: -0.005em;
    white-space: nowrap;
    user-select: none;
  }
  .badge.compact { padding: 2px 7px; font-size: 0.66rem; }
  .dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; flex-shrink: 0; }

  .neutral {
    color: var(--color-fg-muted);
    background: var(--color-surface-soft);
    border-color: var(--color-border);
  }
  .ok {
    color: var(--color-ok);
    background: color-mix(in srgb, var(--color-ok) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-ok) 30%, transparent);
  }
  .warn {
    color: var(--color-warn);
    background: color-mix(in srgb, var(--color-warn) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-warn) 30%, transparent);
  }
  .err {
    color: var(--color-err);
    background: color-mix(in srgb, var(--color-err) 12%, transparent);
    border-color: color-mix(in srgb, var(--color-err) 30%, transparent);
  }
</style>
