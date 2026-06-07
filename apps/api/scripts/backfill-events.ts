#!/usr/bin/env bun
// Backfill script: compute and emit SQL UPDATE statements for events that are
// missing customer_charge_usd. Idempotent — re-running is safe.
//
// This script does NOT connect to D1 directly (bun has no D1 driver).
// Instead it reads events + rate cards via wrangler d1 execute and emits
// SQL UPDATE statements to stdout, which you pipe through wrangler.
//
// Usage (remote production):
//   bun run scripts/backfill-events.ts | wrangler d1 execute brandnana --remote --file=-
//
// Usage (local dev):
//   bun run scripts/backfill-events.ts | wrangler d1 execute brandnana --file=-
//
// The emitted SQL is idempotent — running it twice is safe (UPDATE is a no-op
// for rows whose customer_charge_usd already matches what we'd compute, and
// the WHERE clause only targets NULL rows, so already-priced rows are skipped).
//
// Notes:
//   - Rates are resolved as of each event's original ts (not "now").
//   - Events with vendor_calls are priced via the VendorCall strategy.
//   - Events with NULL vendor_calls get customer_charge via fixed_per_call or
//     markup × 0 = 0 (the card is pinned for audit trail purposes).
//   - If no rate card matches an event's verb_id at its ts, the row is skipped
//     (customer_charge_usd remains NULL — that's intentional; it means "no
//     pricing applicable", not "zero").

import { execSync } from 'node:child_process';
import type { VendorCall } from '@brandnana/schema/events';

interface RawEvent {
  id: string;
  ts: number;
  verb_id: string;
  vendor_calls: string | null;
  vendor_cost_usd: number;
}

interface RawRateCard {
  id: string;
  tag: string | null;
  verb_id: string;
  price_strategy: 'markup_multiplier' | 'fixed_per_call' | 'fixed_per_unit';
  markup_multiplier: number | null;
  fixed_price_usd: number | null;
  effective_from: number;
}

function runQuery(sql: string, remote = false): unknown[] {
  const flag = remote ? '--remote' : '';
  // wrangler d1 execute --json emits newline-separated JSON objects.
  const raw = execSync(
    `wrangler d1 execute brandnana ${flag} --json --command=${JSON.stringify(sql)}`,
    { encoding: 'utf8' },
  );
  // wrangler wraps results in an array of result objects; grab the first.
  const parsed = JSON.parse(raw) as Array<{ results?: unknown[] }>;
  return parsed[0]?.results ?? [];
}

function findBestRate(
  cards: RawRateCard[],
  verb_id: string,
  ts: number,
  tag?: string,
): RawRateCard | null {
  const active = cards.filter((c) => c.effective_from <= ts);

  const candidates: Array<() => RawRateCard | undefined> = [
    // 1. Tagged exact
    ...(tag ? [() => active.find((c) => c.tag === tag && c.verb_id === verb_id)] : []),
    // 2. Tagged catch-all
    ...(tag ? [() => active.find((c) => c.tag === tag && c.verb_id === '*')] : []),
    // 3. Untagged exact
    () => active.find((c) => c.tag == null && c.verb_id === verb_id),
    // 4. Untagged catch-all
    () => active.find((c) => c.tag == null && c.verb_id === '*'),
  ];

  for (const fn of candidates) {
    const match = fn();
    if (match) return match;
  }
  return null;
}

function computeCharge(
  card: RawRateCard,
  vendorCost: number,
  vendorCalls: VendorCall[],
): number {
  switch (card.price_strategy) {
    case 'markup_multiplier':
      return vendorCost * (card.markup_multiplier ?? 1);
    case 'fixed_per_call':
      return card.fixed_price_usd ?? 0;
    case 'fixed_per_unit': {
      const totalUnits = vendorCalls.reduce((sum, c) => sum + c.units, 0);
      return totalUnits * (card.fixed_price_usd ?? 0);
    }
    default:
      return 0;
  }
}

function main() {
  const remote = process.argv.includes('--remote');

  // Fetch all events with NULL customer_charge_usd.
  const events = runQuery(
    `SELECT id, ts, verb_id, vendor_calls, vendor_cost_usd
     FROM events
     WHERE customer_charge_usd IS NULL
     ORDER BY ts ASC`,
    remote,
  ) as RawEvent[];

  if (events.length === 0) {
    console.error('No events to backfill.');
    process.exit(0);
  }

  console.error(`Backfilling ${events.length} event(s)…`);

  // Fetch all customer rate cards once (cheap — there are few).
  const cards = runQuery(
    `SELECT id, tag, verb_id, price_strategy, markup_multiplier, fixed_price_usd, effective_from
     FROM customer_rate_cards
     ORDER BY effective_from DESC`,
    remote,
  ) as RawRateCard[];

  const statements: string[] = [];

  for (const event of events) {
    const card = findBestRate(cards, event.verb_id, event.ts);
    if (!card) continue; // no pricing applicable — leave NULL

    const vendorCalls: VendorCall[] = event.vendor_calls
      ? (JSON.parse(event.vendor_calls) as VendorCall[])
      : [];

    const vendorCost = event.vendor_cost_usd;
    const customerCharge = computeCharge(card, vendorCost, vendorCalls);
    const margin = customerCharge - vendorCost;
    const cardTag = card.tag ? `'${card.tag.replace(/'/g, "''")}'` : 'NULL';

    statements.push(
      `UPDATE events SET customer_charge_usd = ${customerCharge}, margin_usd = ${margin}, ` +
        `customer_rate_card_id = '${card.id}', customer_rate_card_tag = ${cardTag} ` +
        `WHERE id = '${event.id}';`,
    );
  }

  if (statements.length === 0) {
    console.error('No events matched a rate card. Nothing to emit.');
    process.exit(0);
  }

  console.error(`Emitting ${statements.length} UPDATE statement(s) to stdout…`);
  console.log(statements.join('\n'));
}

main();
