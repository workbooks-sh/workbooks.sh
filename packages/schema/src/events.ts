export interface VendorCall {
  provider: string;      // 'openrouter' | 'meta' | 'tiktok' | 'exa' | 'firecrawl' | ...
  model?: string;        // for LLM calls
  units: number;
  unit_cost_usd: number;
  total_usd: number;
}

export interface EventRow {
  id: string;
  ts: number;
  account_id: string;
  verb_id: string;
  source: 'cli' | 'mcp' | 'portal' | 'api' | 'agent' | 'simulation';
  duration_ms: number;
  status: 'ok' | 'error';
  error_code?: string | null;
  error_message?: string | null;
  vendor_calls?: VendorCall[] | null;     // parsed; stored as JSON in DB
  vendor_cost_usd: number;
  customer_charge_usd?: number | null;
  margin_usd?: number | null;
  customer_rate_card_id?: string | null;
  customer_rate_card_tag?: string | null;
  request_payload_hash?: string | null;
  response_payload_hash?: string | null;
}

export interface EventInsert extends Omit<EventRow, 'customer_charge_usd' | 'margin_usd' | 'customer_rate_card_id' | 'customer_rate_card_tag'> {
  // customer_* fields filled in by the margin pass (wb-ew65.5)
}
