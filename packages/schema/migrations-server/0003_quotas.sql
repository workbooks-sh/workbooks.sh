-- Per-tenant quotas (api_key level) for our own API surface.
--
-- api_key_rate_limit is a sliding-window counter mirroring
-- vendor_rate_limit but for inbound /api requests. Per-key default cap
-- is 600 req/min (overridable via api_keys.rate_limit_per_min).

ALTER TABLE api_keys ADD COLUMN rate_limit_per_min INTEGER NOT NULL DEFAULT 600;

CREATE TABLE IF NOT EXISTS api_key_rate_limit (
  api_key_id TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (api_key_id, window_start)
);
