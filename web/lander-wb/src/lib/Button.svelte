<script>
  let { variant = "ink", sm = false, lg = false, href = null, children, ...rest } = $props();
</script>
{#if href}
  <a class="btn {variant}" class:sm class:lg {href} {...rest}>{@render children()}</a>
{:else}
  <button class="btn {variant}" class:sm class:lg {...rest}>{@render children()}</button>
{/if}
<style>
  .btn{display:inline-flex;align-items:center;gap:.5rem;font-weight:600;font-size:.98rem;
    padding:.78rem 1.4rem;border-radius:999px;border:0;cursor:pointer;transition:transform .14s ease;font-family:inherit}
  .btn:hover{transform:translateY(-2px)} .btn:active{transform:none}
  .ink{background:var(--ink);color:var(--bg)}
  .green{background:var(--green);color:#fff} .blue{background:var(--blue);color:#fff} .rose{background:var(--rose);color:#fff}
  .soft{background:var(--bg2);color:var(--ink)}
  .text{background:transparent;color:var(--ink);padding-inline:.3rem} .text:hover{color:var(--blue-text)}
  .sm{padding:.5rem .95rem;font-size:.84rem} .lg{padding:.95rem 1.8rem;font-size:1.06rem}
</style>
