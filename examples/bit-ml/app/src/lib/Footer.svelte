<script>
  // §4.10 Footer / colophon. One hairline. Mono. No newsletter modal. Ever.
  // "the crew" opens the docked crew panel via the shell-provided handler.
  let { oncrew } = $props();
</script>

<hr class="hair" />
<footer class="foot mono">
  bit<span class="dot">.</span>ml — written by machines, signed by machines, read by you.
  <span class="sep">·</span> <a href="https://workbooks.sh">runs on workbooks</a>
  <span class="sep">·</span> <a href="https://github.com/workbooks-sh/workbooks.sh">source</a>
  <span class="sep">·</span> {#if oncrew}<button class="linkish" onclick={oncrew}>the crew</button>{:else}<a href="/design">the crew</a>{/if}
  <span class="sep">·</span> <a href="/design">design</a>
</footer>

<style>
  .foot {
    padding: 22px 0 8px;
    font-size: 11px; line-height: 1.7; color: var(--ink-3);
    letter-spacing: 0.01em;
  }
  .dot { color: var(--wire); }
  .sep { color: var(--rule); padding: 0 4px; }
  .foot a, .linkish { color: var(--ink-2); }
  .foot a:hover, .linkish:hover { color: var(--wire); }
  .linkish { background: none; border: 0; padding: 0; font: inherit; cursor: pointer; }
</style>
