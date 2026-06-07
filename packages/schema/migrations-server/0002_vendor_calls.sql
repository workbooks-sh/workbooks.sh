-- Vendor call telemetry + rate limiting (apps/api/src/vendor.ts).
--
-- vendor_calls is append-only audit; we never update rows. Used for
-- per-tenant cost rollups (ad-3ul.23) and debugging.
-- vendor_rate_limit is a sliding-window counter keyed by
-- (tenant, provider, window_start) where window_start is the unix-ms
-- timestamp of the current 60s window.

CREATE TABLE IF NOT EXISTS vendor_calls (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  tenant TEXT NOT NULL,
  url TEXT NOT NULL,
  status INTEGER NOT NULL,
  cache_state TEXT NOT NULL,        -- hit|miss|bypass
  bytes INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  metadata TEXT,                    -- JSON blob
  called_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vendor_calls_tenant ON vendor_calls(tenant);
CREATE INDEX IF NOT EXISTS idx_vendor_calls_provider ON vendor_calls(provider);
CREATE INDEX IF NOT EXISTS idx_vendor_calls_called_at ON vendor_calls(called_at);

CREATE TABLE IF NOT EXISTS vendor_rate_limit (
  tenant TEXT NOT NULL,
  provider TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (tenant, provider, window_start)
);
