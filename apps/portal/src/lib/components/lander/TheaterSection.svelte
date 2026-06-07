<script lang="ts">
  import WorkbookTheater from "../ds/WorkbookTheater.svelte";
  import FileTree from "../ds/FileTree.svelte";

  const tree = {
    name: "nike",
    kind: "dir" as const,
    children: [
      {
        name: "SKILL.md",
        kind: "file" as const,
        size: "1.7 KB",
        note: "Discovery + progressive disclosure entry. Claude reads this first.",
      },
      {
        name: "nike.workbook.html",
        kind: "dir" as const,
        size: "3.2 MB",
        children: [
          { name: "brand.org", kind: "file" as const, size: "4.1 KB", note: "identity · palette · fonts · voice" },
          {
            name: "competitors/",
            kind: "dir" as const,
            children: [
              { name: "adidas.org", kind: "file" as const, size: "8.2 KB" },
              { name: "asics.org", kind: "file" as const, size: "5.6 KB" },
              { name: "puma.org", kind: "file" as const, size: "6.0 KB" },
              { name: "on-running.org", kind: "file" as const, size: "5.9 KB" },
            ],
          },
          {
            name: "catalog/",
            kind: "dir" as const,
            children: [
              { name: "products.org", kind: "file" as const, size: "182 KB" },
              { name: "categories.org", kind: "file" as const, size: "3.4 KB" },
              { name: "images.manifest.json", kind: "file" as const, size: "44 KB" },
            ],
          },
          {
            name: "ads/",
            kind: "dir" as const,
            children: [
              { name: "manifest.json", kind: "file" as const, size: "62 KB" },
              { name: "thumbs.manifest.json", kind: "file" as const, size: "18 KB" },
            ],
          },
          { name: "timeline.org", kind: "file" as const, size: "2.1 KB" },
        ],
      },
      { name: "query.md", kind: "file" as const, size: "1.2 KB", note: "OQL examples scoped to this brand" },
    ],
  };
</script>

<section class="bg-bg-soft border-t border-line">
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-16 md:py-20">
    <div class="max-w-2xl mb-10">
      <span class="text-[12px] text-blue-deep bg-blue-soft px-2.5 py-1 rounded-full">deliverable</span>
      <h2 class="font-serif text-[32px] md:text-[44px] leading-[1.1] tracking-[-0.02em] text-fg mt-4 mb-3">
        What you actually get.
      </h2>
      <p class="text-[15px] md:text-[16px] text-fg-soft leading-relaxed">
        A single offline-ready HTML file. Opens in any browser. Queryable from the
        CLI. Lives inside <code class="font-mono text-[13px] bg-bg-tint px-1.5 py-0.5 rounded text-fg-soft">~/.claude/skills/brands/</code>
        so Claude finds it the next time you ask about that brand.
      </p>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-[1.7fr_1fr] gap-5 lg:gap-6">
      <div class="min-w-0">
        <WorkbookTheater />
      </div>
      <div class="min-w-0">
        <FileTree
          root={tree}
          initiallyOpen={["nike", "nike/nike.workbook.html", "nike/nike.workbook.html/catalog/"]}
        />
      </div>
    </div>
  </div>
</section>
