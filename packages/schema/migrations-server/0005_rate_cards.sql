-- Rate card schema: vendor costs + customer pricing.
--
-- vendor_rate_cards: what we pay each provider per unit. Append-only by
-- convention (effective_to closes a card when the vendor changes prices).
--
-- customer_rate_cards: what we charge customers per verb. Immutability is
-- enforced at the application layer (apps/api/src/rates.ts):
--   - A row with tag=NULL is an untagged draft — freely mutable.
--   - A row with a non-null tag is FROZEN. To change a tagged card, insert
--     a new row with the same tag and set supersedes_id to the previous row.
--   - tagCustomerRate() is the only function that may set a tag.

-- Vendor side: what we pay vendors.
CREATE TABLE IF NOT EXISTS vendor_rate_cards (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,                 -- 'openrouter' | 'meta' | 'tiktok' | 'exa' | 'firecrawl' | 'e2b' | 'brandfetch' | 'logo_dev' | 'scrapecreators' | 'context_dev' | ...
  model TEXT,                             -- nullable; e.g. 'gemini-3.5-flash', or null for non-AI vendors
  unit TEXT NOT NULL,                     -- 'token_input' | 'token_output' | 'request' | 'second' | 'image' | 'mb'
  price_usd_per_unit REAL NOT NULL,
  effective_from INTEGER NOT NULL,        -- ms since epoch
  effective_to INTEGER,                   -- nullable; null = still active
  source TEXT NOT NULL,                   -- 'vendor_docs' | 'observed' | 'manual'
  notes TEXT,
  created_at INTEGER NOT NULL,
  created_by TEXT                         -- 'system' | account_id
);

CREATE INDEX IF NOT EXISTS idx_vrc_provider_active ON vendor_rate_cards(provider, effective_from DESC) WHERE effective_to IS NULL;
CREATE INDEX IF NOT EXISTS idx_vrc_provider_model ON vendor_rate_cards(provider, model);

-- Customer side: what we charge customers.
-- A row with a tag (non-null) is IMMUTABLE. Updates create a new row with the
-- same tag, pointing the supersedes_id at the previous one — application logic
-- enforces this; SQLite doesn't have native row immutability.
CREATE TABLE IF NOT EXISTS customer_rate_cards (
  id TEXT PRIMARY KEY,
  tag TEXT,                               -- nullable; null = untagged draft
  verb_id TEXT NOT NULL,                  -- 'brand.fetch' | 'ads.search' | '*' for catch-all
  price_strategy TEXT NOT NULL,           -- 'markup_multiplier' | 'fixed_per_call' | 'fixed_per_unit'
  markup_multiplier REAL,                 -- used when price_strategy='markup_multiplier'
  fixed_price_usd REAL,                   -- used when price_strategy='fixed_per_call' or 'fixed_per_unit'
  unit TEXT,                              -- for fixed_per_unit: 'token' | 'request' | ...
  notes TEXT,
  effective_from INTEGER NOT NULL,
  supersedes_id TEXT,                     -- fk to previous card (same tag)
  created_at INTEGER NOT NULL,
  created_by TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_crc_tag ON customer_rate_cards(tag);
CREATE INDEX IF NOT EXISTS idx_crc_verb_active ON customer_rate_cards(verb_id, effective_from DESC);
