// Plan executor — takes the planner's Plan, runs research verbs in parallel,
// generates the planned images in parallel, then composes either a document
// or presentation workbook from the outline.
//
// No fixed intents. The plan describes what to do; this just dispatches.

import type { Bindings } from "../env.js";
import type { Plan, PlanResearchStep } from "./planner.js";
import { scrapeHomepageEvidence, type HomepageEvidence } from "./homepage-scrape.js";
import { fetchLogo, type LogoResult } from "./logo-fetch.js";
import { homepageScreenshot } from "./screenshot-fetch.js";
import { verifyBrand } from "./verify-brand.js";
import { harvestMultiPage } from "./multipage-text.js";
import { generateImage, uploadImageToR2, type GeneratedImage } from "./image-gen.js";
import { renderDocument, type DocumentData, type DocumentSection, type DocumentBlock } from "../book/document-shell.js";
import { renderPresentation, type BookData } from "../book/presentation-shell.js";
import { pickThemeColors } from "./contrast.js";
import { strategize, type Strategy } from "./strategist.js";
import { composeOutline, type Composition } from "./composer.js";
import { writeAllSections, type WrittenSection } from "./writer.js";

export interface ResearchOutcome {
  step: PlanResearchStep;
  status: "ok" | "error" | "skipped";
  duration_ms: number;
  /** Verb-specific payload — see runResearchStep for shape per verb. */
  payload?: unknown;
  error?: string;
}

export interface ExecutionResult {
  plan: Plan;
  research: ResearchOutcome[];
  /** The thinking layer — agent's thesis, insights, narrative arc. */
  strategy?: Strategy;
  /** The post-strategy outline + image plan + voice. */
  composition?: Composition;
  images: Array<{ ref: string; url?: string; error?: string; cost_usd: number; latency_ms: number }>;
  /** Per-section bodies written by the writer. */
  sections?: WrittenSection[];
  workbook_url: string;
  workbook_bytes: number;
  slug: string;
  total_cost_usd: number;
  total_latency_ms: number;
  timeline: Array<{ verb: string; status: string; duration_ms: number; summary?: string }>;
}

// ── Research dispatcher ──────────────────────────────────────────────────────

async function runResearchStep(env: Bindings, step: PlanResearchStep): Promise<ResearchOutcome> {
  const t0 = Date.now();
  const args = step.args as any;
  const make = (status: ResearchOutcome["status"], payload?: unknown, error?: string): ResearchOutcome =>
    ({ step, status, duration_ms: Date.now() - t0, payload, error });

  try {
    switch (step.verb) {
      case "scrape": {
        const r = await scrapeHomepageEvidence(args.domain, { browser: env.BROWSER });
        return make(r.fetch_error ? "error" : "ok", r, r.fetch_error);
      }
      case "multipage": {
        const r = await harvestMultiPage({ domain: args.domain, browser: env.BROWSER });
        return make("ok", r);
      }
      case "verify_brand": {
        const r = await verifyBrand({ domain: args.domain, expected_name: args.expected_brand ?? args.expected_name ?? args.domain });
        return make("ok", r);
      }
      case "logo": {
        const r = await fetchLogo(args.domain, { logoDevToken: env.CONTEXT_DEV_API_KEY });
        return make(r.result ? "ok" : "error", r, r.result ? undefined : "logo cascade exhausted");
      }
      case "screenshot": {
        const r = homepageScreenshot(args.domain, { width: args.width ?? 1280, height: args.height ?? 800 });
        return make("ok", r);
      }
      case "competitor": {
        const [scr, lg, ver] = await Promise.all([
          scrapeHomepageEvidence(args.competitor_domain, { browser: env.BROWSER }),
          fetchLogo(args.competitor_domain, { logoDevToken: env.CONTEXT_DEV_API_KEY }),
          verifyBrand({ domain: args.competitor_domain, expected_name: args.competitor_domain.split(".")[0]! }),
        ]);
        return make("ok", { evidence: scr, logo: lg, verify: ver });
      }
      case "ads_search":
      case "catalog_crawl":
        // Not yet wired in vendor pipeline for ad-hoc domains; mark as
        // skipped so the renderer knows to omit the data widget.
        return make("skipped", null, "verb not yet wired for ad-hoc domains");
      default:
        return make("skipped", null, `unknown verb: ${step.verb}`);
    }
  } catch (e) {
    return make("error", null, (e as Error).message);
  }
}

// ── Image generation ─────────────────────────────────────────────────────────

async function generatePlanImages(
  env: Bindings,
  plan: Plan,
  research: ResearchOutcome[],
  slug: string,
): Promise<ExecutionResult["images"]> {
  // Use the FIRST scrape result's domain as the "primary brand" — its
  // screenshot URL is what we condition image-gen on.
  const primaryScrape = research.find((r) => r.step.verb === "scrape" && r.status === "ok");
  const primaryDomain = primaryScrape?.step.args?.domain as string | undefined;
  const evidence = primaryScrape?.payload as HomepageEvidence | undefined;

  const results = await Promise.allSettled(
    plan.images.map(async (img, i) => {
      const t0 = Date.now();
      const refImg = img.use_brand_screenshot && primaryDomain
        ? homepageScreenshot(primaryDomain, { width: 1280, height: 800 }).url
        : undefined;
      const brandFlavor = brandFlavorForPrompt(evidence);
      const fullPrompt = brandFlavor ? `${img.prompt}\n\n${brandFlavor}` : img.prompt;
      try {
        const gen = await generateImage(env.OPENROUTER_API_KEY ?? "", {
          prompt: fullPrompt,
          referenceImageUrl: refImg,
          aspectRatio: img.aspect_ratio,
        });
        const ext = gen.mime === "image/png" ? "png" : gen.mime === "image/jpeg" ? "jpg" : "bin";
        const key = `concept-images/${slug}/${img.ref}-${i}.${ext}`;
        const url = await uploadImageToR2(env.ASSETS, key, gen);
        return { ref: img.ref, url, cost_usd: gen.cost_usd, latency_ms: Date.now() - t0 };
      } catch (e) {
        return { ref: img.ref, error: (e as Error).message, cost_usd: 0, latency_ms: Date.now() - t0 };
      }
    }),
  );
  return results.map((r) => (r.status === "fulfilled" ? r.value : { ref: "?", error: String(r.reason), cost_usd: 0, latency_ms: 0 }));
}

function brandFlavorForPrompt(ev?: HomepageEvidence): string {
  if (!ev) return "";
  const colors = ev.colors_ranked.slice(0, 3).map((c) => c.hex).join(", ");
  const fonts = ev.fonts.slice(0, 2).map((f) => f.family).join(" + ");
  return [colors && `brand palette: ${colors}`, fonts && `type vibe: ${fonts}`].filter(Boolean).join(". ");
}

// ── Composition ──────────────────────────────────────────────────────────────

function findResearchByVerb(research: ResearchOutcome[], verb: string, domain?: string): ResearchOutcome | undefined {
  return research.find((r) => r.step.verb === verb && r.status === "ok" && (!domain || (r.step.args as any).domain === domain));
}

export async function executePlan(
  env: Bindings,
  plan: Plan,
  userQuery: string,
  opts: { presetSlug?: string } = {},
): Promise<ExecutionResult> {
  const t0 = Date.now();
  const slug = opts.presetSlug ?? `${(plan.domains[0] ?? "wb").replace(/\./g, "-")}-${plan.format}-${Date.now().toString(36)}`;
  const keys = { openrouter: env.OPENROUTER_API_KEY, cerebras: env.CEREBRAS_API_KEY };

  // 1. RESEARCH — fetch in parallel.
  const research = await Promise.all(plan.research.map((s) => runResearchStep(env, s)));
  const compactResearch = research
    .filter((r) => r.status === "ok")
    .map((r) => ({ verb: r.step.verb, args: r.step.args, signal: summarizeResearch(r), payload: r.payload }));

  // 2. STRATEGIZE — agent reads the research and forms a thesis + insights
  //    + narrative arc. This is the "thinking" layer.
  const stratT0 = Date.now();
  let strategy: Strategy | undefined;
  try {
    const s = await strategize({ keys, userQuery, research, currentFormat: plan.format });
    strategy = s.strategy;
  } catch (e) {
    // Strategy is critical; if it fails, fall back to a thin stand-in.
    strategy = {
      thesis: plan.understood_as,
      stakes: "(strategist failed — using planner's understanding as fallback)",
      insights: [],
      narrative_arc: "(no arc — strategist unavailable)",
      gaps: [`strategist error: ${(e as Error).message}`],
      confidence: 0.2,
    };
  }
  const stratLatency = Date.now() - stratT0;

  // 3. COMPOSE — given the thesis + insights, write the outline + image briefs.
  const compT0 = Date.now();
  let composition: Composition;
  try {
    const c = await composeOutline({ keys, userQuery, plan, strategy, compactResearch });
    composition = c.composition;
  } catch (e) {
    // Fallback: use the planner's outline.
    composition = {
      format: plan.format,
      title: plan.title,
      dek: plan.understood_as,
      outline: plan.outline.map((n) => ({
        kind: n.kind,
        title: n.title,
        angle: n.body || n.title,
        insight_refs: [],
        evidence_refs: [],
      })),
      images: plan.images.map((i) => ({
        ref: i.ref, intent: "", prompt: i.prompt, aspect_ratio: i.aspect_ratio, use_brand_screenshot: i.use_brand_screenshot,
      })),
      voice_constraints: plan.voice_notes ?? [],
    };
  }
  const compLatency = Date.now() - compT0;

  // 4. IMAGES — generate in parallel from the COMPOSED image plan.
  const images = await generateComposedImages(env, composition.images, research, slug);
  const imageByRef = new Map(images.filter((i) => i.url).map((i) => [i.ref, i.url!]));

  // 5. WRITE — each section/slide gets its own LLM call with focused context.
  const writeT0 = Date.now();
  const sections = await writeAllSections({ keys, userQuery, composition, strategy, compactResearch });
  const writeLatency = Date.now() - writeT0;

  // 6. Build timeline. Includes the new thinking-layer steps.
  const timeline = [
    ...research.map((r) => ({
      verb: r.step.verb,
      status: r.status,
      duration_ms: r.duration_ms,
      summary: r.error ?? summarizeResearch(r),
    })),
    { verb: "agent.strategize", status: strategy.confidence >= 0.5 ? "ok" : "low_confidence", duration_ms: stratLatency, summary: `thesis: "${strategy.thesis.slice(0, 80)}…" · ${strategy.insights.length} insights · conf=${strategy.confidence}` },
    { verb: "agent.compose", status: "ok", duration_ms: compLatency, summary: `${composition.outline.length} ${composition.format === "presentation" ? "slides" : "sections"} · ${composition.images.length} images planned` },
    ...images.map((i) => ({
      verb: `image:${i.ref}`,
      status: i.url ? "ok" : "error",
      duration_ms: i.latency_ms,
      summary: i.url ? `$${i.cost_usd.toFixed(4)}` : (i.error ?? "no url"),
    })),
    { verb: "agent.write", status: "ok", duration_ms: writeLatency, summary: `${sections.length} sections written in parallel · ${sections.reduce((s, x) => s + x.meta.tokens, 0)} tokens` },
  ];

  // 7. RENDER using the FULL composition + written bodies, not just raw plan.
  const workbookHtml = composition.format === "document"
    ? composeDocumentFromWriting(composition, sections, research, imageByRef, timeline, strategy, userQuery)
    : composePresentationFromWriting(composition, sections, research, imageByRef, timeline, strategy, userQuery);

  // 5. Upload to R2 (public).
  const deckKey = `brand-books/public/${slug}.html`;
  const deckBytes = new TextEncoder().encode(workbookHtml);
  try {
    await env.ASSETS.put(deckKey, deckBytes, {
      httpMetadata: { contentType: "text/html; charset=utf-8" },
      customMetadata: {
        slug,
        format: plan.format,
        kind: "agent_dynamic",
        title: plan.title,
        domains: plan.domains.join(","),
        generated_at: new Date().toISOString(),
        query: userQuery.slice(0, 200),
      },
    });
  } catch (e) {
    // continue — caller may still want the result
  }

  return {
    plan,
    research,
    strategy,
    composition,
    images,
    sections,
    workbook_url: `https://api.brandnana.net/books/${slug}.html`,
    workbook_bytes: deckBytes.length,
    slug,
    total_cost_usd: images.reduce((s, i) => s + i.cost_usd, 0),
    total_latency_ms: Date.now() - t0,
    timeline,
  };
}

// Replacement for generatePlanImages: takes Composition.images instead of Plan.images.
async function generateComposedImages(
  env: Bindings,
  imagePlan: Composition["images"],
  research: ResearchOutcome[],
  slug: string,
): Promise<ExecutionResult["images"]> {
  const primaryScrape = research.find((r) => r.step.verb === "scrape" && r.status === "ok");
  const primaryDomain = primaryScrape?.step.args?.domain as string | undefined;
  const evidence = primaryScrape?.payload as HomepageEvidence | undefined;

  const results = await Promise.allSettled(
    imagePlan.map(async (img, i) => {
      const t0 = Date.now();
      const refImg = img.use_brand_screenshot && primaryDomain
        ? homepageScreenshot(primaryDomain, { width: 1280, height: 800 }).url
        : undefined;
      const brandFlavor = brandFlavorForPrompt(evidence);
      const fullPrompt = brandFlavor ? `${img.prompt}\n\n${brandFlavor}` : img.prompt;
      try {
        const gen = await generateImage(env.OPENROUTER_API_KEY ?? "", {
          prompt: fullPrompt,
          referenceImageUrl: refImg,
          aspectRatio: img.aspect_ratio,
        });
        const ext = gen.mime === "image/png" ? "png" : gen.mime === "image/jpeg" ? "jpg" : "bin";
        const key = `concept-images/${slug}/${img.ref}-${i}.${ext}`;
        const url = await uploadImageToR2(env.ASSETS, key, gen);
        return { ref: img.ref, url, cost_usd: gen.cost_usd, latency_ms: Date.now() - t0 };
      } catch (e) {
        return { ref: img.ref, error: (e as Error).message, cost_usd: 0, latency_ms: Date.now() - t0 };
      }
    }),
  );
  return results.map((r, idx) =>
    r.status === "fulfilled" ? r.value : { ref: imagePlan[idx]?.ref ?? "?", error: String(r.reason), cost_usd: 0, latency_ms: 0 },
  );
}

// ── New composers that use the WRITTEN sections, not just raw plan ──────────

function composeDocumentFromWriting(
  composition: Composition,
  sections: WrittenSection[],
  research: ResearchOutcome[],
  imgByRef: Map<string, string>,
  timeline: ExecutionResult["timeline"],
  strategy: Strategy,
  userQuery: string,
): string {
  const primaryDomain = (research.find((r) => r.step.verb === "scrape" && r.status === "ok")?.step.args as any)?.domain;
  const primaryScrape = primaryDomain ? findResearchByVerb(research, "scrape", primaryDomain)?.payload as HomepageEvidence | undefined : undefined;
  const palette = primaryScrape?.colors_ranked.slice(0, 8).map((c) => ({ hex: c.hex })) ?? [];
  const fonts = primaryScrape?.fonts ?? [];

  const docSections: DocumentSection[] = sections.map((s) => {
    const blocks: DocumentBlock[] = [];
    if (s.body) blocks.push({ body: s.body });
    if (s.image_ref && imgByRef.has(s.image_ref)) {
      blocks.push({ image_url: imgByRef.get(s.image_ref)!, image_caption: s.title });
    }
    if (s.highlight) {
      blocks.push({ data: { kind: s.highlight.kind, payload: s.highlight.payload } as any });
    }
    return { title: s.title, blocks };
  });

  // Strategy gets its own opening section (no body — title + insights as quotes).
  if (strategy.thesis && strategy.confidence >= 0.4) {
    docSections.unshift({
      title: "Thesis",
      blocks: [
        { data: { kind: "quote", payload: { quote: strategy.thesis, attribution: strategy.stakes } } },
      ],
    });
  }

  docSections.push({
    title: "Sources & method",
    blocks: [
      { body: `Generated by brandnana agent. Query: _${userQuery}_\n\nNarrative arc: ${strategy.narrative_arc}` },
      ...(strategy.gaps.length ? [{ body: `**Gaps acknowledged:** ${strategy.gaps.join("; ")}` }] : []),
      { data: { kind: "timeline", payload: timeline.map((t) => ({ ts: "", verb_id: t.verb, status: t.status, summary: t.summary })) } },
    ],
  });

  const heroImage = composition.images[0]?.ref && imgByRef.has(composition.images[0].ref) ? imgByRef.get(composition.images[0].ref!) : undefined;

  const docData: DocumentData = {
    spec: {
      slug: `${(primaryDomain ?? "wb").replace(/\./g, "-")}-doc-${Date.now().toString(36)}`,
      title: composition.title,
      subtitle: composition.dek,
      generated_at: new Date().toISOString(),
      domains: composition.outline.length ? [primaryDomain].filter(Boolean) as string[] : [],
    },
    hero: { eyebrow: "BRAND DOSSIER", image_url: heroImage },
    byline: `brandnana · ${new Date().toISOString().slice(0, 10)} · query: "${userQuery.slice(0, 80)}"`,
    palette,
    primary_font: fonts[0]?.family,
    secondary_font: fonts[1]?.family,
    sections: docSections,
    endnotes: composition.voice_constraints,
  };

  return renderDocument({
    data: docData,
    workbookSpec: { slug: docData.spec.slug, title: docData.spec.title, generator: "brandnana-agent", format: "document" },
    sourceBundleBase64: "",
  });
}

function composePresentationFromWriting(
  composition: Composition,
  sections: WrittenSection[],
  research: ResearchOutcome[],
  imgByRef: Map<string, string>,
  timeline: ExecutionResult["timeline"],
  strategy: Strategy,
  userQuery: string,
): string {
  const primaryDomain = composition.outline.length ? ((research.find((r) => r.step.verb === "scrape")?.step.args as any)?.domain ?? "wb") : "wb";
  const primaryScrape = findResearchByVerb(research, "scrape", primaryDomain)?.payload as HomepageEvidence | undefined;
  const primaryLogo = findResearchByVerb(research, "logo", primaryDomain)?.payload as { result?: LogoResult } | undefined;
  const palette = primaryScrape?.colors_ranked.slice(0, 8).map((c) => ({ hex: c.hex })) ?? [];
  const fonts = primaryScrape?.fonts ?? [];
  const verify = findResearchByVerb(research, "verify_brand", primaryDomain)?.payload as { observed_name?: string } | undefined;
  const brandName = verify?.observed_name ?? primaryDomain.split(".")[0]!;

  // Compose a thesis slide at position 1 (after cover).
  const slides: DynamicSlide[] = [];
  slides.push({
    title: composition.title,
    body: composition.dek,
    image_url: composition.images[0]?.ref ? imgByRef.get(composition.images[0].ref) : undefined,
  });
  if (strategy.thesis && strategy.confidence >= 0.4) {
    slides.push({
      title: "Thesis",
      body: strategy.thesis,
      data: { kind: "quote", payload: { quote: strategy.thesis, attribution: strategy.stakes } } as any,
    });
  }
  for (const s of sections) {
    slides.push({
      title: s.title,
      body: s.body,
      image_url: s.image_ref ? imgByRef.get(s.image_ref) : undefined,
      data: s.highlight ? { kind: s.highlight.kind, payload: s.highlight.payload } as any : undefined,
    });
  }

  return renderDynamicPresentation({
    title: composition.title,
    subtitle: composition.dek,
    domains: [primaryDomain],
    brandName,
    palette,
    fonts: fonts.map((f) => f.family),
    logoUrl: primaryLogo?.result?.url ?? "",
    outline: slides,
    timeline,
    userQuery,
    voice_notes: composition.voice_constraints,
  });
}

function summarizeResearch(r: ResearchOutcome): string {
  if (r.status !== "ok" || !r.payload) return "";
  const p = r.payload as any;
  switch (r.step.verb) {
    case "scrape":
      return `vars=${p.brand_css_vars?.length ?? 0} colors=${p.colors_ranked?.length ?? 0} fonts=${p.fonts?.length ?? 0}`;
    case "multipage":
      return `${p.pages?.length ?? 0} pages · ${p.total_text_bytes ?? 0}B`;
    case "verify_brand":
      return `conf=${p.confidence?.toFixed(2)} trust=${p.trust}`;
    case "logo":
      return p.result ? `${p.result.source}` : "no candidate";
    case "screenshot":
      return `${p.viewport?.width}×${p.viewport?.height}`;
    case "competitor":
      return `evidence + logo + verify`;
    default:
      return "";
  }
}

// ── Document composer ───────────────────────────────────────────────────────

function composeDocument(
  plan: Plan,
  research: ResearchOutcome[],
  imgByRef: Map<string, string>,
  timeline: ExecutionResult["timeline"],
  userQuery: string,
): string {
  const primaryDomain = plan.domains[0];
  const primaryScrape = primaryDomain ? findResearchByVerb(research, "scrape", primaryDomain)?.payload as HomepageEvidence | undefined : undefined;
  const palette = primaryScrape?.colors_ranked.slice(0, 8).map((c) => ({ hex: c.hex })) ?? [];
  const fonts = primaryScrape?.fonts ?? [];

  const sections: DocumentSection[] = plan.outline.map((node) => {
    const blocks: DocumentBlock[] = [];
    if (node.body) blocks.push({ body: node.body });
    if (node.image_ref && imgByRef.has(node.image_ref)) {
      blocks.push({ image_url: imgByRef.get(node.image_ref)!, image_caption: node.title });
    }
    if (node.data) {
      blocks.push({ data: resolveData(node.data, research) as DocumentBlock["data"] });
    }
    return { title: node.title, blocks };
  });

  // Append a "Sources" section listing the verb trace.
  if (timeline.length) {
    sections.push({
      title: "Sources & method",
      blocks: [
        { body: "Below is the verb-trace that produced this document. Every fact in the body is traceable to a research step." },
        { data: { kind: "timeline", payload: timeline.map((t) => ({ ts: "", verb_id: t.verb, status: t.status, summary: t.summary })) } },
      ],
    });
  }

  const heroImage = plan.outline[0]?.image_ref && imgByRef.has(plan.outline[0].image_ref!) ? imgByRef.get(plan.outline[0].image_ref!)! : undefined;

  const docData: DocumentData = {
    spec: {
      slug: `${(primaryDomain ?? "wb").replace(/\./g, "-")}-doc-${Date.now().toString(36)}`,
      title: plan.title,
      subtitle: plan.understood_as,
      generated_at: new Date().toISOString(),
      domains: plan.domains,
    },
    hero: { eyebrow: plan.format_rationale.slice(0, 60), image_url: heroImage },
    byline: `brandnana · ${new Date().toISOString().slice(0, 10)} · query: "${userQuery.slice(0, 80)}"`,
    palette,
    primary_font: fonts[0]?.family,
    secondary_font: fonts[1]?.family,
    sections,
    endnotes: plan.voice_notes,
  };

  return renderDocument({
    data: docData,
    workbookSpec: { slug: docData.spec.slug, title: docData.spec.title, generator: "brandnana-agent", format: "document" },
    sourceBundleBase64: "",
  });
}

// ── Presentation composer (uses existing presentation-shell) ────────────────

function composePresentation(
  plan: Plan,
  research: ResearchOutcome[],
  imgByRef: Map<string, string>,
  timeline: ExecutionResult["timeline"],
  userQuery: string,
): string {
  const primaryDomain = plan.domains[0] ?? "wb";
  const primaryScrape = findResearchByVerb(research, "scrape", primaryDomain)?.payload as HomepageEvidence | undefined;
  const primaryLogo = findResearchByVerb(research, "logo", primaryDomain)?.payload as { result?: LogoResult } | undefined;
  const palette = primaryScrape?.colors_ranked.slice(0, 8).map((c) => ({ hex: c.hex, name: c.hex, role: "observed", note: c.via?.[0] ?? "" })) ?? [];
  const fonts = primaryScrape?.fonts ?? [];
  const verify = findResearchByVerb(research, "verify_brand", primaryDomain)?.payload as { observed_name?: string } | undefined;
  const brandName = verify?.observed_name ?? primaryDomain.split(".")[0]!;

  // Map outline → custom slides (we re-use the presentation shell's generic slide layout).
  // For the dynamic agent flow we render a SIMPLE single-deck layout in our
  // own HTML so the planner has full control of slide content.
  return renderDynamicPresentation({
    title: plan.title,
    subtitle: plan.understood_as,
    domains: plan.domains,
    brandName,
    palette,
    fonts: fonts.map((f) => f.family),
    logoUrl: primaryLogo?.result?.url ?? "",
    outline: plan.outline.map((node) => ({
      title: node.title,
      body: node.body,
      image_url: node.image_ref ? imgByRef.get(node.image_ref) : undefined,
      data: node.data ? (resolveData(node.data, research) as any) : undefined,
    })),
    timeline,
    userQuery,
    voice_notes: plan.voice_notes,
  });
}

function resolveData(d: NonNullable<NonNullable<Plan["outline"][number]>["data"]>, research: ResearchOutcome[]): unknown {
  // The planner can either inline data in the outline (which we pass through)
  // OR reference a known kind whose payload we backfill from research.
  // For v1, we trust the planner's payload. Future: lookup by kind + domain.
  return d;
}

// ── Dynamic presentation renderer ────────────────────────────────────────────

interface DynamicSlide {
  title: string;
  body: string;
  image_url?: string;
  data?: NonNullable<NonNullable<Plan["outline"][number]>["data"]>;
}

function renderDynamicPresentation(args: {
  title: string;
  subtitle: string;
  domains: string[];
  brandName: string;
  palette: Array<{ hex: string }>;
  fonts: string[];
  logoUrl: string;
  outline: DynamicSlide[];
  timeline: ExecutionResult["timeline"];
  userQuery: string;
  voice_notes?: string[];
}): string {
  const esc = (s: string) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  // Contrast-aware: picks the FIRST DARK palette color for primary (headings)
  // so brands whose dominant scraped color is white (e.g. Vercel) don't end
  // up with invisible white-on-white text.
  const theme = pickThemeColors(args.palette);
  const primary = theme.primary;
  const secondary = theme.secondary;
  const accent = theme.accent;
  const displayFont = args.fonts[0] || "Optima, Cormorant Garamond, Georgia, serif";
  const bodyFont = args.fonts[1] || "Inter, ui-sans-serif, system-ui, sans-serif";

  const slides = args.outline.map((s, i) => {
    const num = String(i + 1).padStart(2, "0");
    const hasImage = !!s.image_url;
    const hasBody = !!s.body;
    const layoutClass = hasImage && hasBody ? "split" : hasImage ? "full-image" : "text-only";
    const imageHtml = hasImage ? `<div class="slide-image"><img src="${esc(s.image_url!)}" alt="${esc(s.title)}" loading="lazy"></div>` : "";
    const dataHtml = s.data ? renderSlideData(s.data) : "";
    return `<section class="slide ${layoutClass}" data-num="${num}">
      <div class="slide-content">
        <div class="slide-num">${num}</div>
        <h2>${esc(s.title)}</h2>
        ${hasBody ? `<div class="slide-body">${esc(s.body).replace(/\n\n/g, "</p><p>").replace(/^/, "<p>") + "</p>"}</div>` : ""}
        ${dataHtml}
      </div>
      ${imageHtml}
    </section>`;
  }).join("");

  const slideJson = JSON.stringify({ title: args.title, brand: args.brandName, domains: args.domains, outline: args.outline.map((s) => ({ title: s.title })) });

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(args.title)}</title>
<style>
  :root {
    --primary: ${esc(primary)};
    --secondary: ${esc(secondary)};
    --accent: ${esc(accent)};
    --font-display: "${esc(displayFont.split(",")[0]!.trim())}", serif;
    --font-body: "${esc(bodyFont.split(",")[0]!.trim())}", system-ui, sans-serif;
    --bg: #0e0e10;
    --stage-bg: #fff;
    --stage-w: 1280px;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: #fff; font-family: var(--font-body); height: 100%; overflow: hidden; }
  #stage-wrap { position: fixed; inset: 0; display: grid; grid-template-rows: 1fr auto; align-items: center; justify-items: center; padding: clamp(12px, 3vh, 40px) clamp(12px, 3vw, 60px) 60px; }
  #stage { width: min(100%, calc((100vh - 140px) * (16/9))); aspect-ratio: 16/9; max-width: var(--stage-w); background: var(--stage-bg); color: #111; border-radius: 14px; box-shadow: 0 12px 64px -16px rgba(0,0,0,.55); position: relative; overflow: hidden; }

  .slide { position: absolute; inset: 0; padding: clamp(28px, 4vh, 52px) clamp(36px, 5vw, 72px); display: flex; opacity: 0; pointer-events: none; transition: opacity 220ms; }
  .slide.active { opacity: 1; pointer-events: auto; }
  .slide.text-only .slide-content, .slide.full-image .slide-content { flex: 1; }
  .slide.split { gap: clamp(20px, 3vw, 40px); }
  .slide.split .slide-content { flex: 1 1 50%; display: flex; flex-direction: column; justify-content: center; min-width: 0; }
  .slide.split .slide-image { flex: 1 1 50%; display: flex; align-items: center; justify-content: center; }
  .slide.full-image .slide-image { position: absolute; inset: 0; }
  .slide.full-image .slide-image img { width: 100%; height: 100%; object-fit: cover; }
  .slide.full-image .slide-content { position: relative; z-index: 2; color: #fff; background: linear-gradient(to top, rgba(0,0,0,.7), rgba(0,0,0,0) 60%); padding: 0; align-self: flex-end; }
  .slide-image img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px; display: block; }
  .slide-num { font-family: ui-monospace, monospace; font-size: 11px; color: var(--accent); letter-spacing: .14em; margin-bottom: 12px; }
  .slide h2 { font-family: var(--font-display); font-size: clamp(28px, 4.2vw, 52px); line-height: 1.05; margin: 0 0 18px; color: var(--primary); font-weight: 600; letter-spacing: -0.01em; }
  .slide.full-image h2 { color: #fff; }
  .slide-body p { font-size: clamp(14px, 1.4vw, 18px); line-height: 1.55; color: #2a2a2a; margin: 0 0 14px; }
  .slide.full-image .slide-body p { color: rgba(255,255,255,.92); }
  .slide-data { margin-top: 16px; }

  .palette-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(90px, 1fr)); gap: 8px; }
  .palette-strip > div { aspect-ratio: 1/1; border-radius: 6px; display: flex; align-items: flex-end; padding: 8px; font-family: ui-monospace, monospace; font-size: 10px; }
  .product-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 10px; }
  .product-list > div { padding: 10px 12px; background: rgba(0,0,0,.04); border-radius: 6px; font-size: 13px; }
  .product-list .price { font-family: ui-monospace, monospace; font-size: 12px; color: var(--accent); margin-top: 4px; }
  .quote-block { font-family: var(--font-display); font-size: clamp(20px, 2.4vw, 30px); line-height: 1.35; border-left: 4px solid var(--accent); padding-left: 18px; color: #222; }
  .stat-block { padding: 24px; background: var(--primary); color: var(--secondary); border-radius: 8px; }
  .stat-block .value { font-family: var(--font-display); font-size: clamp(40px, 6vw, 80px); font-weight: 700; line-height: 1; }
  .stat-block .label { font-size: 12px; letter-spacing: .14em; text-transform: uppercase; margin-top: 8px; opacity: .85; }
  .comp-list { display: flex; flex-direction: column; gap: 6px; }
  .comp-list > div { padding: 8px 12px; background: rgba(0,0,0,.04); border-radius: 6px; display: flex; gap: 10px; align-items: baseline; font-size: 13px; }
  .comp-list .domain { font-family: ui-monospace, monospace; color: #888; font-size: 11px; }
  .ad-list-slide { display: flex; flex-direction: column; gap: 8px; }
  .ad-list-slide > div { padding: 10px 14px; background: rgba(0,0,0,.04); border-radius: 6px; font-size: 13px; }
  .ad-list-slide .cta { font-size: 10px; letter-spacing: .12em; text-transform: uppercase; color: #888; margin-top: 3px; }

  #dots { display: flex; gap: 6px; padding: 16px 0 0; }
  #dots button { width: 8px; height: 8px; border-radius: 50%; border: 0; background: rgba(255,255,255,.22); cursor: pointer; padding: 0; transition: background 120ms; }
  #dots button.active { background: rgba(255,255,255,.85); }
  #counter { position: fixed; bottom: 18px; right: 22px; font-family: ui-monospace, monospace; font-size: 11px; color: rgba(255,255,255,.55); }
  #chrome { position: fixed; bottom: 18px; left: 22px; font-size: 11px; color: rgba(255,255,255,.5); }
</style>
</head>
<body>
<div id="stage-wrap">
  <div id="stage">${slides}</div>
  <nav id="dots"></nav>
  <div id="counter"></div>
  <div id="chrome">${esc(args.brandName)} · ${esc(args.domains.join(", "))}</div>
</div>
<script id="workbook-spec" type="application/json">${slideJson}</script>
<script id="presentation-data" type="application/json">${slideJson}</script>
<script>
(function(){
  var stage = document.getElementById('stage');
  var dots = document.getElementById('dots');
  var counter = document.getElementById('counter');
  var slides = stage.querySelectorAll('.slide');
  var idx = 0;
  function render() {
    for (var i = 0; i < slides.length; i++) slides[i].classList.toggle('active', i === idx);
    counter.textContent = (idx+1) + ' / ' + slides.length;
    var btns = dots.querySelectorAll('button');
    for (var j = 0; j < btns.length; j++) btns[j].classList.toggle('active', j === idx);
  }
  for (var k = 0; k < slides.length; k++) {
    (function(i){
      var b = document.createElement('button');
      b.addEventListener('click', function(){ idx = i; render(); });
      dots.appendChild(b);
    })(k);
  }
  document.addEventListener('keydown', function(e){
    if (e.key === 'ArrowRight' || e.key === ' ' || e.key === 'l') { idx = Math.min(idx+1, slides.length-1); render(); }
    if (e.key === 'ArrowLeft' || e.key === 'h') { idx = Math.max(idx-1, 0); render(); }
    if (e.key === 'Home') { idx = 0; render(); }
    if (e.key === 'End') { idx = slides.length-1; render(); }
    if (e.key === 'f' || e.key === 'F') document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
  });
  render();
})();
</script>
</body>
</html>`;
}

function renderSlideData(data: NonNullable<NonNullable<Plan["outline"][number]>["data"]>): string {
  const esc = (s: string) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  switch (data.kind) {
    case "palette": {
      const items = (data.payload as Array<{ hex: string; name?: string }>).slice(0, 8);
      return `<div class="slide-data"><div class="palette-strip">${items.map((c) => {
        const lum = parseInt(c.hex.replace("#", "").slice(0, 2), 16) * 0.299 + parseInt(c.hex.replace("#", "").slice(2, 4), 16) * 0.587 + parseInt(c.hex.replace("#", "").slice(4, 6), 16) * 0.114;
        const fg = lum > 140 ? "#111" : "#fff";
        return `<div style="background:${esc(c.hex)};color:${fg}">${esc(c.hex)}</div>`;
      }).join("")}</div></div>`;
    }
    case "products": {
      const items = (data.payload as Array<{ name: string; price?: number; category?: string }>).slice(0, 6);
      return `<div class="slide-data"><div class="product-list">${items.map((p) => `<div>${esc(p.name)}${p.price ? `<div class="price">$${p.price.toFixed(p.price%1?2:0)}</div>` : ""}</div>`).join("")}</div></div>`;
    }
    case "ads": {
      const items = (data.payload as Array<{ headline: string; platform?: string; cta?: string }>).slice(0, 4);
      return `<div class="slide-data"><div class="ad-list-slide">${items.map((a) => `<div>"${esc(a.headline)}"<div class="cta">${esc(a.platform ?? "")}${a.cta ? " · " + esc(a.cta) : ""}</div></div>`).join("")}</div></div>`;
    }
    case "competitors": {
      const items = (data.payload as Array<{ name: string; domain: string }>).slice(0, 6);
      return `<div class="slide-data"><div class="comp-list">${items.map((c) => `<div><span>${esc(c.name)}</span><span class="domain">${esc(c.domain)}</span></div>`).join("")}</div></div>`;
    }
    case "stat": {
      const p = data.payload as { value: string; label: string };
      return `<div class="slide-data"><div class="stat-block"><div class="value">${esc(p.value)}</div><div class="label">${esc(p.label)}</div></div></div>`;
    }
    case "quote": {
      const p = data.payload as { quote: string; attribution?: string };
      return `<div class="slide-data"><div class="quote-block">${esc(p.quote)}${p.attribution ? `<br><small style="font-size:.7em;opacity:.7">— ${esc(p.attribution)}</small>` : ""}</div></div>`;
    }
    case "timeline":
      return ""; // these are doc-only widgets
    default:
      return "";
  }
}
