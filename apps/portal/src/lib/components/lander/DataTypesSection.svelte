<script lang="ts">
  const slices = [
    {
      key: "Brand identity",
      desc: "Logo (SVG + raster), primary + secondary palette, full font stack with weights and licensing, brand descriptors and voice notes, social handles.",
      source: "logo.dev · brandfetch · context.dev · font-face scrape",
      color: "yellow",
    },
    {
      key: "Product catalog",
      desc: "Every SKU on the storefront: title, price, currency, sizes, colorways, image URLs, stock status, materials, tags. Indexed by category, collection, color, price band.",
      source: "shopify · custom storefront crawler",
      color: "blue",
    },
    {
      key: "Competitor ads",
      desc: "Live ad-library captures from Meta, TikTok and Google. Headline, CTA, landing URL, first/last seen, media URL, plus LLM-tagged themes and emotion.",
      source: "meta ads library · tiktok creative center · google transparency",
      color: "yellow",
    },
    {
      key: "Design palette",
      desc: "Computed dominant colors from logo + screenshot + product imagery. Useable as CSS custom properties for downstream generation.",
      source: "image quantization · llm post-pass",
      color: "blue",
    },
    {
      key: "Creative briefs",
      desc: "On-demand strategy briefs: positioning, tone, key message, differentiation, visual direction. Composes brand + competitors + your prompt.",
      source: "gemini-3-pro · with brand book as context",
      color: "yellow",
    },
    {
      key: "Capture timeline",
      desc: "Append-only log of every verb run, with status, duration, vendor cost and customer charge. Audit trail you can hand to finance.",
      source: "internal event log",
      color: "blue",
    },
  ] as const;
</script>

<section class="bg-white border-t border-line">
  <div class="max-w-6xl mx-auto px-6 md:px-8 py-16 md:py-20">
    <div class="max-w-2xl mb-10">
      <span class="text-[12px] text-blue-deep bg-blue-soft px-2.5 py-1 rounded-full">data inside</span>
      <h2 class="font-serif text-[32px] md:text-[44px] leading-[1.1] tracking-[-0.02em] text-fg mt-4 mb-3">
        Six slices. One file.
      </h2>
      <p class="text-[15px] md:text-[16px] text-fg-soft leading-relaxed">
        Each slice is a structured org-mode document. Query any of them from the
        CLI or open the workbook in a browser. Nothing is locked behind a vendor.
      </p>
    </div>

    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 md:gap-7">
      {#each slices as s}
        <div class="flex gap-4">
          <div
            class="shrink-0 w-1 rounded-full"
            style="background: {s.color === 'yellow' ? '#f0c040' : '#2c5fb5'}"
          ></div>
          <div class="min-w-0">
            <h3 class="font-serif text-[20px] text-fg mb-1.5">{s.key}</h3>
            <p class="text-[14px] text-fg-soft leading-relaxed mb-1.5">{s.desc}</p>
            <p class="text-[11.5px] font-mono text-fg-subtle">{s.source}</p>
          </div>
        </div>
      {/each}
    </div>
  </div>
</section>
