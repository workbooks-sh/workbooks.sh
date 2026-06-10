<script>let { pad = true, children, ...rest } = $props();</script>
<div class="card" class:pad {...rest}>{@render children()}</div>
<style>
  .card{background:var(--card);border:1px solid var(--hair);border-radius:20px;box-shadow:var(--shadow);overflow:hidden}
  .pad{padding:var(--pad-card)}
</style>
