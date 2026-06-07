<!--
  InstallBar — full-bleed yellow band at the bottom of the hero.
  Standout secondary CTA: the curl one-liner + the agents it drops into.
-->
<script lang="ts">
  import AgentLogos from "../ds/AgentLogos.svelte";
  import BananaMan from "../ds/BananaMan.svelte";

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

<div class="relative bg-banana border-y border-banana-deep">
  <!--
    The banana mascot runs along the top of this yellow band. Sits on top
    of the bar (negative top offset). Tracks cursor, emotes on click.
  -->
  <BananaMan scale={3} speed={140} topOffset={-58} />
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-5 flex flex-col md:flex-row items-center justify-center gap-4 md:gap-6 text-fg">
    <span class="text-[13px] font-semibold whitespace-nowrap">Install the CLI</span>

    <button
      type="button"
      onclick={copy}
      class="group flex items-center gap-2 rounded-lg bg-white hover:bg-banana-soft transition-colors px-3 py-2 max-w-full"
      aria-label="copy install command"
    >
      <span class="text-fg-subtle text-[12px]" aria-hidden="true">$</span>
      <code class="font-mono text-[12.5px] text-fg truncate">{CMD}</code>
      <span class="text-[11px] text-fg-muted group-hover:text-blue-deep transition-colors ml-1 whitespace-nowrap">
        {copied ? "✓ copied" : "copy"}
      </span>
    </button>

    <div class="flex items-center gap-3 text-fg/75">
      <span class="text-[12px]">drops into</span>
      <a
        href="https://claude.com/code"
        target="_blank"
        rel="noreferrer"
        class="hover:text-fg transition-colors"
        title="Claude Code"
      >
        <AgentLogos name="claude-code" size={20} title="Claude Code" />
      </a>
      <a
        href="https://github.com/openai/codex"
        target="_blank"
        rel="noreferrer"
        class="hover:text-fg transition-colors"
        title="Codex CLI"
      >
        <AgentLogos name="codex" size={20} title="Codex" />
      </a>
      <a
        href="https://cursor.com"
        target="_blank"
        rel="noreferrer"
        class="hover:text-fg transition-colors"
        title="Cursor"
      >
        <AgentLogos name="cursor" size={20} title="Cursor" />
      </a>
    </div>
  </div>
</div>
