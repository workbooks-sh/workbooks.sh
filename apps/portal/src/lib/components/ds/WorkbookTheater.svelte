<!--
  WorkbookTheater — embedded live-feeling brand book viewer with tabs.
  Static sample data (Nike). Demonstrates what a generated .workbook.html
  feels like to actually use, without loading a real workbook.
-->
<script lang="ts">
  const tabs = ["brand", "catalog", "competitors", "ads", "timeline"] as const;
  type Tab = (typeof tabs)[number];
  let active = $state<Tab>("brand");

  const palette = [
    { hex: "#111111", name: "off-black", role: "primary" },
    { hex: "#f5f5f5", name: "off-white", role: "secondary" },
    { hex: "#fa6400", name: "ember", role: "accent" },
    { hex: "#7be0d3", name: "ice", role: "accent" },
  ];

  const fonts = [
    { name: "Futura", weight: "Bold · Heavy", role: "display" },
    { name: "Inter", weight: "Regular · Medium", role: "body" },
    { name: "Arial", weight: "Bold", role: "fallback" },
  ];

  const products = [
    { name: "Air Zoom Pegasus 41", price: 140, color: "Black/White", category: "Running" },
    { name: "InfinityRN 4", price: 160, color: "Stadium Green", category: "Running" },
    { name: "Vomero 17", price: 150, color: "Sail/Cobalt", category: "Lifestyle" },
    { name: "Dunk Low Retro", price: 110, color: "Panda", category: "Lifestyle" },
    { name: "Air Max 1 '86 OG", price: 150, color: "Big Bubble", category: "Lifestyle" },
    { name: "Pegasus Trail 5", price: 140, color: "Mocha/Tour Yellow", category: "Trail" },
  ];

  const competitors = [
    { name: "adidas", domain: "adidas.com", ads: 142, share: "32%" },
    { name: "Asics", domain: "asics.com", ads: 38, share: "12%" },
    { name: "On Running", domain: "on.com", ads: 64, share: "18%" },
    { name: "Puma", domain: "puma.com", ads: 51, share: "14%" },
  ];

  const ads = [
    { headline: "Just do it. — Track Day 2025", platform: "Meta", cta: "Shop running" },
    { headline: "Move different.", platform: "TikTok", cta: "Watch reel" },
    { headline: "Built for tempo, made for miles", platform: "Google", cta: "Find a store" },
    { headline: "Cool down kit · drop 3", platform: "Meta", cta: "Shop" },
  ];

  const timeline = [
    { ts: "11:42", evt: "brand fetch", status: "ok", duration: "1.2s" },
    { ts: "11:43", evt: "ads search · meta", status: "ok", duration: "2.4s" },
    { ts: "11:43", evt: "ads search · tiktok", status: "ok", duration: "1.8s" },
    { ts: "11:43", evt: "ads search · google", status: "ok", duration: "2.1s" },
    { ts: "11:44", evt: "catalog crawl · 247 products", status: "ok", duration: "4.6s" },
    { ts: "11:44", evt: "design palette extract", status: "ok", duration: "0.8s" },
    { ts: "11:44", evt: "bundle workbook (3.2 MB)", status: "ok", duration: "0.4s" },
  ];
</script>

<div class="rounded-2xl bg-white shadow-[0_2px_4px_rgba(0,0,0,0.04),0_24px_48px_-20px_rgba(0,0,0,0.16)] ring-1 ring-line overflow-hidden">
  <!-- chrome -->
  <div class="flex items-center gap-2.5 px-5 py-3 bg-bg-soft border-b border-line text-[13px]">
    <span class="font-mono text-fg">nike.workbook.html</span>
    <span class="text-fg-subtle">·</span>
    <span class="text-fg-muted text-[12px]">3.2 MB · offline-ready</span>
  </div>

  <!-- tabs -->
  <div class="flex border-b border-line px-3 overflow-x-auto">
    {#each tabs as t}
      <button
        type="button"
        onclick={() => (active = t)}
        class="px-3 py-2.5 text-[13px] -mb-px border-b-2 transition-colors whitespace-nowrap {active === t
          ? 'text-fg border-banana font-medium'
          : 'text-fg-muted border-transparent hover:text-fg hover:border-line-strong'}"
      >
        {t}
      </button>
    {/each}
  </div>

  <!-- body -->
  <div class="px-5 py-6 md:px-7 md:py-7 min-h-[280px]">
    {#if active === "brand"}
      <div class="grid grid-cols-1 md:grid-cols-[1fr_auto] gap-7 items-start">
        <div class="min-w-0">
          <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-2">brand identity</div>
          <div class="font-serif text-2xl text-fg mb-1">Nike</div>
          <div class="text-fg-muted text-[13px] mb-5">
            Bold, declarative, athletic. Voice that turns instruction into manifesto.
            Sells aspiration as much as product.
          </div>
          <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-2">palette</div>
          <div class="flex gap-2 mb-5">
            {#each palette as c}
              <div class="flex flex-col items-center">
                <div class="w-12 h-12 rounded-lg ring-1 ring-line" style="background: {c.hex}"></div>
                <div class="text-[10px] font-mono text-fg-muted mt-1">{c.hex}</div>
              </div>
            {/each}
          </div>
          <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-2">type</div>
          <div class="space-y-1.5">
            {#each fonts as f}
              <div class="flex items-baseline justify-between text-[13px]">
                <span class="text-fg" style="font-family: {f.name}, sans-serif">{f.name}</span>
                <span class="text-fg-muted text-[11px]">{f.weight} · {f.role}</span>
              </div>
            {/each}
          </div>
        </div>
        <!-- logo card -->
        <div class="rounded-xl bg-fg w-44 h-44 flex items-center justify-center">
          <svg width="120" height="44" viewBox="0 0 120 44" fill="white" aria-hidden="true">
            <path d="M104 18 C 82 32, 36 42, 12 32 C 36 38, 86 28, 116 8 L 104 18 Z"/>
          </svg>
        </div>
      </div>
    {:else if active === "catalog"}
      <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-3">247 products · 32 categories · sample</div>
      <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3">
        {#each products as p}
          <div class="rounded-xl bg-bg-soft p-4 hover:bg-banana-soft transition-colors cursor-default">
            <div class="text-[13px] text-fg mb-0.5 font-medium">{p.name}</div>
            <div class="text-[11px] text-fg-muted mb-2">{p.category} · {p.color}</div>
            <div class="font-mono text-[13px] text-fg">${p.price}</div>
          </div>
        {/each}
      </div>
    {:else if active === "competitors"}
      <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-3">4 competitors · 295 ads aggregated</div>
      <div class="divide-y divide-line">
        {#each competitors as c}
          <div class="flex items-center justify-between py-3 text-[14px]">
            <div>
              <div class="text-fg font-medium">{c.name}</div>
              <div class="text-fg-muted text-[12px]">{c.domain}</div>
            </div>
            <div class="text-right">
              <div class="text-fg font-mono">{c.ads}</div>
              <div class="text-fg-muted text-[11px]">{c.share} ad share</div>
            </div>
          </div>
        {/each}
      </div>
    {:else if active === "ads"}
      <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-3">295 captures · meta · tiktok · google</div>
      <div class="space-y-2">
        {#each ads as ad}
          <div class="flex items-center gap-3 rounded-xl bg-bg-soft hover:bg-blue-soft transition-colors px-4 py-3">
            <div class="w-10 h-10 rounded-lg bg-fg shrink-0 flex items-center justify-center text-white text-[10px] font-mono uppercase">{ad.platform[0]}</div>
            <div class="flex-1 min-w-0">
              <div class="text-fg text-[13px] truncate">"{ad.headline}"</div>
              <div class="text-fg-muted text-[11px]">{ad.platform} · CTA: {ad.cta}</div>
            </div>
          </div>
        {/each}
      </div>
    {:else if active === "timeline"}
      <div class="text-fg-muted text-[11px] uppercase tracking-wider mb-3">capture log · 11:42–11:44 · 13.3s total</div>
      <div class="font-mono text-[12px] space-y-1.5">
        {#each timeline as row}
          <div class="grid grid-cols-[60px_1fr_80px_auto] gap-3 items-baseline">
            <span class="text-fg-subtle">{row.ts}</span>
            <span class="text-fg">{row.evt}</span>
            <span class="text-blue-deep">{row.status}</span>
            <span class="text-fg-muted">{row.duration}</span>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
