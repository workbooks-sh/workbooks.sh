// Rate card helpers — vendor cost lookup + customer pricing resolution.
//
// Immutability contract for tagged customer cards:
//   - tagCustomerRate() is the ONLY function that may set a tag on a card.
//   - Once tagged, a card row is never mutated. Revisions supersede via a new row.
//   - Drafts (tag=null) are freely mutable via proposeCustomerRate.
//
// Resolution order for findCustomerRate:
//   1. Tagged card matching verb_id exactly     (requested_tag, if provided)
//   2. Tagged catch-all ('*')                   (requested_tag, if provided)
//   3. Untagged card matching verb_id exactly
//   4. Untagged catch-all ('*')
//   Tagged cards beat untagged at every position.

import type { CustomerRateCard, VendorRateCard } from "@brandnana/schema";

// ── Vendor rates ──────────────────────────────────────────────────────────────

/**
 * Return the active vendor rate for (provider, model, unit) at timestamp `ts`
 * (ms). "Active" means effective_from ≤ ts AND (effective_to IS NULL OR
 * effective_to > ts). Returns null when no matching row exists.
 *
 * When multiple rows match (e.g. a vendor updated their price), the one with
 * the highest effective_from wins (most-recently-effective wins).
 */
export async function findVendorRate(
  db: D1Database,
  provider: string,
  model: string | null,
  unit: string,
  ts: number,
): Promise<VendorRateCard | null> {
  const row = model != null
    ? await db
        .prepare(
          `SELECT * FROM vendor_rate_cards
           WHERE provider = ?
             AND model = ?
             AND unit = ?
             AND effective_from <= ?
             AND (effective_to IS NULL OR effective_to > ?)
           ORDER BY effective_from DESC
           LIMIT 1`,
        )
        .bind(provider, model, unit, ts, ts)
        .first<VendorRateCard>()
    : await db
        .prepare(
          `SELECT * FROM vendor_rate_cards
           WHERE provider = ?
             AND model IS NULL
             AND unit = ?
             AND effective_from <= ?
             AND (effective_to IS NULL OR effective_to > ?)
           ORDER BY effective_from DESC
           LIMIT 1`,
        )
        .bind(provider, unit, ts, ts)
        .first<VendorRateCard>();

  return row ?? null;
}

// ── Customer rates ────────────────────────────────────────────────────────────

/**
 * Return the best-matching customer rate card for `verb_id` at timestamp `ts`.
 * If `requested_tag` is provided, tagged cards with that tag are preferred over
 * untagged drafts. Resolution order (first non-null wins):
 *   1. tagged + exact verb_id
 *   2. tagged + '*'
 *   3. untagged + exact verb_id
 *   4. untagged + '*'
 */
export async function findCustomerRate(
  db: D1Database,
  verb_id: string,
  ts: number,
  requested_tag?: string,
): Promise<CustomerRateCard | null> {
  if (requested_tag != null) {
    // Tagged exact.
    const tagged = await db
      .prepare(
        `SELECT * FROM customer_rate_cards
         WHERE tag = ? AND verb_id = ? AND effective_from <= ?
         ORDER BY effective_from DESC LIMIT 1`,
      )
      .bind(requested_tag, verb_id, ts)
      .first<CustomerRateCard>();
    if (tagged) return tagged;

    // Tagged catch-all.
    if (verb_id !== "*") {
      const taggedCatchAll = await db
        .prepare(
          `SELECT * FROM customer_rate_cards
           WHERE tag = ? AND verb_id = '*' AND effective_from <= ?
           ORDER BY effective_from DESC LIMIT 1`,
        )
        .bind(requested_tag, ts)
        .first<CustomerRateCard>();
      if (taggedCatchAll) return taggedCatchAll;
    }
  }

  // Untagged exact.
  const untagged = await db
    .prepare(
      `SELECT * FROM customer_rate_cards
       WHERE tag IS NULL AND verb_id = ? AND effective_from <= ?
       ORDER BY effective_from DESC LIMIT 1`,
    )
    .bind(verb_id, ts)
    .first<CustomerRateCard>();
  if (untagged) return untagged;

  // Untagged catch-all.
  if (verb_id !== "*") {
    const untaggedCatchAll = await db
      .prepare(
        `SELECT * FROM customer_rate_cards
         WHERE tag IS NULL AND verb_id = '*' AND effective_from <= ?
         ORDER BY effective_from DESC LIMIT 1`,
      )
      .bind(ts)
      .first<CustomerRateCard>();
    if (untaggedCatchAll) return untaggedCatchAll;
  }

  return null;
}

/**
 * Insert a new untagged (draft) customer rate card.
 * The caller must not supply `id`, `created_at`, or `supersedes_id` — those
 * are set here.
 */
export async function proposeCustomerRate(
  db: D1Database,
  draft: Omit<CustomerRateCard, "id" | "created_at" | "supersedes_id">,
): Promise<CustomerRateCard> {
  if (draft.tag != null) {
    throw new Error("proposeCustomerRate: draft must be untagged (tag must be null/undefined)");
  }

  const id = crypto.randomUUID();
  const now = Date.now();

  await db
    .prepare(
      `INSERT INTO customer_rate_cards
         (id, tag, verb_id, price_strategy, markup_multiplier, fixed_price_usd,
          unit, notes, effective_from, supersedes_id, created_at, created_by)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
    )
    .bind(
      id,
      null,
      draft.verb_id,
      draft.price_strategy,
      draft.markup_multiplier ?? null,
      draft.fixed_price_usd ?? null,
      draft.unit ?? null,
      draft.notes ?? null,
      draft.effective_from,
      now,
      draft.created_by,
    )
    .run();

  return {
    ...draft,
    id,
    tag: null,
    supersedes_id: null,
    created_at: now,
  };
}

/**
 * Freeze (tag) an existing untagged draft card.
 * Throws if the card does not exist or is already tagged.
 *
 * This is the ONLY function that may set a tag on a customer rate card.
 * Application code that needs to revise a tagged card must call
 * proposeCustomerRate() to create a new draft, then tagCustomerRate() to
 * freeze it — passing `supersedes_id` via the draft if needed.
 */
export async function tagCustomerRate(
  db: D1Database,
  id: string,
  tag: string,
): Promise<CustomerRateCard> {
  const existing = await db
    .prepare(`SELECT * FROM customer_rate_cards WHERE id = ?`)
    .bind(id)
    .first<CustomerRateCard>();

  if (!existing) {
    throw new Error(`tagCustomerRate: card not found: ${id}`);
  }
  if (existing.tag != null) {
    throw new Error(
      `tagCustomerRate: card ${id} is already tagged "${existing.tag}" — tagged cards are immutable`,
    );
  }

  await db
    .prepare(`UPDATE customer_rate_cards SET tag = ? WHERE id = ?`)
    .bind(tag, id)
    .run();

  return { ...existing, tag };
}
