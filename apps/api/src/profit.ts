// Profit/margin calculator for Brandnana events.
//
// Two entry points:
//   computePricing  — pure calculation (no DB writes)
//   priceAndUpdateEvent — compute + UPDATE events row in one shot
//
// Strategy dispatch:
//   markup_multiplier  → customer_charge = vendor_cost × multiplier
//   fixed_per_call     → customer_charge = fixed_price_usd (regardless of calls)
//   fixed_per_unit     → customer_charge = sum(vendor_calls[].units) × fixed_price_usd
//
// When no customer rate card matches, all customer_* fields return null.

import type { VendorCall } from '@brandnana/schema/events';
import { findCustomerRate } from './rates.js';

export interface PriceResult {
  vendor_cost_usd: number;
  customer_charge_usd: number | null;
  margin_usd: number | null;
  customer_rate_card_id: string | null;
  customer_rate_card_tag: string | null;
}

/**
 * Given vendor calls + verb + ts, compute the totals.
 * Returns nulls for customer side if no rate card matches.
 */
export async function computePricing(
  db: D1Database,
  vendor_calls: VendorCall[],
  verb_id: string,
  ts: number,
  requested_tag?: string,
): Promise<PriceResult> {
  // 1. Vendor cost: sum of all vendor call totals.
  const vendor_cost_usd = vendor_calls.reduce((sum, c) => sum + c.total_usd, 0);

  // 2. Find matching customer rate card.
  const card = await findCustomerRate(db, verb_id, ts, requested_tag);

  if (!card) {
    return {
      vendor_cost_usd,
      customer_charge_usd: null,
      margin_usd: null,
      customer_rate_card_id: null,
      customer_rate_card_tag: null,
    };
  }

  // 3. Compute customer charge per strategy.
  let customer_charge_usd: number;

  switch (card.price_strategy) {
    case 'markup_multiplier': {
      const multiplier = card.markup_multiplier ?? 1;
      customer_charge_usd = vendor_cost_usd * multiplier;
      break;
    }
    case 'fixed_per_call': {
      customer_charge_usd = card.fixed_price_usd ?? 0;
      break;
    }
    case 'fixed_per_unit': {
      const total_units = vendor_calls.reduce((sum, c) => sum + c.units, 0);
      customer_charge_usd = total_units * (card.fixed_price_usd ?? 0);
      break;
    }
    default: {
      // Unknown strategy — treat as zero so we never silently overcounting.
      customer_charge_usd = 0;
    }
  }

  const margin_usd = customer_charge_usd - vendor_cost_usd;

  return {
    vendor_cost_usd,
    customer_charge_usd,
    margin_usd,
    customer_rate_card_id: card.id,
    customer_rate_card_tag: card.tag ?? null,
  };
}

/**
 * Run BOTH: compute pricing + update the event row with the result.
 * Used by middleware as the post-vendor-calls step.
 */
export async function priceAndUpdateEvent(
  db: D1Database,
  event_id: string,
  vendor_calls: VendorCall[],
  verb_id: string,
  ts: number,
  requested_tag?: string,
): Promise<PriceResult> {
  const result = await computePricing(db, vendor_calls, verb_id, ts, requested_tag);

  await db
    .prepare(
      `UPDATE events
       SET vendor_calls = ?,
           vendor_cost_usd = ?,
           customer_charge_usd = ?,
           margin_usd = ?,
           customer_rate_card_id = ?,
           customer_rate_card_tag = ?
       WHERE id = ?`,
    )
    .bind(
      vendor_calls.length > 0 ? JSON.stringify(vendor_calls) : null,
      result.vendor_cost_usd,
      result.customer_charge_usd,
      result.margin_usd,
      result.customer_rate_card_id,
      result.customer_rate_card_tag,
      event_id,
    )
    .run();

  return result;
}
