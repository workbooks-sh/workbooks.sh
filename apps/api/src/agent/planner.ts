// Dynamic planner. Takes a free-form user request → DeepSeek v4 ideates a
// plan. The plan picks ONE of two output formats (document | presentation)
// and a flexible outline + verb list. No fixed intent enum.
//
// The plan is rendered as org-mode so a human can read it, but executed
// from its JSON shape.

import { chatJson, MODELS } from "../llm.js";

export type WorkbookFormat = "document" | "presentation";

export interface PlanResearchStep {
  /** A verb the executor knows: "scrape", "logo", "screenshot", "verify_brand",
   *  "multipage", "ads_search", "catalog_crawl", "competitor". */
  verb: string;
  /** Verb-specific args (e.g. {domain, expected_brand}). */
  args: Record<string, unknown>;
  /** Why the planner thinks this verb is needed for THIS request. */
  rationale: string;
}

export interface PlanImage {
  /** Where in the deck this image belongs (matches an outline node's image_ref). */
  ref: string;
  /** Detailed prompt the image-gen model receives. */
  prompt: string;
  /** "1:1" | "16:9" | "9:16" | "4:5" | "3:4" — keep it explicit. */
  aspect_ratio: string;
  /** Optional: pull a brand-vibe reference image (homepage screenshot, etc). */
  use_brand_screenshot?: boolean;
}

export interface PlanOutlineNode {
  /** For presentation = slide; for document = section. */
  kind: "slide" | "section";
  /** Section/slide title. */
  title: string;
  /** What to put in the body. Could be markdown, could be a brief. */
  body: string;
  /** Optional ref into PlanImage.ref so executor knows which image to inline. */
  image_ref?: string;
  /** Optional structured data (palette swatches, product grid, ad list). The
   *  executor + renderer know these shapes and lay them out. */
  data?: { kind: "palette" | "products" | "ads" | "competitors" | "timeline" | "stat" | "quote"; payload: unknown };
}

export interface Plan {
  format: WorkbookFormat;
  /** Title of the final deliverable. */
  title: string;
  /** One-sentence framing of what the user actually asked for. */
  understood_as: string;
  /** Why the planner picked document vs presentation. */
  format_rationale: string;
  /** Domains involved (primary + competitors for compare workflows). */
  domains: string[];
  /** Research steps to run before composing. */
  research: PlanResearchStep[];
  /** Images to generate. */
  images: PlanImage[];
  /** The outline — slides or sections, in order. */
  outline: PlanOutlineNode[];
  /** Optional voice/tone constraints the writer should honor. */
  voice_notes?: string[];
}

const SYSTEM_PROMPT = `You are a creative-research planner for brandnana. The user gives a free-form request; you write a PLAN.

OUTPUT FORMATS (pick exactly one):
  - "document":      long-form scrollable HTML. Sections with H2 + body text + embedded images + data widgets. Good for: research reports, audits, strategy memos, RFPs, press kits, narrative pieces.
  - "presentation":  slide-by-slide deck (16:9). Each slide is one idea. Good for: pitches, campaign concepts, brand books, competitive teardowns, mood boards, ad mockups, carousels.

Pick the format that fits the REQUEST. Pitch deck → presentation. Audit report → document. If the user explicitly asks for one, honor that. Default lean: if the request implies "show me" → presentation; "tell me" or "write me" → document.

VERBS YOU CAN PUT IN research[] (executor will run them in parallel where it can):
  - scrape          {domain}                              → homepage HTML + CSS vars + colors + fonts + meta
  - multipage       {domain}                              → About/Press/Journal/Products text harvested
  - verify_brand    {domain, expected_brand}              → confidence the URL is the brand we think
  - logo            {domain}                              → cascading logo URL hunt (Clearbit → favicon → og)
  - screenshot      {domain}                              → mshots homepage capture URL
  - ads_search      {query, providers?: [meta|tiktok|google|exa]} → ad library hits
  - catalog_crawl   {domain}                              → product list
  - competitor      {domain, competitor_domain}           → competitor scrape + verify

Each research step has a rationale. Don't add steps that don't serve the outline. For multi-brand work, repeat scrape/logo/screenshot per domain.

IMAGES: each image[] entry has a ref ('hero', 'slide3', 'product_render_a', etc) that must also appear in some outline node's image_ref. The image_ref creates the binding. Don't generate images that aren't placed. Don't reference images you didn't generate.

OUTLINE NODES: kind matches format. For "presentation" use kind="slide"; for "document" use kind="section". A node may have body text AND an image AND a structured data widget. The data widget can be a palette swatch grid, product card list, ads quote list, competitor matrix, or a single big stat/quote.

DESIGN PRINCIPLES:
  - Be specific. "show palette" is bad; "Side-by-side palette chips for both brands, sourced from CSS vars" is good.
  - The plan is BOTH a research checklist AND a layout outline. Both halves matter.
  - For comparisons, plan symmetric research (same verbs both sides).
  - For ad creative tasks, include image prompts; describe subject + composition + lighting + props.

HARD LIMITS (Cloudflare Worker subrequest budget):
  - research[] max 8 entries. For multi-brand, prefer scrape + logo per domain over deeper crawls.
  - images[] max 6 entries.
  - outline[] max 10 entries (slides) or 8 (sections).

Reply with ONLY this JSON shape:
{
  "format": "document" | "presentation",
  "title": "...",
  "understood_as": "one sentence",
  "format_rationale": "why this format for this request",
  "domains": ["primary.com", "competitor.com"],
  "research": [{"verb": "scrape", "args": {"domain": "..."}, "rationale": "..."}],
  "images": [{"ref": "hero", "prompt": "...", "aspect_ratio": "16:9", "use_brand_screenshot": true}],
  "outline": [
    {"kind": "slide" | "section", "title": "...", "body": "...", "image_ref": "hero", "data": {"kind": "palette", "payload": {...}}}
  ],
  "voice_notes": ["3-5 short tone bullets"]
}`;

export interface KeyBag { openrouter?: string; cerebras?: string }

export async function planRequest(
  keys: KeyBag,
  userQuery: string,
): Promise<{ plan: Plan; latency_ms: number; cost_usd?: number; model: string }> {
  const { value, usage, latency_ms, model } = await chatJson<Plan>(keys, {
    model: MODELS.planner, // deepseek/deepseek-v4-pro by default
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userQuery },
    ],
    temperature: 0.4,
    max_tokens: 8000,
  });

  // Defensive fixups — the model is good but occasionally drops a field.
  value.format = value.format === "document" ? "document" : "presentation";
  value.domains = Array.isArray(value.domains) ? value.domains.map((d) => normalizeDomain(d)).filter(Boolean) : [];
  // Hard caps to stay inside CF Worker subrequest budget.
  value.research = (Array.isArray(value.research) ? value.research : []).slice(0, 8);
  value.images = (Array.isArray(value.images) ? value.images : []).slice(0, 6);
  value.outline = (Array.isArray(value.outline) ? value.outline : []).slice(0, plan_outline_cap(value.format));
  value.voice_notes = Array.isArray(value.voice_notes) ? value.voice_notes : [];

  return { plan: value, latency_ms, cost_usd: usage.cost_usd, model };
}

function plan_outline_cap(fmt: WorkbookFormat): number { return fmt === "presentation" ? 10 : 8; }

function normalizeDomain(d: unknown): string {
  if (typeof d !== "string") return "";
  return d.toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").replace(/^www\./, "").trim();
}

// ── Pretty-print a plan as org so a human can read it. ──────────────────────

export function planAsOrg(plan: Plan): string {
  const lines: string[] = [];
  lines.push(`* ${plan.title}`);
  lines.push(`  :PROPERTIES:`);
  lines.push(`  :FORMAT:        ${plan.format}`);
  lines.push(`  :DOMAINS:       ${plan.domains.join(", ")}`);
  lines.push(`  :END:`);
  lines.push(`  ${plan.understood_as}`);
  lines.push(``);
  lines.push(`  Rationale: ${plan.format_rationale}`);
  lines.push(``);
  lines.push(`** Research (${plan.research.length})`);
  for (const r of plan.research) {
    lines.push(`   - [ ] ${r.verb}(${JSON.stringify(r.args)}) — ${r.rationale}`);
  }
  lines.push(``);
  lines.push(`** Images (${plan.images.length})`);
  for (const i of plan.images) {
    lines.push(`   - [ ] ${i.ref} (${i.aspect_ratio}): ${i.prompt.slice(0, 100)}…`);
  }
  lines.push(``);
  lines.push(`** Outline (${plan.outline.length} ${plan.format === "presentation" ? "slides" : "sections"})`);
  for (const [i, o] of plan.outline.entries()) {
    const tag = o.image_ref ? ` [img:${o.image_ref}]` : "";
    const data = o.data ? ` [data:${o.data.kind}]` : "";
    lines.push(`   ${i + 1}. ${o.title}${tag}${data}`);
    if (o.body) lines.push(`      ${o.body.slice(0, 140).replace(/\n/g, " ")}`);
  }
  if (plan.voice_notes?.length) {
    lines.push(``);
    lines.push(`** Voice notes`);
    for (const v of plan.voice_notes) lines.push(`   - ${v}`);
  }
  return lines.join("\n");
}
