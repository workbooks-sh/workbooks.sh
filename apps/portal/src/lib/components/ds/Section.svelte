<!--
  Section — full-bleed section with centered inner container.
  Surfaces: white | cream | ink | banana
-->
<script lang="ts">
  import type { Snippet } from "svelte";

  type Surface = "white" | "cream" | "ink" | "banana" | "paper";
  type Padding = "sm" | "md" | "lg";

  interface Props {
    surface?: Surface;
    padding?: Padding;
    bordered?: boolean;
    id?: string;
    class?: string;
    innerClass?: string;
    children: Snippet;
  }

  let {
    surface = "white",
    padding = "lg",
    bordered = true,
    id,
    class: extraClass = "",
    innerClass = "",
    children,
  }: Props = $props();

  const surfaceClasses: Record<Surface, string> = {
    white: "bg-white text-fg",
    cream: "bg-bg-cream text-fg",
    paper: "bg-bg-cream-soft text-fg",
    ink: "bg-fg text-bg-cream",
    banana: "bg-banana text-fg",
  };

  const paddingClasses: Record<Padding, string> = {
    sm: "py-8",
    md: "py-14",
    lg: "py-20",
  };
</script>

<section
  {id}
  class="{surfaceClasses[surface]} {paddingClasses[padding]} {bordered ? 'border-b-2 border-border-ink' : ''} {extraClass}"
>
  <div class="max-w-6xl mx-auto px-6 md:px-8 {innerClass}">
    {@render children()}
  </div>
</section>
