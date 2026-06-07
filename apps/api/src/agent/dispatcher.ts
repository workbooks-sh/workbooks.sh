// Agent dispatcher — takes a free-form query, classifies intent via
// Cerebras, plans a verb sequence, executes it, validates each step, and
// returns a curated answer. The "agent verb."
//
// v1 scope: a thin orchestrator over our existing verbs (brand-fetch,
// logo-cascade, homepage-scrape, verify-brand, book.build). Per the user's
// direction: "creates a checklist, follows the plan by going through
// everything and putting it together."
//
// Intent taxonomy (Cerebras picks one):
//   - "book"     → full brand book (calls buildBook)
//   - "describe" → quick brand identity summary (scrape + verify + curate)
//   - "logo"     → just find + verify the logo
//   - "verify"   → just confirm domain matches expected brand
//
// Each step records to a plan log with input → output → validation pass/fail.
// On validation failure, the agent can retry with a different source.

import { chatJson, AiError } from "../ai.js";
import type { Bindings } from "../env.js";
import { fetchLogo } from "./logo-fetch.js";
import { scrapeHomepageEvidence } from "./homepage-scrape.js";
import { verifyBrand } from "./verify-brand.js";
import { probeLogo } from "./asset-probe.js";
import { harvestMultiPage } from "./multipage-text.js";
import { composeConcept, type ConceptIntent } from "./concept-deck.js";

export type AgentIntent = "book" | "describe" | "logo" | "verify" | "static_ad" | "landing_page" | "carousel" | "product_concept" | "campaign_brief" | "unknown";

export interface AgentPlanStep {
  verb: string;
  why: string;
}

export interface AgentPlan {
  intent: AgentIntent;
  domain: string;
  expected_brand?: string;
  /** Creative brief for GENERATE intents (image-producing). */
  brief?: string;
  /** One-line restatement of what the user actually asked. */
  understood_as: string;
  steps: AgentPlanStep[];
}

const GENERATE_INTENTS: ReadonlySet<AgentIntent> = new Set([
  "static_ad", "landing_page", "carousel", "product_concept", "campaign_brief",
]);

export interface AgentStepResult {
  verb: string;
  status: "ok" | "low_confidence" | "failed" | "skipped";
  duration_ms: number;
  /** Output payload (verb-specific). */
  output?: unknown;
  /** Pass/fail validation of this step's output, when applicable. */
  validation?: { passed: boolean; reasons: string[] };
  notes?: string[];
}

export interface AgentRunResult {
  query: string;
  plan: AgentPlan;
  steps: AgentStepResult[];
  /** Final narrative answer (Cerebras-written). */
  answer: string;
  /** Confidence score 0-1 (worst of every step's validation). */
  confidence: number;
  /** Tokens + latency totals. */
  meta: { latency_ms: number; cerebras_tokens: number };
}

// ── Intent classification ────────────────────────────────────────────────────

const PLAN_SYSTEM_PROMPT = `You are an agent planner for brandnana. The user asks about a brand or domain. Pick ONE intent and surface the domain.

Intents:
  Brand intelligence (READ):
  - "book":            full brand book / brand identity dossier
  - "describe":        quick brand summary (no images generated)
  - "logo":            just the logo / visual mark
  - "verify":          confirm a domain is the brand they think

  Creative production (GENERATE):
  - "static_ad":       3 static ad variations across formats (square, portrait, story)
  - "landing_page":    hero + 3-section landing page concept
  - "carousel":        5-frame IG carousel
  - "product_concept": invented product variant render + supporting visuals
  - "campaign_brief":  4 ad variations + tone brief

  - "unknown":         the query doesn't map cleanly to any of these

For GENERATE intents, capture the user's actual creative brief verbatim (a sentence or two of WHAT they want made — promo angle, season, audience, vibe, etc).

Reply with ONLY a JSON object. No prose:
{
  "intent": "book|describe|logo|verify|static_ad|landing_page|carousel|product_concept|campaign_brief|unknown",
  "domain": "the bare domain like nike.com (lowercase, no protocol, no path) — REQUIRED if intent != unknown",
  "expected_brand": "the brand name the user mentioned (e.g. 'Nike') OR omit if not stated",
  "brief":  "REQUIRED for GENERATE intents — the user's creative brief in their own words",
  "understood_as": "one-sentence restatement of what they asked for"
}`;

async function planFromQuery(
  apiKey: string,
  query: string,
): Promise<{ plan: AgentPlan; tokens: number }> {
  const { value, usage } = await chatJson<{
    intent?: string;
    domain?: string;
    expected_brand?: string;
    brief?: string;
    understood_as?: string;
  }>(apiKey, {
    messages: [
      { role: "system", content: PLAN_SYSTEM_PROMPT },
      { role: "user", content: query },
    ],
    temperature: 0.1,
    max_tokens: 2000,
  });

  const VALID = ["book", "describe", "logo", "verify", "static_ad", "landing_page", "carousel", "product_concept", "campaign_brief"];
  const intent = (VALID.includes(value.intent ?? "") ? value.intent : "unknown") as AgentIntent;
  const domain = (value.domain ?? "").toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "").trim();

  // Build canonical step list from intent.
  const steps: AgentPlanStep[] = [];
  if (intent === "book") {
    steps.push(
      { verb: "agent.homepage_scrape", why: "ground in real CSS evidence" },
      { verb: "agent.verify_brand", why: "confirm the URL is the right brand" },
      { verb: "agent.logo_cascade", why: "find a valid logo" },
      { verb: "agent.logo_probe", why: "validate logo quality" },
      { verb: "agent.multipage_text", why: "harvest voice signal across pages" },
      { verb: "agent.cerebras_compose", why: "write final brand book narrative" },
    );
  } else if (intent === "describe") {
    steps.push(
      { verb: "agent.homepage_scrape", why: "ground in real evidence" },
      { verb: "agent.verify_brand", why: "confirm brand identity" },
      { verb: "agent.cerebras_compose", why: "write 3-sentence summary" },
    );
  } else if (intent === "logo") {
    steps.push(
      { verb: "agent.logo_cascade", why: "find best logo URL" },
      { verb: "agent.logo_probe", why: "validate format + quality" },
    );
  } else if (intent === "verify") {
    steps.push(
      { verb: "agent.homepage_scrape", why: "fetch homepage HTML" },
      { verb: "agent.verify_brand", why: "compare expected_brand vs observed signals" },
    );
  } else if (GENERATE_INTENTS.has(intent)) {
    // Concept-deck composer handles its own internal pipeline (scrape +
    // logo + Cerebras-plan + image-gen × N + R2 upload + deck render). The
    // dispatcher just delegates to it as a single super-step.
    steps.push({ verb: "agent.compose_concept", why: "scrape + plan + generate images + bundle deck" });
  }

  return {
    plan: {
      intent,
      domain,
      expected_brand: value.expected_brand,
      brief: value.brief,
      understood_as: value.understood_as ?? `User query: ${query}`,
      steps,
    },
    tokens: usage.completion_tokens,
  };
}

// ── Execution ────────────────────────────────────────────────────────────────

export async function runAgent(env: Bindings, query: string): Promise<AgentRunResult> {
  const t0 = Date.now();
  let cerebrasTokens = 0;

  // Step A: plan.
  let plan: AgentPlan;
  try {
    const planned = await planFromQuery(env.CEREBRAS_API_KEY ?? "", query);
    plan = planned.plan;
    cerebrasTokens += planned.tokens;
  } catch (e) {
    plan = {
      intent: "unknown",
      domain: "",
      understood_as: `(planner failed: ${(e as Error).message})`,
      steps: [],
    };
  }

  // Bail fast if planner produced unknown / no domain.
  if (plan.intent === "unknown" || !plan.domain) {
    return {
      query,
      plan,
      steps: [],
      answer: `I couldn't figure out what to do with that. Try: "make a brand book for nike.com" or "describe sweetgreen.com".`,
      confidence: 0,
      meta: { latency_ms: Date.now() - t0, cerebras_tokens: cerebrasTokens },
    };
  }

  // Step B: execute each planned step + record results.
  const stepResults: AgentStepResult[] = [];
  const context: Record<string, any> = {}; // intermediate data passed between steps

  for (const step of plan.steps) {
    const sT0 = Date.now();
    try {
      const result = await runStep(env, step.verb, plan, context);
      stepResults.push({
        verb: step.verb,
        status: result.validation && !result.validation.passed ? "low_confidence" : "ok",
        duration_ms: Date.now() - sT0,
        output: result.output,
        validation: result.validation,
        notes: result.notes,
      });
    } catch (e) {
      stepResults.push({
        verb: step.verb,
        status: "failed",
        duration_ms: Date.now() - sT0,
        notes: [(e as Error).message],
      });
    }
  }

  // Step C: compose final answer.
  let answer: string;
  let composeTokens = 0;
  try {
    const composed = await composeAnswer(env.CEREBRAS_API_KEY ?? "", query, plan, stepResults, context);
    answer = composed.answer;
    composeTokens = composed.tokens;
  } catch (e) {
    answer = `Plan ran but final compose failed: ${(e as Error).message}. Raw step results in .steps[].`;
  }
  cerebrasTokens += composeTokens;

  // Confidence = min of each step's validation (default 0.8 if step passed without validator).
  const stepScores = stepResults.map((r) => {
    if (r.status === "failed") return 0;
    if (r.status === "low_confidence") return 0.4;
    if (r.validation?.passed === false) return 0.4;
    return 0.9;
  });
  const confidence = stepScores.length ? Math.min(...stepScores) : 0;

  return {
    query,
    plan,
    steps: stepResults,
    answer,
    confidence,
    meta: { latency_ms: Date.now() - t0, cerebras_tokens: cerebrasTokens },
  };
}

// ── Step runners ─────────────────────────────────────────────────────────────

async function runStep(
  env: Bindings,
  verb: string,
  plan: AgentPlan,
  ctx: Record<string, any>,
): Promise<{ output: any; validation?: { passed: boolean; reasons: string[] }; notes?: string[] }> {
  switch (verb) {
    case "agent.homepage_scrape": {
      const ev = await scrapeHomepageEvidence(plan.domain, { browser: env.BROWSER });
      ctx.evidence = ev;
      const passed = !ev.fetch_error && (ev.brand_css_vars.length > 0 || ev.colors_ranked.length > 0);
      return {
        output: { meta: ev.meta, brand_css_vars: ev.brand_css_vars.length, colors: ev.colors_ranked.length, fonts: ev.fonts.length, fetch_error: ev.fetch_error },
        validation: { passed, reasons: passed ? [] : ["no CSS evidence extracted"] },
      };
    }
    case "agent.verify_brand": {
      const html = ctx.evidence ? undefined : undefined; // homepage scrape doesn't return raw html in current shape
      const v = await verifyBrand({
        domain: plan.domain,
        expected_name: plan.expected_brand ?? plan.domain.split(".")[0]!,
        html,
      });
      ctx.brand_verify = v;
      return {
        output: { confidence: v.confidence, observed_name: v.observed_name, signals: v.signals.length, trust: v.trust },
        validation: { passed: v.trust, reasons: v.warnings },
      };
    }
    case "agent.logo_cascade": {
      const r = await fetchLogo(plan.domain, { logoDevToken: env.CONTEXT_DEV_API_KEY });
      ctx.logo = r;
      return {
        output: r.result ? { url: r.result.url, source: r.result.source } : { error: "all sources failed", attempts: r.attempts.length },
        validation: { passed: !!r.result, reasons: r.result ? [] : ["cascade exhausted"] },
      };
    }
    case "agent.logo_probe": {
      const url = ctx.logo?.result?.url;
      if (!url) return { output: null, validation: { passed: false, reasons: ["no logo url from previous step"] } };
      const p = await probeLogo(url);
      ctx.logo_probe = p;
      const passed = p.reachable && p.quality_score >= 30;
      return {
        output: { format: p.format, bytes: p.bytes, width: p.width, height: p.height, quality_score: p.quality_score },
        validation: { passed, reasons: passed ? [] : [`low quality score: ${p.quality_score}/100`] },
        notes: p.notes,
      };
    }
    case "agent.multipage_text": {
      const r = await harvestMultiPage({ domain: plan.domain, browser: env.BROWSER });
      ctx.multipage = r;
      const passed = r.pages.length > 0 && r.total_text_bytes > 500;
      return {
        output: { pages: r.pages.map((p) => ({ url: p.url, kind: p.kind, words: p.word_count })), total_text_bytes: r.total_text_bytes },
        validation: { passed, reasons: passed ? [] : ["no relevant pages found"] },
      };
    }
    case "agent.cerebras_compose":
      // Compose handled in composeAnswer() — this step is a marker.
      return { output: { deferred: true } };
    case "agent.compose_concept": {
      const intent = plan.intent as ConceptIntent;
      const result = await composeConcept({
        env,
        intent,
        domain: plan.domain,
        brief: plan.brief ?? "",
        brandName: plan.expected_brand,
      });
      ctx.concept = result;
      const passed = result.ok && result.image_urls.length > 0;
      return {
        output: {
          workbook_url: result.workbook_url,
          image_urls: result.image_urls,
          cost_usd: result.cost_usd,
          cover_headline: result.narrative.cover_headline,
        },
        validation: { passed, reasons: passed ? [] : ["no images generated"] },
      };
    }
    default:
      throw new Error(`unknown verb: ${verb}`);
  }
}

// ── Final compose ────────────────────────────────────────────────────────────

async function composeAnswer(
  apiKey: string,
  query: string,
  plan: AgentPlan,
  steps: AgentStepResult[],
  ctx: Record<string, any>,
): Promise<{ answer: string; tokens: number }> {
  const evidence = {
    intent: plan.intent,
    domain: plan.domain,
    expected_brand: plan.expected_brand,
    brand_verify: ctx.brand_verify
      ? { confidence: ctx.brand_verify.confidence, observed_name: ctx.brand_verify.observed_name, trust: ctx.brand_verify.trust }
      : null,
    evidence_meta: ctx.evidence?.meta,
    brand_css_vars: ctx.evidence?.brand_css_vars?.slice(0, 20),
    colors_ranked: ctx.evidence?.colors_ranked?.slice(0, 6),
    fonts: ctx.evidence?.fonts?.slice(0, 4),
    logo: ctx.logo?.result ? { url: ctx.logo.result.url, source: ctx.logo.result.source } : null,
    logo_probe: ctx.logo_probe
      ? { format: ctx.logo_probe.format, dimensions: `${ctx.logo_probe.width}×${ctx.logo_probe.height}`, quality: ctx.logo_probe.quality_score }
      : null,
    multipage_kinds: ctx.multipage?.pages?.map((p: any) => p.kind),
    step_failures: steps.filter((s) => s.status === "failed").map((s) => ({ verb: s.verb, note: s.notes?.[0] })),
  };

  // For GENERATE intents, the concept-deck composer already did all the heavy
  // lifting; we just write a short summary pointing at the deck URL.
  if (GENERATE_INTENTS.has(plan.intent)) {
    const concept = ctx.concept;
    if (concept?.workbook_url) {
      return {
        answer:
          `Generated a ${plan.intent.replace(/_/g, " ")} concept for ${plan.domain}.\n\n` +
          `Headline: ${concept.narrative.cover_headline}\n` +
          `Subhead:  ${concept.narrative.cover_subhead}\n\n` +
          `${concept.image_urls.length} image${concept.image_urls.length === 1 ? "" : "s"} generated (cost $${concept.cost_usd.toFixed(4)}).\n` +
          `View the deck: ${concept.workbook_url}\n` +
          `Individual images: ${concept.image_urls.join(", ")}`,
        tokens: 0,
      };
    }
    return { answer: "Concept generation failed — see steps[] for the trace.", tokens: 0 };
  }

  const SYSTEM = `You are answering a user query about a brand. You have OBSERVED evidence we just scraped. Answer the query using ONLY this evidence. \
If evidence is sparse for some claim, acknowledge it. Do NOT invoke memory of the brand. Tone: direct, confident, no marketing puff. \
${plan.intent === "book" ? "User wants a brand book — write a 4-paragraph brand identity summary (voice, palette, type, visual style)." : ""}\
${plan.intent === "describe" ? "User wants a quick description — write 2-3 sentences." : ""}\
${plan.intent === "logo" ? "User wants the logo — return its URL + format + quality observations in one paragraph." : ""}\
${plan.intent === "verify" ? "User wants to confirm a brand match — state YES/NO + confidence + reasoning in one paragraph." : ""}\
Reply with ONLY a JSON object: { "answer": "<your written reply>" }`;

  const { value, usage } = await chatJson<{ answer?: string }>(apiKey, {
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: `Query: ${query}\n\nObserved evidence:\n${JSON.stringify(evidence, null, 2)}` },
    ],
    temperature: 0.4,
    max_tokens: 4000,
  });

  return {
    answer: (value.answer ?? "(empty)").slice(0, 4000),
    tokens: usage.completion_tokens,
  };
}
