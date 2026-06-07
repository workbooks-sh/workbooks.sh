<!--
  SectionHead — kicker (§ NN) + title + optional lede.
-->
<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    kicker?: string;
    title: string;
    lede?: string;
    align?: "left" | "center";
    children?: Snippet;
  }

  let { kicker, title, lede, align = "left", children }: Props = $props();
</script>

<header class="max-w-3xl mb-10 {align === 'center' ? 'mx-auto text-center' : ''}">
  {#if kicker}
    <div class="mb-4">
      <span class="font-mono text-[11px] tracking-[0.08em] text-fg-muted border-b-2 border-banana pb-1">
        {kicker}
      </span>
    </div>
  {/if}
  <h2 class="font-serif text-[28px] md:text-[42px] leading-[1.1] tracking-tight font-normal text-fg mb-3">
    {title}
  </h2>
  {#if lede}
    <p class="text-fg-soft text-[15px] leading-relaxed">{lede}</p>
  {/if}
  {#if children}
    {@render children()}
  {/if}
</header>
