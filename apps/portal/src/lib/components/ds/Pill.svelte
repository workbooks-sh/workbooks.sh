<!--
  Pill — small monospace label, dashed or solid border.
  Variants: default | kicker | accent
-->
<script lang="ts">
  import type { Snippet } from "svelte";

  type Variant = "default" | "kicker" | "accent";

  interface Props {
    variant?: Variant;
    class?: string;
    children: Snippet;
  }

  let { variant = "default", class: extraClass = "", children }: Props = $props();

  const classes: Record<Variant, string> = {
    default:
      "inline-flex items-center font-mono text-[11px] px-2 py-0.5 border border-border-warm text-fg-muted bg-white rounded",
    kicker:
      "inline-flex items-center font-mono text-[11px] uppercase tracking-[0.08em] px-2.5 py-1 border border-dashed border-border-strong text-fg-muted bg-white rounded",
    accent:
      "inline-flex items-center font-mono text-[11px] px-2 py-0.5 border-2 border-border-ink text-fg bg-banana rounded",
  };
</script>

<span class="{classes[variant]} {extraClass}">
  {@render children()}
</span>
