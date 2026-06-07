<script lang="ts">
  import ChunkyBox from "../ds/ChunkyBox.svelte";
  import Button from "../ds/Button.svelte";

  interface Props {
    open: boolean;
    onClose: () => void;
  }
  let { open, onClose }: Props = $props();

  const INSTALL_CMD = "curl -fsSL https://install.brandnana.net | sh";
  let copied = $state(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(INSTALL_CMD);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      /* noop */
    }
  }

  function backdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) onClose();
  }
</script>

{#if open}
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div
    class="fixed inset-0 bg-fg/40 flex items-center justify-center px-6 z-50"
    onclick={backdropClick}
    aria-hidden="true"
  >
    <div class="w-full max-w-lg">
      <ChunkyBox surface="white" shadow="ink" rounded="lg">
        <div class="flex items-center justify-between px-4 py-3 bg-bg-cream-soft border-b-2 border-border-ink">
          <span class="font-mono text-[12px] text-fg-muted">install brandnana</span>
          <button
            type="button"
            class="bg-transparent border-none font-mono text-[12px] text-fg-subtle hover:text-fg cursor-pointer"
            onclick={onClose}
            aria-label="close"
          >[esc]</button>
        </div>
        <div class="p-6 flex flex-col gap-4">
          <p class="font-mono text-[11px] uppercase tracking-[0.08em] text-fg-muted">
            one-liner · macOS + Linux
          </p>
          <div class="flex items-stretch border-2 border-border-ink rounded overflow-hidden">
            <pre class="m-0 flex-1 px-4 py-3 bg-fg text-bg-cream font-mono text-[13px] overflow-x-auto whitespace-pre">{INSTALL_CMD}</pre>
            <button
              type="button"
              class="bg-banana hover:bg-banana-deep px-5 font-sans font-bold text-[12px] text-fg border-l-2 border-border-ink cursor-pointer transition-colors"
              onclick={copy}
            >
              {copied ? "copied ✓" : "copy"}
            </button>
          </div>
          <p class="text-fg-muted text-[12px] leading-relaxed">
            drops the binary in <code class="font-mono bg-bg-cream-soft border border-border-warm px-1 rounded">~/.local/bin/brandnana</code>.
            no sudo. inspect <a href="https://github.com/workbooks-sh/brandnana/blob/main/install.sh" target="_blank" rel="noreferrer">install.sh</a>.
          </p>
          <Button variant="ghost" size="sm" onclick={onClose}>close</Button>
        </div>
      </ChunkyBox>
    </div>
  </div>
{/if}
