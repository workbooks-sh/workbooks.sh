// Cost / revenue / profit reporting over the events table.
//
// GET /spend query params:
//   from        — start timestamp (ms), default: 30 days ago
//   to          — end timestamp (ms), default: now
//   group_by    — 'day' | 'verb' | 'provider' | 'source' (default: 'day')
//
// Returns buckets aggregated by the requested dimension + overall totals.

import { Hono } from 'hono';
import type { Bindings } from './env.js';

type GroupBy = 'day' | 'verb' | 'provider' | 'source';

interface SpendBucket {
  key: string;
  calls: number;
  vendor_cost_usd: number;
  customer_charge_usd: number;
  margin_usd: number;
}

interface SpendRow {
  key: string;
  calls: number;
  vendor_cost_usd: number;
  customer_charge_usd: number;
  margin_usd: number;
}

const app = new Hono<{ Bindings: Bindings }>();

app.get('/', async (c) => {
  const now = Date.now();
  const thirtyDaysAgo = now - 30 * 24 * 60 * 60 * 1000;

  const fromParam = c.req.query('from');
  const toParam = c.req.query('to');
  const groupByParam = (c.req.query('group_by') ?? 'day') as GroupBy;

  const from = fromParam != null ? Number(fromParam) : thirtyDaysAgo;
  const to = toParam != null ? Number(toParam) : now;

  if (isNaN(from) || isNaN(to)) {
    return c.json({ error: 'from and to must be numeric timestamps (ms)' }, 400);
  }

  const validGroupBy: GroupBy[] = ['day', 'verb', 'provider', 'source'];
  if (!validGroupBy.includes(groupByParam)) {
    return c.json({ error: `group_by must be one of: ${validGroupBy.join(', ')}` }, 400);
  }

  // Build the GROUP BY expression.
  // 'day' groups by calendar day (UTC) using integer division of ts by 86400000.
  // 'provider' is not a direct column — it's derived from the first vendor_call's
  // provider field. We approximate by using the verb_id prefix as a proxy since
  // full JSON aggregation over vendor_calls in D1 SQLite is heavy. For a real
  // provider breakdown the caller should use GET /events and aggregate client-side.
  let selectKey: string;
  switch (groupByParam) {
    case 'day':
      // Cast to integer day bucket: floor(ts / 86400000) * 86400000 → epoch-day-ms
      selectKey = `CAST((ts / 86400000) AS INTEGER) * 86400000`;
      break;
    case 'verb':
      selectKey = `verb_id`;
      break;
    case 'provider':
      // Best-effort: verb_id prefix (e.g. 'ads', 'catalog', 'brand').
      // Full vendor_calls JSON parse for provider is done at /events level.
      selectKey = `SUBSTR(verb_id, 1, INSTR(verb_id || '.', '.') - 1)`;
      break;
    case 'source':
      selectKey = `source`;
      break;
  }

  const sql = `
    SELECT
      ${selectKey} AS key,
      COUNT(*) AS calls,
      COALESCE(SUM(vendor_cost_usd), 0) AS vendor_cost_usd,
      COALESCE(SUM(customer_charge_usd), 0) AS customer_charge_usd,
      COALESCE(SUM(margin_usd), 0) AS margin_usd
    FROM events
    WHERE ts >= ? AND ts < ?
    GROUP BY key
    ORDER BY key ASC
  `;

  const { results } = await c.env.DB.prepare(sql).bind(from, to).all<SpendRow>();

  const buckets: SpendBucket[] = (results ?? []).map((r) => ({
    key: String(r.key),
    calls: r.calls,
    vendor_cost_usd: r.vendor_cost_usd,
    customer_charge_usd: r.customer_charge_usd,
    margin_usd: r.margin_usd,
  }));

  const totals = buckets.reduce(
    (acc, b) => ({
      calls: acc.calls + b.calls,
      vendor_cost_usd: acc.vendor_cost_usd + b.vendor_cost_usd,
      customer_charge_usd: acc.customer_charge_usd + b.customer_charge_usd,
      margin_usd: acc.margin_usd + b.margin_usd,
    }),
    { calls: 0, vendor_cost_usd: 0, customer_charge_usd: 0, margin_usd: 0 },
  );

  return c.json({ buckets, totals });
});

export default app;
