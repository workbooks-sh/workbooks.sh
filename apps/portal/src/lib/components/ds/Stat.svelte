<!--
  Stat — number + label. Inline display for the stat strip.
-->
<script lang="ts">
  interface Props {
    value: string;
    unit?: string;
    label: string;
    color?: "banana" | "cherry" | "blue" | "white";
  }

  let { value, unit, label, color = "banana" }: Props = $props();

  const colorClass: Record<NonNullable<Props["color"]>, string> = {
    banana: "text-banana",
    cherry: "text-cherry",
    blue: "text-blue",
    white: "text-white",
  };
</script>

<div class="inline-flex items-baseline gap-2">
  <span class="font-serif text-[28px] leading-none {colorClass[color]}">
    {value}{#if unit}<span class="font-mono text-[14px] text-bg-cream-soft ml-0.5">{unit}</span>{/if}
  </span>
  <span class="font-mono text-[12px] text-bg-cream-soft lowercase tracking-wider">
    {label}
  </span>
</div>
