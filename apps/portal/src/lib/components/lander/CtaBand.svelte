<script lang="ts">
  import Button from "../ds/Button.svelte";

  interface Props {
    onInstall: () => void;
  }
  let { onInstall }: Props = $props();

  const INSTALL_CMD = "curl -fsSL https://install.brandnana.net | sh";
</script>

<section
  class="bg-banana border-t-2 border-b-2 border-border-ink relative overflow-hidden"
  style="background-image: repeating-linear-gradient(135deg, rgba(31,26,20,0.06) 0 8px, transparent 8px 16px);"
>
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-10 flex flex-wrap items-center justify-between gap-6 relative">
    <div class="max-w-xl">
      <h2 class="font-serif text-[26px] md:text-[32px] leading-tight tracking-tight font-normal text-fg mb-1">
        Your first brand book in under a minute.
      </h2>
      <p class="text-fg-soft text-[13px]">
        No accounts. No SDKs. Just a CLI and an agent that already knows how to use it.
      </p>
    </div>
    <div class="flex flex-col items-end gap-2">
      <Button variant="dark" size="lg" onclick={onInstall}>
        <span class="font-mono text-[12px] bg-banana border-2 border-border-ink rounded w-5 h-5 inline-flex items-center justify-center text-fg mr-1">$</span>
        install brandnana
      </Button>
      <code class="font-mono text-[12px] bg-white border-2 border-border-ink rounded px-3 py-1.5 text-fg">{INSTALL_CMD}</code>
    </div>
  </div>
</section>
