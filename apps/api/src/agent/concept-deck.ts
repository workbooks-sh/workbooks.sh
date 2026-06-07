// Concept-deck composer — orchestrates evidence gathering + image generation
// + workbook bundling for marketing-task intents:
//   - static_ad      → 3 static ad variations (1:1, 4:5, 9:16)
//   - landing_page   → hero image + 3-section concept page
//   - carousel       → 5-frame IG carousel
//   - product_concept→ invented product render + supporting context
//   - campaign_brief → full mini-campaign (4 ads + brief)
//
// All output as a brandnana workbook (.html). Uses the same Presentation
// runtime as the brand-book deck; just a different slide template.

import type { Bindings } from "../env.js";
import { scrapeHomepageEvidence } from "./homepage-scrape.js";
import { fetchLogo } from "./logo-fetch.js";
import { homepageScreenshot } from "./screenshot-fetch.js";
import { curate } from "./curate.js";
import { generateImage, type GeneratedImage, uploadImageToR2 } from "./image-gen.js";
import { chatJson } from "../ai.js";
import { bundleWorkbook } from "../book/book-bundle.js";
import { composeBookData } from "../book/presentation-shell.js";
import type { SeedBrand } from "./seed-brands.js";

export type ConceptIntent = "static_ad" | "landing_page" | "carousel" | "product_concept" | "campaign_brief";

export interface ConceptResult {
  ok: boolean;
  slug: string;
  intent: ConceptIntent;
  brief: string;
  /** Public URLs for each generated image. */
  image_urls: string[];
  /** Total cost across image-gen calls. */
  cost_usd: number;
  /** Concept deck HTML (also stored in R2). */
  workbook_url: string;
  workbook_bytes: number;
  /** Timeline of every verb run, for debugging. */
  timeline: Array<{ verb: string; status: string; ms: number; summary?: string }>;
  /** Cerebras-written narrative for the concept (cover headline, voice, etc). */
  narrative: {
    cover_headline: string;
    cover_subhead: string;
    image_prompts: string[];
  };
}

interface ConceptPlanResponse {
  cover_headline?: string;
  cover_subhead?: string;
  /** One prompt per image to generate. Length matches the intent's expected count. */
  image_prompts?: string[];
  /** Per-image copy (headline + supporting line). */
  image_copy?: Array<{ headline: string; sub?: string }>;
  /** Optional: voice/tone notes for the deck. */
  voice_notes?: string[];
}

const COUNTS: Record<ConceptIntent, { images: number; aspect: string[] }> = {
  static_ad: { images: 3, aspect: ["1:1", "4:5", "9:16"] },
  landing_page: { images: 3, aspect: ["16:9", "1:1", "4:5"] },
  carousel: { images: 5, aspect: ["4:5", "4:5", "4:5", "4:5", "4:5"] },
  product_concept: { images: 2, aspect: ["1:1", "1:1"] },
  campaign_brief: { images: 4, aspect: ["1:1", "4:5", "9:16", "16:9"] },
};

const INTENT_INSTRUCTIONS: Record<ConceptIntent, string> = {
  static_ad: "3 static ad variations (square, portrait, story). Each with bold headline + 1-line sub.",
  landing_page: "Landing-page concept: hero image + 2 section images. Hero gets the campaign headline; section images each get a feature headline.",
  carousel: "5-frame Instagram carousel telling one cohesive story. Frame 1 hook, frames 2-4 build, frame 5 CTA.",
  product_concept: "Invent a new product variation that fits the brand. Render 2 hero shots (front + lifestyle).",
  campaign_brief: "4 ads across formats (square / portrait / story / banner). Each anchored to one campaign theme.",
};

// ── Compose ──────────────────────────────────────────────────────────────────

export async function composeConcept(args: {
  env: Bindings;
  intent: ConceptIntent;
  domain: string;
  brief: string;
  brandName?: string;
}): Promise<ConceptResult> {
  const { env, intent, domain, brief } = args;
  const slug = `${domain.split(".")[0]}-${intent}-${Date.now().toString(36)}`;
  const timeline: ConceptResult["timeline"] = [];
  let totalCost = 0;

  const stamp = <T>(verb: string, t0: number, status: string, summary: string, val: T): T => {
    timeline.push({ verb, status, ms: Date.now() - t0, summary });
    return val;
  };

  // 1. Gather brand evidence in parallel: scrape + logo cascade + screenshot.
  const t1 = Date.now();
  const [evidence, logoOutcome] = await Promise.all([
    scrapeHomepageEvidence(domain, { browser: env.BROWSER }),
    fetchLogo(domain, { logoDevToken: env.CONTEXT_DEV_API_KEY }),
  ]);
  const screenshot = homepageScreenshot(domain, { width: 1280, height: 800 });
  const brandName = args.brandName ?? evidence.meta.title?.split(/[-|·]/)[0]?.trim() ?? domain.split(".")[0]!;
  stamp(
    "agent.scrape",
    t1,
    evidence.fetch_error ? "error" : "ok",
    `vars=${evidence.brand_css_vars.length} colors=${evidence.colors_ranked.length} fonts=${evidence.fonts.length}`,
    null,
  );

  // 2. Cerebras plans the concept narrative + image prompts.
  const planT0 = Date.now();
  let plan: ConceptPlanResponse;
  try {
    plan = await planConcept({
      apiKey: env.CEREBRAS_API_KEY ?? "",
      intent,
      brandName,
      domain,
      brief,
      evidence,
    });
    stamp("agent.plan_concept", planT0, "ok", `${plan.image_prompts?.length ?? 0} prompts written`, null);
  } catch (e) {
    plan = fallbackPlan(intent, brandName, brief);
    stamp("agent.plan_concept", planT0, "fallback", (e as Error).message, null);
  }

  const cfg = COUNTS[intent];
  const prompts = (plan.image_prompts ?? []).slice(0, cfg.images);
  while (prompts.length < cfg.images) prompts.push(plan.cover_headline ?? brief);

  // 3. Generate images in parallel — each conditioned on the homepage screenshot
  //    as a brand-vibe reference, so visual identity carries through.
  const imgT0 = Date.now();
  const generations = await Promise.all(
    prompts.map((p, i) =>
      generateImage(env.OPENROUTER_API_KEY ?? "", {
        prompt: brandFlavored(p, brandName, evidence),
        referenceImageUrl: screenshot.url,
        aspectRatio: cfg.aspect[i] ?? "1:1",
      }).catch((e) => ({ error: (e as Error).message })),
    ),
  );
  const successfulImages = generations.filter((g): g is GeneratedImage => "bytes" in g);
  totalCost += successfulImages.reduce((s, g) => s + g.cost_usd, 0);
  stamp(
    "agent.image_gen",
    imgT0,
    successfulImages.length === cfg.images ? "ok" : "partial",
    `${successfulImages.length}/${cfg.images} images · $${totalCost.toFixed(4)}`,
    null,
  );

  // 4. Upload images to R2 and collect public URLs.
  const uploadT0 = Date.now();
  const imageUrls: string[] = [];
  for (let i = 0; i < successfulImages.length; i++) {
    const img = successfulImages[i]!;
    const ext = img.mime === "image/png" ? "png" : img.mime === "image/jpeg" ? "jpg" : "bin";
    const key = `concept-images/${slug}/${i}.${ext}`;
    try {
      const url = await uploadImageToR2(env.ASSETS, key, img);
      imageUrls.push(url);
    } catch (e) {
      // Skip failed upload but continue
    }
  }
  stamp("agent.upload_r2", uploadT0, imageUrls.length ? "ok" : "error", `${imageUrls.length} uploaded`, null);

  // 5. Build a concept-flavored workbook deck. We re-use the brand-book
  //    Presentation, but with concept-specific slides via curate.
  const deckT0 = Date.now();
  const concept = composeConceptHtml({
    intent,
    slug,
    brandName,
    domain,
    brief,
    cover_headline: plan.cover_headline ?? brief,
    cover_subhead: plan.cover_subhead ?? `${intent.replace(/_/g, " ")} for ${brandName}`,
    image_urls: imageUrls,
    image_copy: plan.image_copy ?? [],
    voice_notes: plan.voice_notes ?? [],
    timeline,
    evidence,
    logoUrl: logoOutcome.result?.url ?? "",
  });

  // 6. Upload deck to public R2 (read-only).
  const deckKey = `brand-books/public/${slug}.html`;
  const deckBytes = new TextEncoder().encode(concept);
  try {
    await env.ASSETS.put(deckKey, deckBytes, {
      httpMetadata: { contentType: "text/html; charset=utf-8" },
      customMetadata: {
        slug,
        kind: "concept",
        intent,
        brand_name: brandName,
        domain,
        brief: brief.slice(0, 200),
        generated_at: new Date().toISOString(),
        cost_usd: String(totalCost),
        image_count: String(imageUrls.length),
      },
    });
  } catch (e) {
    stamp("agent.deck_upload", deckT0, "error", (e as Error).message, null);
  }
  stamp("agent.deck_upload", deckT0, "ok", `${deckBytes.length}B deck`, null);

  return {
    ok: imageUrls.length > 0,
    slug,
    intent,
    brief,
    image_urls: imageUrls,
    cost_usd: totalCost,
    workbook_url: `https://api.brandnana.net/books/${slug}.html`,
    workbook_bytes: deckBytes.length,
    timeline,
    narrative: {
      cover_headline: plan.cover_headline ?? brief,
      cover_subhead: plan.cover_subhead ?? "",
      image_prompts: prompts,
    },
  };
}

// ── Planning ─────────────────────────────────────────────────────────────────

async function planConcept(args: {
  apiKey: string;
  intent: ConceptIntent;
  brandName: string;
  domain: string;
  brief: string;
  evidence: Awaited<ReturnType<typeof scrapeHomepageEvidence>>;
}): Promise<ConceptPlanResponse> {
  const SYSTEM = `You are a creative director planning ${args.intent.replace(/_/g, " ")} for a brand.

${INTENT_INSTRUCTIONS[args.intent]}

The brand's observed visual identity (from live homepage scrape):
${args.evidence.fetch_error ? "  (homepage fetch failed — work from brief alone)" : `
  Title: ${args.evidence.meta.title ?? "?"}
  Description: ${args.evidence.meta.description ?? "?"}
  Brand CSS vars: ${args.evidence.brand_css_vars.slice(0, 10).map((v) => `${v.name}=${v.value}`).join(", ")}
  Dominant colors: ${args.evidence.colors_ranked.slice(0, 5).map((c) => c.hex).join(", ")}
  Fonts: ${args.evidence.fonts.slice(0, 4).map((f) => f.family).join(", ")}
`}

Write the creative brief AND ${COUNTS[args.intent].images} highly-specific image-generation prompts. Each prompt should:
  - Reference the brand's actual visual identity (colors above, type vibe)
  - Specify subject, composition, mood, lighting, props
  - Be visually concrete — an art director should read it and know exactly what to render
  - NOT contain the brand's logo or text overlays (we composite those separately)

Reply with ONLY this JSON, no markdown:
{
  "cover_headline": "<= 80 chars campaign headline",
  "cover_subhead":  "<= 120 chars supporting line",
  "image_prompts":  ["one detailed prompt per image"],
  "image_copy":     [{"headline": "<= 60 chars", "sub": "<= 100 chars"}],
  "voice_notes":    ["3-5 tone bullets, each <= 90 chars"]
}`;

  const { value } = await chatJson<ConceptPlanResponse>(args.apiKey, {
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: `Brand: ${args.brandName} (${args.domain})\n\nBrief: ${args.brief}` },
    ],
    temperature: 0.7,
    max_tokens: 4000,
  });
  return value;
}

function fallbackPlan(intent: ConceptIntent, brandName: string, brief: string): ConceptPlanResponse {
  const n = COUNTS[intent].images;
  return {
    cover_headline: brief.slice(0, 80),
    cover_subhead: `${intent.replace(/_/g, " ")} for ${brandName}`,
    image_prompts: Array.from({ length: n }, (_, i) => `${brief} — variation ${i + 1}, brand: ${brandName}`),
    image_copy: Array.from({ length: n }, () => ({ headline: brief.slice(0, 50) })),
    voice_notes: [],
  };
}

function brandFlavored(prompt: string, brand: string, ev: Awaited<ReturnType<typeof scrapeHomepageEvidence>>): string {
  const colors = ev.colors_ranked.slice(0, 3).map((c) => c.hex).join(", ");
  const fonts = ev.fonts.slice(0, 2).map((f) => f.family).join(" + ");
  const tail = [
    colors ? `brand palette: ${colors}` : "",
    fonts ? `type vibe: ${fonts}` : "",
  ].filter(Boolean).join(". ");
  return tail ? `${prompt}\n\n${tail}.` : prompt;
}

// ── Deck rendering ───────────────────────────────────────────────────────────
//
// Concept decks reuse the brand-book Presentation runtime but with a single
// "concept gallery" slide layout that grids the generated images with copy.
// Cheaper than a fully new template; visually focused on the IMAGES.

function composeConceptHtml(args: {
  intent: ConceptIntent;
  slug: string;
  brandName: string;
  domain: string;
  brief: string;
  cover_headline: string;
  cover_subhead: string;
  image_urls: string[];
  image_copy: Array<{ headline: string; sub?: string }>;
  voice_notes: string[];
  timeline: Array<{ verb: string; status: string; ms: number; summary?: string }>;
  evidence: Awaited<ReturnType<typeof scrapeHomepageEvidence>>;
  logoUrl: string;
}): string {
  const palette = args.evidence.colors_ranked.slice(0, 6).map((c) => ({ hex: c.hex }));
  const primary = palette[0]?.hex ?? "#111";
  const secondary = palette[1]?.hex ?? "#fff";
  const accent = palette[2]?.hex ?? "#1F6FEB";
  const font = args.evidence.fonts[0]?.family ?? "Inter";

  const intentLabel = args.intent.replace(/_/g, " ");
  const imagesGrid = args.image_urls
    .map((u, i) => {
      const copy: { headline?: string; sub?: string } = args.image_copy[i] ?? {};
      const hl = copy.headline ?? "";
      const sub = copy.sub ?? "";
      return `
        <figure class="concept-frame">
          <img src="${esc(u)}" alt="${esc(hl || args.cover_headline)}" loading="lazy">
          ${hl ? `<figcaption><div class="hl">${esc(hl)}</div>${sub ? `<div class="sub">${esc(sub)}</div>` : ""}</figcaption>` : ""}
        </figure>`;
    })
    .join("");

  const voiceList = args.voice_notes.length
    ? `<ul class="voice-list">${args.voice_notes.map((v) => `<li>${esc(v)}</li>`).join("")}</ul>`
    : "";

  const palettePills = palette.map((c) => `<span class="palette-pill" style="background:${esc(c.hex)}" title="${esc(c.hex)}"></span>`).join("");

  const timelineRows = args.timeline
    .map((t) => `<tr><td>${esc(t.verb)}</td><td>${esc(t.status)}</td><td>${t.ms}ms</td><td>${esc(t.summary ?? "")}</td></tr>`)
    .join("");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(args.brandName)} — ${esc(intentLabel)} concept</title>
<style>
  :root {
    --primary: ${esc(primary)};
    --secondary: ${esc(secondary)};
    --accent: ${esc(accent)};
    --font: "${esc(font)}", ui-sans-serif, system-ui, -apple-system, "Helvetica Neue", sans-serif;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: #08080a; color: #fff; font-family: var(--font); }
  .page { max-width: 1280px; margin: 0 auto; padding: clamp(20px, 4vw, 56px); }
  header { display: flex; align-items: baseline; justify-content: space-between; gap: 24px; margin-bottom: 40px; }
  header .left .eyebrow { font-size: 11px; letter-spacing: .18em; text-transform: uppercase; color: rgba(255,255,255,.55); }
  header .left h1 { font-size: clamp(28px, 4vw, 52px); font-weight: 600; margin: 6px 0 4px; letter-spacing: -0.01em; }
  header .left .sub { color: rgba(255,255,255,.7); font-size: 15px; max-width: 60ch; }
  header .right { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; }
  header .right .brand { font-size: 12px; color: rgba(255,255,255,.6); }
  header .right .palette { display: flex; gap: 4px; }
  .palette-pill { width: 16px; height: 16px; border-radius: 3px; display: inline-block; border: 1px solid rgba(255,255,255,.15); }
  .concept-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 18px; }
  .concept-frame { margin: 0; background: #111; border-radius: 10px; overflow: hidden; display: flex; flex-direction: column; }
  .concept-frame img { width: 100%; height: auto; display: block; aspect-ratio: 1/1; object-fit: cover; }
  .concept-frame figcaption { padding: 12px 14px; }
  .concept-frame .hl { font-size: 14px; font-weight: 500; }
  .concept-frame .sub { font-size: 12px; color: rgba(255,255,255,.6); margin-top: 4px; }
  .voice-section { margin-top: 56px; }
  .voice-section h2 { font-size: 13px; letter-spacing: .18em; text-transform: uppercase; color: rgba(255,255,255,.55); font-weight: 500; }
  .voice-list { list-style: none; padding: 0; margin: 16px 0 0; columns: 2; column-gap: 24px; }
  .voice-list li { padding: 8px 0; font-size: 14px; color: rgba(255,255,255,.85); border-bottom: 1px solid rgba(255,255,255,.08); break-inside: avoid; }
  .meta-section { margin-top: 56px; padding-top: 24px; border-top: 1px solid rgba(255,255,255,.08); display: grid; grid-template-columns: 1fr 2fr; gap: 32px; font-size: 12px; color: rgba(255,255,255,.55); }
  .meta-section table { width: 100%; border-collapse: collapse; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; }
  .meta-section td { padding: 4px 8px; border-bottom: 1px solid rgba(255,255,255,.05); vertical-align: top; }
  @media (max-width: 700px) { .voice-list { columns: 1; } .meta-section { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="page">
  <header>
    <div class="left">
      <div class="eyebrow">${esc(intentLabel)} concept</div>
      <h1>${esc(args.cover_headline)}</h1>
      <div class="sub">${esc(args.cover_subhead)}</div>
    </div>
    <div class="right">
      <div class="brand">${esc(args.brandName)} · ${esc(args.domain)}</div>
      <div class="palette">${palettePills}</div>
    </div>
  </header>
  <main>
    <section class="concept-grid">${imagesGrid}</section>
    ${voiceList ? `<section class="voice-section"><h2>Voice + tone</h2>${voiceList}</section>` : ""}
    <section class="meta-section">
      <div>
        <div style="font-size: 11px; letter-spacing: .12em; text-transform: uppercase; margin-bottom: 8px;">Brief</div>
        <div style="color: rgba(255,255,255,.8); font-size: 13px;">${esc(args.brief)}</div>
      </div>
      <div>
        <div style="font-size: 11px; letter-spacing: .12em; text-transform: uppercase; margin-bottom: 8px;">Verb trace</div>
        <table>${timelineRows}</table>
      </div>
    </section>
  </main>
</div>
<script id="concept-spec" type="application/json">${JSON.stringify({
    slug: args.slug,
    intent: args.intent,
    brand: { name: args.brandName, domain: args.domain },
    brief: args.brief,
    image_urls: args.image_urls,
    cover_headline: args.cover_headline,
    cover_subhead: args.cover_subhead,
    palette: palette.map((c) => c.hex),
    timeline: args.timeline,
  })}</script>
</body>
</html>`;
}

function esc(s: string): string {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
