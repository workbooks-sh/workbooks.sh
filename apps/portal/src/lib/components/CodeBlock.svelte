<script lang="ts">
  interface Props {
    code: string;
    lang?: string;
  }
  let { code, lang = "sh" }: Props = $props();

  let copied = $state(false);

  async function copy() {
    await navigator.clipboard.writeText(code);
    copied = true;
    setTimeout(() => (copied = false), 1500);
  }
</script>

<div class="block">
  {#if lang}
    <span class="lang">{lang}</span>
  {/if}
  <pre><code>{code}</code></pre>
  <button class="copy-btn" onclick={copy} type="button">
    {copied ? "[copied]" : "[copy]"}
  </button>
</div>

<style>
  .block {
    position: relative;
    background: var(--color-bg-cream);
    border: 1px solid var(--color-border-warm);
    padding: 12px 14px;
    padding-top: 28px;
    border-radius: 2px;
  }

  .lang {
    position: absolute;
    top: 6px;
    left: 14px;
    font-size: 10px;
    color: var(--color-fg-subtle);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-family: var(--font-sans);
  }

  pre {
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }

  code {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--color-fg);
  }

  .copy-btn {
    position: absolute;
    top: 6px;
    right: 10px;
    background: none;
    border: none;
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 11px;
    cursor: pointer;
    padding: 0;
  }

  .copy-btn:hover {
    color: var(--color-fg);
  }
</style>
