-- Brandnana local SQLite schema (initial).
-- This file is the source of truth. Keep types.ts in sync.
-- PRAGMA settings (journal_mode=WAL, foreign_keys=ON) are applied at
-- connection-open time by the CLI, not in migrations (cannot run inside
-- a transaction).

CREATE TABLE IF NOT EXISTS brands (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL UNIQUE,
  name TEXT,
  logo_url TEXT,
  palette_json TEXT,       -- JSON array of hex colors
  descriptors_json TEXT,   -- JSON object: tone, voice, descriptors[]
  fetched_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
  id TEXT PRIMARY KEY,
  brand_id TEXT NOT NULL REFERENCES brands(id) ON DELETE CASCADE,
  external_id TEXT,        -- e.g., Shopify product ID
  url TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  price_cents INTEGER,
  currency TEXT,
  available INTEGER NOT NULL DEFAULT 1,
  platform TEXT NOT NULL,  -- shopify|woocommerce|bigcommerce|...
  raw_json TEXT,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  UNIQUE(brand_id, url)
);
CREATE INDEX IF NOT EXISTS idx_products_brand ON products(brand_id);
CREATE INDEX IF NOT EXISTS idx_products_platform ON products(platform);

CREATE TABLE IF NOT EXISTS product_images (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  url TEXT NOT NULL,
  alt TEXT,
  width INTEGER,
  height INTEGER,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images(product_id);

CREATE TABLE IF NOT EXISTS ads (
  id TEXT PRIMARY KEY,
  brand_id TEXT REFERENCES brands(id) ON DELETE SET NULL,
  source TEXT NOT NULL,    -- meta|tiktok|google|manual
  external_id TEXT NOT NULL,
  url TEXT,
  body TEXT,
  cta TEXT,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  raw_json TEXT,
  UNIQUE(source, external_id)
);
CREATE INDEX IF NOT EXISTS idx_ads_brand ON ads(brand_id);
CREATE INDEX IF NOT EXISTS idx_ads_source ON ads(source);

CREATE TABLE IF NOT EXISTS ad_media (
  id TEXT PRIMARY KEY,
  ad_id TEXT NOT NULL REFERENCES ads(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,      -- image|video
  url TEXT NOT NULL,
  poster_url TEXT,
  width INTEGER,
  height INTEGER
);
CREATE INDEX IF NOT EXISTS idx_ad_media_ad ON ad_media(ad_id);

CREATE TABLE IF NOT EXISTS pages (
  id TEXT PRIMARY KEY,
  brand_id TEXT REFERENCES brands(id) ON DELETE SET NULL,
  url TEXT NOT NULL,
  html_r2_key TEXT,        -- pointer to R2-stored raw HTML
  fetched_at INTEGER NOT NULL,
  status INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pages_brand ON pages(brand_id);

CREATE TABLE IF NOT EXISTS sync_runs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,      -- ads|catalog|brand
  source TEXT NOT NULL,
  brand_id TEXT REFERENCES brands(id) ON DELETE SET NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  ok INTEGER NOT NULL DEFAULT 0,
  error TEXT
);
