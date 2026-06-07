<script lang="ts">
  import Section from "../ds/Section.svelte";
  import SectionHead from "../ds/SectionHead.svelte";
  import ChunkyBox from "../ds/ChunkyBox.svelte";

  const tabs = ["claude-code", "cursor", "codex"] as const;
  type Tab = (typeof tabs)[number];

  let active = $state<Tab>("claude-code");

  const snippets: Record<Tab, string> = {
    "claude-code": `// ~/.claude/mcp.json
{
  "mcpServers": {
    "brandnana": {
      "command": "brandnana",
      "args": ["mcp"]
    }
  }
}`,
    cursor: `// ~/.cursor/mcp.json
{
  "mcpServers": {
    "brandnana": {
      "command": "brandnana",
      "args": ["mcp"]
    }
  }
}`,
    codex: `# ~/.codex/instructions/brandnana.md
# Then in any session, prompt:
> use brandnana to research nike.com`,
  };
</script>

<Section surface="white" padding="lg">
  <SectionHead
    kicker="§ 03 · drop in"
    title="Drop into your agent in 30 seconds."
    lede="brandnana ships an MCP server too. One config block — and your agent has 123 tools to fetch brands, search ads, crawl catalogs, generate briefs."
  />

  <div class="max-w-3xl min-w-0">
    <ChunkyBox surface="white" shadow="teal">
      <div class="flex border-b-2 border-border-ink bg-bg-cream-soft">
        {#each tabs as tab}
          <button
            type="button"
            class="flex-1 px-4 py-3 font-sans text-[13px] lowercase border-r-2 border-border-ink last:border-r-0 cursor-pointer transition-colors {active === tab ? 'bg-banana text-fg font-bold' : 'bg-transparent text-fg-muted hover:bg-bg-cream hover:text-fg'}"
            onclick={() => (active = tab)}
            aria-selected={active === tab}
          >
            {tab.replace("-", " ")}
          </button>
        {/each}
      </div>
      <pre class="m-0 p-6 font-mono text-[13px] leading-[1.75] text-fg whitespace-pre overflow-x-auto bg-white">{snippets[active]}</pre>
    </ChunkyBox>
  </div>
</Section>
