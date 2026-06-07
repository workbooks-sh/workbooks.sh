// Dry-run cost simulation for a verb against current rate cards.
//
// POST /simulate
// Body: {
//   verb_id: string,
//   payload?: unknown,                    — unused for now, reserved for future unit estimation
//   customer_rate_card_id?: string,       — pin to a specific card by id
//   customer_rate_card_tag?: string,      — pin to a tagged card (overrides id if both supplied)
// }
// Returns: {
//   projected_vendor_cost_usd: number,
//   projected_customer_charge_usd: number,
//   projected_margin_usd: number,
//   breakdown: VendorCallEstimate[],      — per-vendor-call unit estimates
// }
//
// ── Heuristic unit table ──────────────────────────────────────────────────────
// Each entry defines the expected vendor calls for one execution of a verb.
// These are ESTIMATES — not contract values. They let the admin get a ballpark
// before any real traffic exists for that verb.
//
// LLM verbs (anything using openrouter):
//   ~500 input tokens + ~300 output tokens per call.
//
// ads.search:
//   1 request × 50 items (Exa search, $10/1000 req = $0.01/req at 50 results).
//
// catalog.crawl:
//   1 e2b second × 60 + 1 firecrawl request × 20 pages.
//   (E2B sandbox: ~$0.001/sec; Firecrawl: per-page pricing.)
//
// resolve.url, brand.*, design.*:
//   1 firecrawl request × 1 page.
//
// scrape.*:
//   1 firecrawl request × 5 pages (typical).
//
// social.*:
//   1 API request (TikTok/Meta/Google).
//
// Default fallback:
//   1 request at $0.
//
// Multiply units by vendor_rate_cards at the current timestamp to get cost.
// Then apply the customer rate card (markup_multiplier / fixed) for charge.

import { Hono } from 'hono';
import type { CustomerRateCard, VendorRateCard } from '@brandnana/schema';
import type { Bindings } from './env.js';

interface SimulateBody {
  verb_id: string;
  payload?: unknown;
  customer_rate_card_id?: string;
  customer_rate_card_tag?: string;
}

interface VendorCallEstimate {
  provider: string;
  model?: string;
  unit: string;
  estimated_units: number;
  price_usd_per_unit: number;
  total_usd: number;
}

interface SimulateResult {
  projected_vendor_cost_usd: number;
  projected_customer_charge_usd: number;
  projected_margin_usd: number;
  breakdown: VendorCallEstimate[];
}

// ── Static verb → unit heuristic table ───────────────────────────────────────

interface VendorUnitHint {
  provider: string;
  model?: string;
  unit: string;
  estimated_units: number;
}

function heuristicUnits(verb_id: string): VendorUnitHint[] {
  // LLM verbs: anything in the brand / brief / design namespaces or explicit
  // LLM routes that call OpenRouter.
  const llmPrefixes = ['brand.', 'brief.', 'design.', 'social.analyze', 'catalog.classify'];
  if (llmPrefixes.some((p) => verb_id.startsWith(p))) {
    return [
      // Default model in seeded vendor_rate_cards. Override via the rate-card system, not here.
      { provider: 'openrouter', model: 'google/gemini-3.5-flash', unit: 'token_input', estimated_units: 500 },
      { provider: 'openrouter', model: 'google/gemini-3.5-flash', unit: 'token_output', estimated_units: 300 },
    ];
  }

  if (verb_id.startsWith('ads.search') || verb_id === 'ads.search') {
    return [
      { provider: 'exa', unit: 'request', estimated_units: 1 },
    ];
  }

  if (verb_id.startsWith('catalog.crawl')) {
    return [
      { provider: 'e2b', unit: 'second', estimated_units: 60 },
      { provider: 'firecrawl', unit: 'request', estimated_units: 20 },
    ];
  }

  if (verb_id.startsWith('resolve.') || verb_id.startsWith('scrape.')) {
    const pages = verb_id.startsWith('scrape.') ? 5 : 1;
    return [
      { provider: 'firecrawl', unit: 'request', estimated_units: pages },
    ];
  }

  if (verb_id.startsWith('social.')) {
    return [
      { provider: 'meta', unit: 'request', estimated_units: 1 },
    ];
  }

  // Default: one request at no vendor cost. The customer card may still charge.
  return [
    { provider: 'internal', unit: 'request', estimated_units: 1 },
  ];
}

// ── Rate lookups ──────────────────────────────────────────────────────────────

async function findVendorRate(
  db: D1Database,
  provider: string,
  model: string | undefined,
  unit: string,
  ts: number,
): Promise<VendorRateCard | null> {
  const row = model != null
    ? await db
        .prepare(
          `SELECT * FROM vendor_rate_cards
           WHERE provider = ? AND model = ? AND unit = ?
             AND effective_from <= ?
             AND (effective_to IS NULL OR effective_to > ?)
           ORDER BY effective_from DESC LIMIT 1`,
        )
        .bind(provider, model, unit, ts, ts)
        .first<VendorRateCard>()
    : await db
        .prepare(
          `SELECT * FROM vendor_rate_cards
           WHERE provider = ? AND model IS NULL AND unit = ?
             AND effective_from <= ?
             AND (effective_to IS NULL OR effective_to > ?)
           ORDER BY effective_from DESC LIMIT 1`,
        )
        .bind(provider, unit, ts, ts)
        .first<VendorRateCard>();
  return row ?? null;
}

async function findCustomerRate(
  db: D1Database,
  verb_id: string,
  ts: number,
  id_pin?: string,
  tag_pin?: string,
): Promise<CustomerRateCard | null> {
  // Pin by id takes precedence if no tag_pin.
  if (id_pin != null && tag_pin == null) {
    return db
      .prepare('SELECT * FROM customer_rate_cards WHERE id = ?')
      .bind(id_pin)
      .first<CustomerRateCard>();
  }

  // Resolution order: tagged exact → tagged catch-all → untagged exact → untagged catch-all.
  if (tag_pin != null) {
    const tagged = await db
      .prepare(
        `SELECT * FROM customer_rate_cards
         WHERE tag = ? AND verb_id = ? AND effective_from <= ?
         ORDER BY effective_from DESC LIMIT 1`,
      )
      .bind(tag_pin, verb_id, ts)
      .first<CustomerRateCard>();
    if (tagged) return tagged;

    if (verb_id !== '*') {
      const taggedCatchAll = await db
        .prepare(
          `SELECT * FROM customer_rate_cards
           WHERE tag = ? AND verb_id = '*' AND effective_from <= ?
           ORDER BY effective_from DESC LIMIT 1`,
        )
        .bind(tag_pin, ts)
        .first<CustomerRateCard>();
      if (taggedCatchAll) return taggedCatchAll;
    }
  }

  const untagged = await db
    .prepare(
      `SELECT * FROM customer_rate_cards
       WHERE tag IS NULL AND verb_id = ? AND effective_from <= ?
       ORDER BY effective_from DESC LIMIT 1`,
    )
    .bind(verb_id, ts)
    .first<CustomerRateCard>();
  if (untagged) return untagged;

  if (verb_id !== '*') {
    const catchAll = await db
      .prepare(
        `SELECT * FROM customer_rate_cards
         WHERE tag IS NULL AND verb_id = '*' AND effective_from <= ?
         ORDER BY effective_from DESC LIMIT 1`,
      )
      .bind(ts)
      .first<CustomerRateCard>();
    if (catchAll) return catchAll;
  }

  return null;
}

// ── Route ─────────────────────────────────────────────────────────────────────

const app = new Hono<{ Bindings: Bindings }>();

app.post('/', async (c) => {
  let body: Partial<SimulateBody>;
  try {
    body = await c.req.json<Partial<SimulateBody>>();
  } catch {
    return c.json({ error: 'invalid JSON body' }, 400);
  }

  if (!body.verb_id || typeof body.verb_id !== 'string') {
    return c.json({ error: 'verb_id is required' }, 400);
  }

  const { verb_id, customer_rate_card_id, customer_rate_card_tag } = body;
  const ts = Date.now();

  // 1. Derive unit estimates from the heuristic table.
  const hints = heuristicUnits(verb_id);

  // 2. Look up vendor rates and compute breakdown.
  const breakdown: VendorCallEstimate[] = [];
  let totalVendorCost = 0;

  for (const hint of hints) {
    const rate = await findVendorRate(c.env.DB, hint.provider, hint.model, hint.unit, ts);
    const pricePerUnit = rate?.price_usd_per_unit ?? 0;
    const total = hint.estimated_units * pricePerUnit;
    totalVendorCost += total;

    breakdown.push({
      provider: hint.provider,
      ...(hint.model != null ? { model: hint.model } : {}),
      unit: hint.unit,
      estimated_units: hint.estimated_units,
      price_usd_per_unit: pricePerUnit,
      total_usd: total,
    });
  }

  // 3. Look up customer rate card and compute charge.
  const card = await findCustomerRate(
    c.env.DB,
    verb_id,
    ts,
    customer_rate_card_id,
    customer_rate_card_tag,
  );

  let projected_customer_charge_usd = 0;

  if (card != null) {
    switch (card.price_strategy) {
      case 'markup_multiplier':
        projected_customer_charge_usd = totalVendorCost * (card.markup_multiplier ?? 1);
        break;
      case 'fixed_per_call':
        projected_customer_charge_usd = card.fixed_price_usd ?? 0;
        break;
      case 'fixed_per_unit': {
        // Sum units across all breakdown hints for the card's unit type.
        const cardUnit = card.unit;
        const unitTotal = breakdown
          .filter((b) => b.unit === cardUnit)
          .reduce((sum, b) => sum + b.estimated_units, 0);
        projected_customer_charge_usd = unitTotal * (card.fixed_price_usd ?? 0);
        break;
      }
    }
  } else {
    // No rate card: pass through vendor cost (0 margin).
    projected_customer_charge_usd = totalVendorCost;
  }

  const projected_margin_usd = projected_customer_charge_usd - totalVendorCost;

  const result: SimulateResult = {
    projected_vendor_cost_usd: totalVendorCost,
    projected_customer_charge_usd,
    projected_margin_usd,
    breakdown,
  };

  return c.json(result);
});

export default app;
