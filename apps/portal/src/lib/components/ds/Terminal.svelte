<!--
  Terminal — chunky terminal frame with traffic-light dots and a title.
  Children render inside the body as plain text (use <pre>-like content).
-->
<script lang="ts">
  import type { Snippet } from "svelte";
  import ChunkyBox from "./ChunkyBox.svelte";

  type Shadow = "ink" | "banana" | "cherry" | "blue" | "olive" | "teal" | "none";

  interface Props {
    title?: string;
    shadow?: Shadow;
    tilt?: number;             // degrees, optional rotation for a touch of character
    class?: string;
    bodyClass?: string;
    children: Snippet;
  }

  let {
    title = "",
    shadow = "ink",
    tilt = 0,
    class: extraClass = "",
    bodyClass = "",
    children,
  }: Props = $props();
</script>

<!-- block (not inline-block) + min-w-0 so the <pre> inside can shrink under
     its content's intrinsic width and scroll horizontally inside the frame
     instead of pushing the page wider. -->
<div
  class="block w-full min-w-0 {extraClass}"
  style={tilt ? `transform: rotate(${tilt}deg);` : ""}
>
  <ChunkyBox surface="ink" {shadow} rounded="lg" class="overflow-hidden min-w-0">
    <div class="flex items-center gap-1.5 px-3 py-2 bg-bg-cream-soft border-b-2 border-border-ink">
      <span class="w-2.5 h-2.5 rounded-full bg-[#e15a4d] border border-border-ink"></span>
      <span class="w-2.5 h-2.5 rounded-full bg-banana border border-border-ink"></span>
      <span class="w-2.5 h-2.5 rounded-full bg-[#6fb084] border border-border-ink"></span>
      {#if title}
        <span class="ml-auto font-mono text-[11px] text-fg-muted">{title}</span>
      {/if}
    </div>
    <pre class="font-mono text-[12.5px] leading-[1.7] text-bg-cream-soft m-0 px-5 py-4 overflow-x-auto whitespace-pre {bodyClass}">{@render children()}</pre>
  </ChunkyBox>
</div>
