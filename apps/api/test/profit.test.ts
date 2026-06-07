// Unit tests for the profit/margin calculator.
//
// Run with: bun test test/profit.test.ts  (from substrates/brandnana/apps/api/)

import { describe, expect, it } from 'bun:test';
import { computePricing } from '../src/profit.js';
import type { VendorCall } from '@brandnana/schema/events';
import type { CustomerRateCard } from '@brandnana/schema/rates';

// ── Minimal D1Database stub ───────────────────────────────────────────────────
// computePricing only calls db via findCustomerRate, which runs one prepared
// statement and calls .first(). We stub the full chain here.

function makeDb(card: CustomerRateCard | null): D1Database {
  const stmt = {
    bind: (..._args: unknown[]) => stmt,
    first: async <T>(): Promise<T | null> => card as T | null,
    run: async () => ({ success: true }),
    all: async <T>() => ({ results: [] as T[], success: true }),
  };

  return {
    prepare: (_sql: string) => stmt,
    batch: async () => [],
    dump: async () => new ArrayBuffer(0),
    exec: async () => ({ count: 0, duration: 0 }),
  } as unknown as D1Database;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const NOW = 1_700_000_000_000; // fixed ms timestamp

function vendorCall(units: number, unitCost: number): VendorCall {
  return {
    provider: 'openrouter',
    model: 'meta-llama/llama-3.2-3b-instruct',
    units,
    unit_cost_usd: unitCost,
    total_usd: units * unitCost,
  };
}

function card(overrides: Partial<CustomerRateCard>): CustomerRateCard {
  return {
    id: 'card-1',
    tag: null,
    verb_id: 'resolve',
    price_strategy: 'markup_multiplier',
    markup_multiplier: 1.5,
    fixed_price_usd: null,
    unit: null,
    notes: null,
    effective_from: NOW - 10_000,
    supersedes_id: null,
    created_at: NOW - 10_000,
    created_by: 'test',
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('computePricing — markup_multiplier strategy', () => {
  it('sums vendor costs and applies multiplier', async () => {
    const calls: VendorCall[] = [
      vendorCall(1000, 0.00006),  // total_usd = 0.06
      vendorCall(500, 0.00012),   // total_usd = 0.06
    ];
    const db = makeDb(card({ markup_multiplier: 2.0 }));

    const result = await computePricing(db, calls, 'resolve', NOW);

    expect(result.vendor_cost_usd).toBeCloseTo(0.12, 6);
    expect(result.customer_charge_usd).toBeCloseTo(0.24, 6); // 0.12 × 2
    expect(result.margin_usd).toBeCloseTo(0.12, 6);
    expect(result.customer_rate_card_id).toBe('card-1');
    expect(result.customer_rate_card_tag).toBeNull();
  });

  it('charge is 0 when vendor_cost is 0 (empty vendor_calls)', async () => {
    const db = makeDb(card({ markup_multiplier: 1.5 }));

    const result = await computePricing(db, [], 'resolve', NOW);

    expect(result.vendor_cost_usd).toBe(0);
    expect(result.customer_charge_usd).toBe(0);
    expect(result.margin_usd).toBe(0);
    expect(result.customer_rate_card_id).toBe('card-1');
  });
});

describe('computePricing — fixed_per_call strategy', () => {
  it('returns fixed_price_usd regardless of vendor calls', async () => {
    const db = makeDb(card({ price_strategy: 'fixed_per_call', fixed_price_usd: 0.05 }));

    const result = await computePricing(db, [], 'resolve', NOW);

    expect(result.vendor_cost_usd).toBe(0);
    expect(result.customer_charge_usd).toBe(0.05);
    expect(result.margin_usd).toBe(0.05);
    expect(result.customer_rate_card_id).toBe('card-1');
  });

  it('margin = fixed_price - vendor_cost when vendor calls are present', async () => {
    const calls: VendorCall[] = [vendorCall(1, 0.01)];
    const db = makeDb(card({ price_strategy: 'fixed_per_call', fixed_price_usd: 0.05 }));

    const result = await computePricing(db, calls, 'resolve', NOW);

    expect(result.vendor_cost_usd).toBeCloseTo(0.01, 6);
    expect(result.customer_charge_usd).toBe(0.05);
    expect(result.margin_usd).toBeCloseTo(0.04, 6);
  });
});

describe('computePricing — fixed_per_unit strategy', () => {
  it('multiplies sum of units by fixed_price_usd', async () => {
    const calls: VendorCall[] = [
      vendorCall(100, 0.001),
      vendorCall(200, 0.001),
    ];
    const db = makeDb(
      card({ price_strategy: 'fixed_per_unit', fixed_price_usd: 0.002 }),
    );

    const result = await computePricing(db, calls, 'resolve', NOW);

    // total units = 300; charge = 300 × 0.002 = 0.6
    expect(result.customer_charge_usd).toBeCloseTo(0.6, 6);
    expect(result.vendor_cost_usd).toBeCloseTo(0.3, 6); // 300 × 0.001
    expect(result.margin_usd).toBeCloseTo(0.3, 6);
  });
});

describe('computePricing — no matching rate card', () => {
  it('returns null for all customer fields', async () => {
    const db = makeDb(null); // findCustomerRate returns null

    const result = await computePricing(db, [vendorCall(1, 0.01)], 'unknown-verb', NOW);

    expect(result.vendor_cost_usd).toBeCloseTo(0.01, 6);
    expect(result.customer_charge_usd).toBeNull();
    expect(result.margin_usd).toBeNull();
    expect(result.customer_rate_card_id).toBeNull();
    expect(result.customer_rate_card_tag).toBeNull();
  });

  it('vendor_cost is still summed even without a card', async () => {
    const db = makeDb(null);
    const calls: VendorCall[] = [
      vendorCall(10, 0.005),
      vendorCall(20, 0.005),
    ];

    const result = await computePricing(db, calls, 'unknown-verb', NOW);

    expect(result.vendor_cost_usd).toBeCloseTo(0.15, 6);
  });
});

describe('computePricing — tagged rate card', () => {
  it('returns card tag when the card has a tag set', async () => {
    const taggedCard = card({ tag: 'v2024-q4', markup_multiplier: 1.2 });
    const db = makeDb(taggedCard);

    const result = await computePricing(db, [], 'resolve', NOW, 'v2024-q4');

    expect(result.customer_rate_card_tag).toBe('v2024-q4');
    expect(result.customer_rate_card_id).toBe('card-1');
  });
});
