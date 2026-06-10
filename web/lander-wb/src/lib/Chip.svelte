<script>let { tone = "", children } = $props();</script>
<span class="chip {tone}">{#if tone}<i></i>{/if}{@render children()}</span>
<style>
  .chip{display:inline-flex;align-items:center;gap:.45rem;font-family:var(--mono);font-size:.72rem;font-weight:500;
    padding:.32rem .75rem;border-radius:999px;background:var(--bg2);color:var(--ink2)}
  .chip i{width:7px;height:7px;border-radius:50%;flex:none}
  .live i{background:var(--green)} .live{color:var(--green-ink)}
  .run i{background:var(--blue)} .run{color:var(--blue-text)}
  .err i{background:var(--rose)} .err{color:var(--rose-text)}
</style>
