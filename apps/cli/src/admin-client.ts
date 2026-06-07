// Typed HTTP wrapper for admin.brandnana.net
//
// Auth: reads BRANDNANA_ADMIN_KEY from env, then falls back to
// ~/.config/brandnana/admin-key (plain text, no trailing newline required).
//
// Every method throws on non-2xx with a structured AdminError.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const ADMIN_BASE_URL = "https://admin.brandnana.net";

// ── Auth ──────────────────────────────────────────────────────────────────────

function adminKeyFilePath(): string {
  const base = process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config");
  return join(base, "brandnana", "admin-key");
}

export function getAdminKey(): string | null {
  if (process.env.BRANDNANA_ADMIN_KEY) {
    return process.env.BRANDNANA_ADMIN_KEY.trim();
  }
  const path = adminKeyFilePath();
  if (existsSync(path)) {
    return readFileSync(path, "utf8").trim();
  }
  return null;
}

export function requireAdminKey(): string {
  const key = getAdminKey();
  if (!key) {
    process.stderr.write(
      `brandnana: Admin operations require BRANDNANA_ADMIN_KEY env or ${adminKeyFilePath()} file.\n`,
    );
    process.exit(1);
  }
  return key;
}

// ── Error ─────────────────────────────────────────────────────────────────────

export class AdminError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: string,
  ) {
    super(`Admin API ${status}: ${body.slice(0, 200)}`);
    this.name = "AdminError";
  }
}

// ── Low-level fetch ───────────────────────────────────────────────────────────

async function adminFetch<T>(
  method: "GET" | "POST" | "PATCH" | "DELETE",
  path: string,
  key: string,
  opts?: { query?: Record<string, string | undefined>; body?: unknown },
): Promise<T> {
  let url = `${ADMIN_BASE_URL}${path}`;
  if (opts?.query) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(opts.query)) {
      if (v !== undefined && v !== "") qs.set(k, v);
    }
    const qsStr = qs.toString();
    if (qsStr) url = `${url}?${qsStr}`;
  }

  const headers: Record<string, string> = {
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
  };

  const init: RequestInit = {
    method,
    headers,
    body: opts?.body !== undefined ? JSON.stringify(opts.body) : undefined,
  };

  const resp = await fetch(url, init);
  const text = await resp.text();

  if (!resp.ok) {
    throw new AdminError(resp.status, text);
  }

  try {
    return JSON.parse(text) as T;
  } catch {
    return text as unknown as T;
  }
}

// ── Types ─────────────────────────────────────────────────────────────────────

export interface SpendBucket {
  key: string;
  calls: number;
  vendor_cost_usd: number;
  customer_charge_usd: number;
  margin_usd: number;
}

export interface SpendTotals {
  calls: number;
  vendor_cost_usd: number;
  customer_charge_usd: number;
  margin_usd: number;
}

export interface SpendResponse {
  buckets: SpendBucket[];
  totals: SpendTotals;
}

export interface VendorRateCard {
  id: string;
  provider: string;
  model?: string | null;
  unit: string;
  price_usd_per_unit: number;
  effective_from?: number;
  effective_to?: number | null;
  source?: string | null;
  notes?: string | null;
  created_at: number | string;
  created_by?: string;
}

export interface CustomerRateCard {
  id: string;
  verb_id: string;
  price_strategy: string;
  markup_multiplier?: number | null;
  fixed_price_usd?: number | null;
  unit?: string | null;
  tag?: string | null;
  notes?: string | null;
  effective_from?: number;
  supersedes_id?: string | null;
  created_at: number | string;
  created_by?: string;
}

export interface RatesResponse {
  vendor: VendorRateCard[];
  customer: CustomerRateCard[];
}

export interface SimulateLineItem {
  provider: string;
  model?: string;
  unit?: string;
  operation?: string;
  quantity?: number;
  estimated_units?: number;
  unit_cost_usd?: number;
  price_usd_per_unit?: number;
  subtotal_usd?: number;
  total_usd?: number;
}

export interface SimulateResponse {
  verb_id?: string;
  vendor_cost_usd?: number;
  customer_charge_usd?: number;
  margin_usd?: number;
  projected_vendor_cost_usd?: number;
  projected_customer_charge_usd?: number;
  projected_margin_usd?: number;
  rate_card_id?: string;
  rate_card_tag?: string;
  markup_label?: string;
  breakdown?: SimulateLineItem[];
  note?: string;
}

export interface EventItem {
  id: string;
  verb_id: string;
  source?: string | null;
  status: string;
  duration_ms?: number | null;
  vendor_cost_usd?: number | null;
  customer_charge_usd?: number | null;
  margin_usd?: number | null;
  ts: string | number;
  account_id?: string;
  error_code?: string | null;
  error_message?: string | null;
}

export interface EventsResponse {
  items: EventItem[];
  next_cursor?: string;
}

export interface RateCardDraft {
  verb_id: string;
  price_strategy: "markup_multiplier" | "fixed_per_call" | "fixed_per_unit";
  markup_multiplier?: number;
  fixed_price_usd?: number;
  unit?: string;
  notes?: string;
  effective_from?: number;
  supersedes_id?: string;
}

export interface HealthResponse {
  status: string;
  [key: string]: unknown;
}

// ── Client ────────────────────────────────────────────────────────────────────

export class AdminClient {
  constructor(private readonly key: string) {}

  async spend(opts?: {
    from?: string;
    to?: string;
    group_by?: string;
  }): Promise<SpendResponse> {
    return adminFetch<SpendResponse>("GET", "/spend", this.key, {
      query: {
        from: opts?.from,
        to: opts?.to,
        group_by: opts?.group_by,
      },
    });
  }

  async rates(opts?: { tag?: string; verb?: string }): Promise<RatesResponse> {
    return adminFetch<RatesResponse>("GET", "/rates", this.key, {
      query: {
        tag: opts?.tag,
        verb: opts?.verb,
      },
    });
  }

  async ratesPropose(draft: RateCardDraft): Promise<CustomerRateCard> {
    return adminFetch<CustomerRateCard>("POST", "/rates", this.key, { body: draft });
  }

  async ratesTag(id: string, tag: string): Promise<unknown> {
    return adminFetch<unknown>("POST", `/rates/${encodeURIComponent(id)}/tag`, this.key, {
      body: { tag },
    });
  }

  async simulate(opts: {
    verb_id: string;
    payload?: unknown;
    customer_rate_card_id?: string;
    customer_rate_card_tag?: string;
  }): Promise<SimulateResponse> {
    return adminFetch<SimulateResponse>("POST", "/simulate", this.key, { body: opts });
  }

  async events(opts?: {
    verb?: string;
    from?: string;
    to?: string;
    limit?: number;
    cursor?: string;
  }): Promise<EventsResponse> {
    return adminFetch<EventsResponse>("GET", "/events", this.key, {
      query: {
        verb: opts?.verb,
        from: opts?.from,
        to: opts?.to,
        limit: opts?.limit !== undefined ? String(opts.limit) : undefined,
        cursor: opts?.cursor,
      },
    });
  }

  async health(): Promise<HealthResponse> {
    // Health endpoint needs no auth — but we pass the key anyway if present.
    const resp = await fetch(`${ADMIN_BASE_URL}/health`, {
      headers: { Authorization: `Bearer ${this.key}` },
    });
    const text = await resp.text();
    try {
      return JSON.parse(text) as HealthResponse;
    } catch {
      return { status: text };
    }
  }
}

export function makeAdminClient(): AdminClient {
  return new AdminClient(requireAdminKey());
}

// For health (no auth required)
export async function fetchHealth(): Promise<HealthResponse> {
  const resp = await fetch(`${ADMIN_BASE_URL}/health`);
  const text = await resp.text();
  try {
    return JSON.parse(text) as HealthResponse;
  } catch {
    return { status: text };
  }
}
