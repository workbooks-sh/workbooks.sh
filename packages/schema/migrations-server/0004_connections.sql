-- Per-user provider connections (OAuth tokens).
--
-- One row per (user, provider). access_token + refresh_token are
-- stored as cleartext for now — Workers/D1 doesn't expose KMS, and the
-- alternatives (KV-encrypted, secret-store binding) are heavier. Treat
-- D1 as the security boundary.
--
-- pending_oauth_sessions handles the CLI ↔ browser hand-off: CLI
-- creates a session id, browser carries it in `state`, server stores
-- the resulting tokens against the session, CLI polls.

CREATE TABLE IF NOT EXISTS provider_connections (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,                -- 'meta' | 'tiktok' | 'google'
  account_id TEXT,                       -- provider's user id (e.g. fb user id)
  account_name TEXT,
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  scope TEXT,
  token_type TEXT,
  expires_at INTEGER,                    -- unix ms, NULL = long-lived/no expiry
  connected_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  raw_json TEXT,
  UNIQUE(user_id, provider)
);
CREATE INDEX IF NOT EXISTS idx_provider_connections_user ON provider_connections(user_id);

CREATE TABLE IF NOT EXISTS pending_oauth_sessions (
  id TEXT PRIMARY KEY,                   -- session id, also used as `state`
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'connected' | 'error'
  connection_id TEXT REFERENCES provider_connections(id) ON DELETE SET NULL,
  error TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_oauth_sessions_status ON pending_oauth_sessions(status);
