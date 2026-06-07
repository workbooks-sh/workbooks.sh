<!--
  ChunkyBox — the signature PostHog/brandnana surface:
  thick ink border + hard offset shadow. Used for cards, terminals, panels.
-->
<script lang="ts">
  import type { Snippet } from "svelte";

  type Surface = "white" | "cream" | "ink" | "banana" | "blue" | "cherry";
  type Shadow = "none" | "ink" | "banana" | "cherry" | "blue" | "olive" | "teal";

  interface Props {
    surface?: Surface;
    shadow?: Shadow;
    hover?: boolean;     // lift on hover
    rounded?: "md" | "lg";
    class?: string;
    children: Snippet;
  }

  let {
    surface = "white",
    shadow = "ink",
    hover = false,
    rounded = "md",
    class: extraClass = "",
    children,
  }: Props = $props();

  const surfaceClasses: Record<Surface, string> = {
    white: "bg-white text-fg",
    cream: "bg-bg-cream text-fg",
    ink: "bg-fg text-bg-cream",
    banana: "bg-banana text-fg",
    blue: "bg-blue text-white",
    cherry: "bg-cherry text-white",
  };

  const shadowClasses: Record<Shadow, string> = {
    none: "",
    ink: "shadow-[4px_4px_0_0_var(--color-border-ink)]",
    banana: "shadow-[4px_4px_0_0_var(--color-banana-deep)]",
    cherry: "shadow-[4px_4px_0_0_var(--color-cherry-deep)]",
    blue: "shadow-[4px_4px_0_0_var(--color-blue-deep)]",
    olive: "shadow-[4px_4px_0_0_var(--color-olive)]",
    teal: "shadow-[4px_4px_0_0_var(--color-teal)]",
  };

  const hoverShadow: Record<Shadow, string> = {
    none: "",
    ink: "hover:shadow-[6px_6px_0_0_var(--color-border-ink)]",
    banana: "hover:shadow-[6px_6px_0_0_var(--color-banana-deep)]",
    cherry: "hover:shadow-[6px_6px_0_0_var(--color-cherry-deep)]",
    blue: "hover:shadow-[6px_6px_0_0_var(--color-blue-deep)]",
    olive: "hover:shadow-[6px_6px_0_0_var(--color-olive)]",
    teal: "hover:shadow-[6px_6px_0_0_var(--color-teal)]",
  };

  const className = [
    "border-2 border-border-ink",
    rounded === "lg" ? "rounded-lg" : "rounded-md",
    surfaceClasses[surface],
    shadowClasses[shadow],
    hover ? hoverShadow[shadow] : "",
    hover ? "hover:-translate-x-0.5 hover:-translate-y-0.5 transition-all duration-100" : "",
    extraClass,
  ]
    .filter(Boolean)
    .join(" ");
</script>

<div class={className}>
  {@render children()}
</div>
