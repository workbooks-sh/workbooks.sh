<script lang="ts">
  import Wordmark from "../ds/Wordmark.svelte";
</script>

<footer class="bg-white border-t border-line">
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-8 flex flex-wrap items-center justify-between gap-4 text-fg-muted text-[12.5px]">
    <div class="flex items-baseline gap-3">
      <Wordmark size="sm" />
      <span class="text-fg-subtle">v0.1 · pre-release</span>
    </div>
    <nav class="flex gap-5">
      <a href="/docs" class="no-underline hover:text-fg transition-colors">docs</a>
      <a href="/pricing" class="no-underline hover:text-fg transition-colors">pricing</a>
      <a href="/app" class="no-underline hover:text-fg transition-colors">portal</a>
      <a href="https://github.com/workbooks-sh/brandnana" target="_blank" rel="noreferrer" class="no-underline hover:text-fg transition-colors">github</a>
      <a href="https://api.brandnana.net/health" target="_blank" rel="noreferrer" class="no-underline hover:text-fg transition-colors">status</a>
    </nav>
  </div>
</footer>
