// Rate card management — GET list, POST draft, POST /:id/tag.
//
// Mirror of apps/api/src/rates.ts helpers, copied here intentionally.
// Admin is a SEPARATE Cloudflare Worker — cross-worker imports are not
// supported at build time. Keep in sync manually when the schema changes.
//
// Immutability rule (from schema):
//   tag=null  → untagged draft, freely mutable.
//   tag≠null  → frozen. To revise: create new draft (proposeCustomerRate),
//               freeze it (tagCustomerRate), point supersedes_id at the old one.

import { Hono } from 'hono';
import type { CustomerRateCard, VendorRateCard } from '@brandnana/schema';
import type { Bindings } from './env.js';

const app = new Hono<{ Bindings: Bindings }>();

// ── GET /rates ────────────────────────────────────────────────────────────────
// Query params:
//   tag?   — filter customer cards by tag (exact match)
//   verb?  — filter customer cards by verb_id (exact match)

app.get('/', async (c) => {
  const tag = c.req.query('tag');
  const verb = c.req.query('verb');

  // Vendor rates — all active (no filter; admin sees everything).
  const { results: vendor } = await c.env.DB
    .prepare('SELECT * FROM vendor_rate_cards ORDER BY provider, effective_from DESC')
    .all<VendorRateCard>();

  // Customer rates — optional filters.
  let customerSql = 'SELECT * FROM customer_rate_cards WHERE 1=1';
  const binds: unknown[] = [];

  if (tag != null) {
    customerSql += ' AND tag = ?';
    binds.push(tag);
  }
  if (verb != null) {
    customerSql += ' AND verb_id = ?';
    binds.push(verb);
  }
  customerSql += ' ORDER BY created_at DESC';

  const { results: customer } = await c.env.DB
    .prepare(customerSql)
    .bind(...binds)
    .all<CustomerRateCard>();

  return c.json({ vendor: vendor ?? [], customer: customer ?? [] });
});

// ── POST /rates ───────────────────────────────────────────────────────────────
// Body: Omit<CustomerRateCard, 'id' | 'created_at' | 'supersedes_id'>
// Returns: the created untagged draft.
// Rejects 400 if `tag` is supplied (admin drafts must be untagged).

app.post('/', async (c) => {
  let body: Partial<CustomerRateCard>;
  try {
    body = await c.req.json<Partial<CustomerRateCard>>();
  } catch {
    return c.json({ error: 'invalid JSON body' }, 400);
  }

  if (body.tag != null) {
    return c.json({ error: 'draft must be untagged — omit `tag` or set to null' }, 400);
  }

  const required = ['verb_id', 'price_strategy', 'effective_from', 'created_by'] as const;
  for (const field of required) {
    if (body[field] == null) {
      return c.json({ error: `missing required field: ${field}` }, 400);
    }
  }

  const draft = body as Omit<CustomerRateCard, 'id' | 'created_at' | 'supersedes_id'>;

  const created = await proposeCustomerRate(c.env.DB, draft);
  return c.json(created, 201);
});

// ── POST /rates/:id/tag ───────────────────────────────────────────────────────
// Body: { tag: string }
// Returns the now-frozen card.
// 404 if card not found. 409 if already tagged.

app.post('/:id/tag', async (c) => {
  const id = c.req.param('id');
  let body: { tag?: string };
  try {
    body = await c.req.json<{ tag?: string }>();
  } catch {
    return c.json({ error: 'invalid JSON body' }, 400);
  }

  if (!body.tag || typeof body.tag !== 'string') {
    return c.json({ error: 'body must include a non-empty `tag` string' }, 400);
  }

  const existing = await c.env.DB
    .prepare('SELECT * FROM customer_rate_cards WHERE id = ?')
    .bind(id)
    .first<CustomerRateCard>();

  if (!existing) return c.json({ error: 'rate card not found' }, 404);
  if (existing.tag != null) {
    return c.json(
      { error: `card is already tagged "${existing.tag}" — tagged cards are immutable` },
      409,
    );
  }

  const tagged = await tagCustomerRate(c.env.DB, id, body.tag);
  return c.json(tagged);
});

export default app;

// ── Helpers (mirrored from apps/api/src/rates.ts) ─────────────────────────────

async function proposeCustomerRate(
  db: D1Database,
  draft: Omit<CustomerRateCard, 'id' | 'created_at' | 'supersedes_id'>,
): Promise<CustomerRateCard> {
  if (draft.tag != null) {
    throw new Error('proposeCustomerRate: draft must be untagged (tag must be null/undefined)');
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

async function tagCustomerRate(
  db: D1Database,
  id: string,
  tag: string,
): Promise<CustomerRateCard> {
  const existing = await db
    .prepare('SELECT * FROM customer_rate_cards WHERE id = ?')
    .bind(id)
    .first<CustomerRateCard>();

  if (!existing) throw new Error(`tagCustomerRate: card not found: ${id}`);
  if (existing.tag != null) {
    throw new Error(
      `tagCustomerRate: card ${id} is already tagged "${existing.tag}" — tagged cards are immutable`,
    );
  }

  await db
    .prepare('UPDATE customer_rate_cards SET tag = ? WHERE id = ?')
    .bind(tag, id)
    .run();

  return { ...existing, tag };
}
