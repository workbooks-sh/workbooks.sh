<script lang="ts">
  import Section from "../ds/Section.svelte";
  import SectionHead from "../ds/SectionHead.svelte";
  import Terminal from "../ds/Terminal.svelte";
</script>

<Section surface="white" padding="lg">
  <SectionHead
    kicker="§ 01 · what you get"
    title="A single workbook your agent can read."
    lede="Drops at ~/.claude/skills/brands/<slug>/ with a SKILL.md so Claude knows when to use it. Everything else lives inside one offline-capable .html."
  />

  <div class="grid grid-cols-1 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)] gap-8 items-start">
    <div class="min-w-0">
      <Terminal shadow="olive">~/.claude/skills/brands/nike/
├── <span class="text-banana font-bold">SKILL.md</span>            <span class="text-fg-muted">→ tells Claude when to use this skill</span>
├── <span style="color: #ff8a5b;" class="font-bold">nike.html</span>  <span class="text-fg-muted">→ single-file, gzip-packed, ~3 MB</span>
│   ├── brand.org      <span class="text-fg-muted">  · identity, palette, fonts, voice</span>
│   ├── competitors/   <span class="text-fg-muted">  · adidas, puma, asics — ad breakdowns</span>
│   ├── catalog/       <span class="text-fg-muted">  · products by category / color / price</span>
│   ├── ads/           <span class="text-fg-muted">  · 142 ad captures (streamed or embedded)</span>
│   └── timeline.org   <span class="text-fg-muted">  · what was captured, when, by who</span>
└── query.md           <span class="text-fg-muted">→ OQL examples, scoped to this brand</span>
      </Terminal>
    </div>

    <dl class="flex flex-col gap-3 min-w-0">
      {#each [
        { k: "format", v: "single-file HTML · WASM runtime baked in" },
        { k: "data", v: "org-mode tree · queryable via OQL" },
        { k: "media", v: "embedded (offline) or R2-linked (slim)" },
        { k: "install", v: "drops into ~/.claude/skills/brands/" },
        { k: "query", v: "brandnana book query nike '(under \"Catalog/by-color/Black\")'" },
      ] as row}
        <div class="grid grid-cols-[100px_1fr] gap-3 pb-3 border-b border-dotted border-border-strong last:border-b-0">
          <dt class="font-mono text-[11px] uppercase tracking-[0.08em] text-fg-muted">{row.k}</dt>
          <dd class="text-[13px] text-fg leading-relaxed font-mono break-words">{row.v}</dd>
        </div>
      {/each}
    </dl>
  </div>
</Section>
