<!--
  CapabilityCard — one verb spot. Colored icon tile + title + blurb +
  realistic terminal output. Used in the lander capabilities grid.
-->
<script lang="ts">
  import ChunkyBox from "./ChunkyBox.svelte";
  import Terminal from "./Terminal.svelte";
  import CapIcon from "./CapIcon.svelte";

  type ColorKey = "cherry" | "teal" | "olive" | "rust" | "banana" | "plum" | "blue";

  interface Props {
    n: string;            // "01"
    title: string;
    blurb: string;
    cmd: string;
    out: string;
    color: ColorKey;
    icon: "logo" | "megaphone" | "catalog" | "brief" | "palette" | "wires";
  }

  let { n, title, blurb, cmd, out, color, icon }: Props = $props();

  // Color → background tint + ink color for the icon tile
  const tile: Record<ColorKey, string> = {
    cherry: "bg-[#ffe0d0] text-cherry",
    teal:   "bg-[#d5e6ec] text-teal",
    olive:  "bg-[#e2eacd] text-olive",
    rust:   "bg-[#ecdacf] text-rust",
    banana: "bg-[#fbe7a8] text-banana-deep",
    plum:   "bg-[#ead8e3] text-plum",
    blue:   "bg-[#d8e3f4] text-blue-deep",
  };
</script>

<!-- min-w-0 critical: lets this grid/flex item shrink below its <pre> intrinsic width -->
<ChunkyBox surface="white" shadow="ink" hover class="min-w-0">
  <div class="p-6 flex flex-col gap-3 h-full min-w-0">
    <div class="flex items-start justify-between">
      <div class="w-12 h-12 rounded-md border-2 border-border-ink flex items-center justify-center {tile[color]}">
        <CapIcon name={icon} />
      </div>
      <span class="font-mono text-[11px] tracking-[0.08em] text-fg-subtle pt-1">
        {n}
      </span>
    </div>
    <h3 class="font-serif text-[22px] leading-tight font-normal text-fg tracking-tight">
      {title}
    </h3>
    <p class="text-fg-soft text-[13px] leading-relaxed flex-1">
      {blurb}
    </p>
    <Terminal shadow="none">$ {cmd}
{out}</Terminal>
  </div>
</ChunkyBox>
