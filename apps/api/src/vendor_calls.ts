// Vendor call pricing helper.
//
// Gateway and vendor modules call priceVendorCall() after a vendor request
// completes. They pass (provider, model, unit, units) and get back a VendorCall
// with unit_cost_usd + total_usd filled in from the active vendor rate card.
//
// When no rate card matches, unit_cost_usd is 0 (no pricing data yet) so the
// call is still recorded for volume telemetry without inflating costs.

import type { VendorCall } from '@brandnana/schema/events';
import { findVendorRate } from './rates.js';

/**
 * Resolve a vendor call's pricing given its raw shape (provider, model, units).
 * Looks up the active vendor rate card and computes total_usd.
 * Returns the VendorCall with unit_cost_usd + total_usd filled.
 *
 * When no rate card exists for (provider, model, unit) at ts, unit_cost_usd
 * and total_usd are both 0 — the call is still returned so callers can
 * include it in vendor_calls for volume tracking.
 */
export async function priceVendorCall(
  db: D1Database,
  provider: string,
  model: string | null,
  unit: 'token_input' | 'token_output' | 'request' | 'second' | 'image' | 'mb',
  units: number,
  ts: number,
): Promise<VendorCall> {
  const rate = await findVendorRate(db, provider, model, unit, ts);

  const unit_cost_usd = rate?.price_usd_per_unit ?? 0;
  const total_usd = unit_cost_usd * units;

  return {
    provider,
    ...(model != null ? { model } : {}),
    units,
    unit_cost_usd,
    total_usd,
  };
}
