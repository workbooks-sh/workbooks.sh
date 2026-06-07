-- Canonical event log for every brandnana API call.
-- Source of truth for cost, profit, activity, audit.

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,                    -- uuid v7 preferred (sortable by time)
  ts INTEGER NOT NULL,                    -- ms since epoch
  account_id TEXT NOT NULL,               -- the API key's owning account
  verb_id TEXT NOT NULL,                  -- e.g. 'brand.fetch', 'ads.search'
  source TEXT NOT NULL,                   -- 'cli' | 'mcp' | 'portal' | 'api' | 'agent' | 'simulation'
  duration_ms INTEGER NOT NULL,
  status TEXT NOT NULL,                   -- 'ok' | 'error'
  error_code TEXT,                        -- nullable; only set if status='error'
  error_message TEXT,
  vendor_calls TEXT,                      -- JSON array of {provider, model, units, unit_cost_usd, total_usd}
  vendor_cost_usd REAL NOT NULL DEFAULT 0,
  customer_charge_usd REAL,               -- nullable until rate card resolved
  margin_usd REAL,                        -- nullable; = customer_charge - vendor_cost
  customer_rate_card_id TEXT,             -- fk to customer_rate_cards.id (table from .2)
  customer_rate_card_tag TEXT,            -- snapshot of which tag was active
  request_payload_hash TEXT,              -- sha256, 16 hex chars
  response_payload_hash TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
CREATE INDEX IF NOT EXISTS idx_events_account_ts ON events(account_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_events_verb_ts ON events(verb_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_events_status_ts ON events(status, ts DESC);
