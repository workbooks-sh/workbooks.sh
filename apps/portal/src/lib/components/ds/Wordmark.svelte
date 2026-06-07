<!--
  Wordmark — banana + 'brandnana' lockup. Sizes:
    sm (header), md (footer), lg (hero).
-->
<script lang="ts">
  type Size = "sm" | "md" | "lg";

  interface Props {
    size?: Size;
    href?: string;
    class?: string;
  }

  let { size = "sm", href = "/", class: extraClass = "" }: Props = $props();

  const textSize: Record<Size, string> = {
    sm: "text-lg",
    md: "text-xl",
    lg: "text-3xl",
  };
  const iconSize: Record<Size, string> = {
    sm: "text-xl",
    md: "text-2xl",
    lg: "text-4xl",
  };
</script>

<a
  {href}
  class="inline-flex items-baseline gap-1.5 no-underline text-fg hover:text-fg-soft transition-colors {extraClass}"
  aria-label="brandnana home"
>
  <span class="{iconSize[size]} leading-none" aria-hidden="true">🍌</span>
  <span class="font-serif {textSize[size]} font-normal tracking-tight">brandnana</span>
</a>
