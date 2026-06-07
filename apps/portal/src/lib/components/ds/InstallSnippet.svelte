<!--
  InstallSnippet — small, clean install one-liner CTA. Click to copy.
-->
<script lang="ts">
  const CMD = "curl -fsSL https://install.brandnana.net | sh";
  let copied = $state(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(CMD);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      /* noop */
    }
  }
</script>

<div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3">
  <span class="text-[12px] text-fg-muted">Or install the CLI:</span>
  <button
    type="button"
    onclick={copy}
    class="group flex items-center gap-2 rounded-lg bg-bg-tint hover:bg-bg-soft transition-colors px-3 py-2 text-left max-w-full"
    aria-label="copy install command"
  >
    <span class="text-fg-subtle text-[12px]" aria-hidden="true">$</span>
    <code class="font-mono text-[12.5px] text-fg truncate">{CMD}</code>
    <span class="text-[11px] text-fg-muted group-hover:text-blue-deep transition-colors ml-1">
      {copied ? "✓ copied" : "copy"}
    </span>
  </button>
</div>
