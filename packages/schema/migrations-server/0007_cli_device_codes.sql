-- CLI device-flow auth — short-lived codes the CLI exchanges for a real API key.
--
-- Lifecycle:
--   1. CLI calls /v1/auth/cli/start → row created, status='pending'
--   2. User opens /cli/connect?code=<user_code> in browser, signs in via Clerk
--   3. Approve button POSTs Clerk session JWT + user_code to /v1/auth/cli/approve
--      → row updated: status='approved', user_id + api_key set
--   4. CLI polls /v1/auth/cli/poll?device_code=... until status='approved',
--      then receives the API key cleartext exactly once
--   5. Row purged or marked status='consumed' after first poll-after-approve

CREATE TABLE IF NOT EXISTS cli_device_codes (
  device_code   TEXT PRIMARY KEY,             -- ~32-char opaque, the CLI's secret
  user_code     TEXT NOT NULL UNIQUE,         -- ~8-char human-friendly, e.g. ABCD-1234
  user_id       TEXT REFERENCES users(id),    -- set on approve
  api_key_id    TEXT,                         -- set on approve, FK to api_keys.id
  api_key_text  TEXT,                         -- cleartext, returned exactly once
  status        TEXT NOT NULL DEFAULT 'pending', -- pending | approved | consumed | expired | denied
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,             -- created_at + 10min
  client_info   TEXT,                         -- JSON: { hostname, platform, cli_version }
  approved_at   INTEGER,
  consumed_at   INTEGER
);

CREATE INDEX IF NOT EXISTS idx_cli_device_codes_user_code ON cli_device_codes(user_code);
CREATE INDEX IF NOT EXISTS idx_cli_device_codes_status ON cli_device_codes(status);
CREATE INDEX IF NOT EXISTS idx_cli_device_codes_expires ON cli_device_codes(expires_at);
