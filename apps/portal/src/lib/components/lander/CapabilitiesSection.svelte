<script lang="ts">
  import Section from "../ds/Section.svelte";
  import SectionHead from "../ds/SectionHead.svelte";
  import CapabilityCard from "../ds/CapabilityCard.svelte";

  const capabilities = [
    {
      n: "01",
      title: "brand fetch",
      blurb: "Pull live brand identity — logos, palette, font stack, voice, social handles.",
      cmd: "brandnana brand fetch nike.com",
      out: `✓ primary: #111  ·  secondary: #f5f5f5
✓ fonts: Futura, Inter, Arial
✓ logo: nike-swoosh.svg (24 KB)
✓ tone: bold, declarative, athletic`,
      color: "cherry" as const,
      icon: "logo" as const,
    },
    {
      n: "02",
      title: "ads search",
      blurb: "Scrape live creative from any brand's ad library — Meta, TikTok, Google.",
      cmd: "brandnana ads search --domain=adidas.com",
      out: `› meta:    142 ads  (28 active)
› tiktok:   38 ads  (6 promoted)
› google:   54 ads  (18 with video)
› themes:  return-to-running · trail · y2k`,
      color: "teal" as const,
      icon: "megaphone" as const,
    },
    {
      n: "03",
      title: "catalog crawl",
      blurb: "Extract a structured product catalog from any storefront — Shopify, custom, anywhere.",
      cmd: "brandnana catalog crawl glossier.com",
      out: `▸ products: 247 (32 categories)
▸ images:   1,184 (avg 3.6mb)
▸ price band: $14 — $98
▸ variants: 812 · colors: 42`,
      color: "olive" as const,
      icon: "catalog" as const,
    },
    {
      n: "04",
      title: "brief generate",
      blurb: "Composable creative brief — pulls in brand context + a prompt, drops a tight one-pager.",
      cmd: `brandnana brief generate "summer launch"`,
      out: `✓ strategy:  position vs Nike Air Max
✓ tone:       playful, surprising
✓ assets:    use SS25 palette
✓ word count: 412 · reading: 1m48s`,
      color: "rust" as const,
      icon: "brief" as const,
    },
    {
      n: "05",
      title: "design palette",
      blurb: "Extract a design system palette from any logo, image, or whole brand.",
      cmd: "brandnana design palette logo.png",
      out: `● #f0c040  banana       (primary)
● #d65a3a  cherry       (secondary)
● #1f1a14  ink          (text)
● #fbf4e4  parchment    (background)`,
      color: "banana" as const,
      icon: "palette" as const,
    },
    {
      n: "06",
      title: "mcp ready",
      blurb: "Drop into Claude Code, Codex, Cursor as a native MCP server. 123 tools, zero config.",
      cmd: "brandnana mcp",
      out: `[brandnana] mcp ready on stdio
  ➜ 123 tools exposed
  ➜ skill: ~/.claude/skills/brandnana/
  ➜ try:  use brandnana to research nike.com`,
      color: "plum" as const,
      icon: "wires" as const,
    },
  ];
</script>

<Section surface="cream" padding="lg">
  <SectionHead
    kicker="§ 02 · six verbs"
    title="Six verbs. One CLI. 123 MCP tools."
    lede="Each verb returns clean JSON if you call it raw — or feeds straight into the brand book when you call brandnana book."
  />

  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
    {#each capabilities as cap}
      <CapabilityCard {...cap} />
    {/each}
  </div>
</Section>
