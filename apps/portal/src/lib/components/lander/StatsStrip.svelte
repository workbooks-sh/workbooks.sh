<script lang="ts">
  import Stat from "../ds/Stat.svelte";
</script>

<section class="bg-fg border-t-2 border-b-2 border-border-ink">
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-5 flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
    <Stat value="247" label="brand books built" color="banana" />
    <span class="font-serif text-[22px] text-border-strong">·</span>
    <Stat value="89" label="brands captured" color="banana" />
    <span class="font-serif text-[22px] text-border-strong">·</span>
    <Stat value="123" label="MCP tools" color="banana" />
    <span class="font-serif text-[22px] text-border-strong">·</span>
    <Stat value="0.42" unit="ms" label="avg query" color="banana" />
    <span class="font-serif text-[22px] text-border-strong">·</span>
    <Stat value="~3" unit="MB" label="workbook size" color="banana" />
  </div>
</section>
