-- Users + API keys.
--
-- Sign-in is GitHub OAuth device flow. The server upserts a `users` row
-- keyed by `github_id` after validating the device-flow access token.
-- API keys are stored hashed (sha256); only the first 8 chars of the
-- cleartext are kept in `prefix` so the CLI can identify the key in
-- listings without exposing it.

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  github_id INTEGER UNIQUE,
  github_login TEXT,
  email TEXT,
  name TEXT,
  avatar_url TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_github_id ON users(github_id);

CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hash TEXT NOT NULL UNIQUE,        -- sha256(cleartext) hex
  prefix TEXT NOT NULL,             -- first 8 chars of cleartext, for UX
  label TEXT,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_api_keys_user ON api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(hash);
