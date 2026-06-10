<script>let { pad = true, children, ...rest } = $props();</script>
<div class="card" class:pad {...rest}>{@render children()}</div>
<style>
  .card{background:var(--card);border:1px solid var(--hair);border-radius:18px;box-shadow:var(--shadow);overflow:hidden}
  .pad{padding:clamp(1.4rem,2.4vw,2rem)}
</style>
