<!--
  Button — chunky PostHog-style button with hard offset shadow.
  Variants: primary (banana), ghost (white), dark (ink), accent-cherry, accent-blue.
  Sizes:    sm | md | lg
  Tag:      default <button>, set href to render as <a>
-->
<script lang="ts">
  import type { Snippet } from "svelte";

  type Variant = "primary" | "ghost" | "dark" | "cherry" | "blue";
  type Size = "sm" | "md" | "lg";

  interface Props {
    variant?: Variant;
    size?: Size;
    href?: string;
    target?: string;
    rel?: string;
    type?: "button" | "submit";
    disabled?: boolean;
    onclick?: (e: MouseEvent) => void;
    class?: string;
    ariaLabel?: string;
    children: Snippet;
  }

  let {
    variant = "primary",
    size = "md",
    href,
    target,
    rel,
    type = "button",
    disabled = false,
    onclick,
    class: extraClass = "",
    ariaLabel,
    children,
  }: Props = $props();

  const variantClasses: Record<Variant, string> = {
    primary: "bg-banana hover:bg-banana-deep text-fg",
    ghost: "bg-white hover:bg-bg-cream text-fg",
    dark: "bg-fg hover:bg-fg-soft text-bg-cream",
    cherry: "bg-cherry hover:bg-cherry-deep text-white",
    blue: "bg-blue hover:bg-blue-deep text-white",
  };

  const sizeClasses: Record<Size, string> = {
    sm: "text-xs px-3 py-1.5 gap-1.5",
    md: "text-sm px-4 py-2 gap-2",
    lg: "text-base px-5 py-2.5 gap-2",
  };

  // Chunky button signature: 2px border-ink + offset shadow + translate-on-hover.
  // We use box-shadow instead of borders for the offset so the button keeps a
  // consistent footprint while hovered.
  const chunky =
    "inline-flex items-center justify-center font-bold border-2 border-border-ink rounded-md " +
    "shadow-[3px_3px_0_0_var(--color-border-ink)] " +
    "hover:shadow-[5px_5px_0_0_var(--color-border-ink)] hover:-translate-x-0.5 hover:-translate-y-0.5 " +
    "active:shadow-[1px_1px_0_0_var(--color-border-ink)] active:translate-x-0.5 active:translate-y-0.5 " +
    "transition-all duration-100 no-underline whitespace-nowrap select-none " +
    "disabled:opacity-50 disabled:pointer-events-none";

  const className = [
    chunky,
    variantClasses[variant],
    sizeClasses[size],
    extraClass,
  ].join(" ");
</script>

{#if href}
  <a {href} {target} {rel} class={className} aria-label={ariaLabel} {onclick}>
    {@render children()}
  </a>
{:else}
  <button {type} {disabled} class={className} aria-label={ariaLabel} {onclick}>
    {@render children()}
  </button>
{/if}
