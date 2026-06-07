-- Useful queries against an Brandnana SQLite. Drop into the agent's tool
-- usage examples or run interactively with `sqlite3 .brandnana/brandnana.sqlite`.

-- ============================================================
-- Products
-- ============================================================

-- Cheapest 10 products at a brand.
SELECT title, price_cents / 100.0 AS price, currency, url
FROM products
WHERE brand_id = (SELECT id FROM brands WHERE domain = 'example.com')
ORDER BY price_cents ASC
LIMIT 10;

-- Distribution of prices for a brand (rough buckets).
SELECT
  CASE
    WHEN price_cents IS NULL THEN 'unknown'
    WHEN price_cents < 2500 THEN '< $25'
    WHEN price_cents < 5000 THEN '$25-50'
    WHEN price_cents < 10000 THEN '$50-100'
    WHEN price_cents < 25000 THEN '$100-250'
    ELSE '$250+'
  END AS bucket,
  COUNT(*) AS n
FROM products
WHERE brand_id = (SELECT id FROM brands WHERE domain = 'example.com')
GROUP BY bucket
ORDER BY MIN(price_cents);

-- Products that disappeared between two crawls (soft-deleted heuristic).
WITH last_crawl AS (
  SELECT MAX(finished_at) AS ts
  FROM sync_runs
  WHERE kind = 'catalog' AND ok = 1
)
SELECT title, url, datetime(last_seen_at/1000, 'unixepoch') AS last_seen
FROM products
WHERE brand_id = (SELECT id FROM brands WHERE domain = 'example.com')
  AND last_seen_at < (SELECT ts FROM last_crawl)
ORDER BY last_seen_at DESC;

-- Products with no image (data-quality check).
SELECT p.title, p.url
FROM products p
LEFT JOIN product_images pi ON pi.product_id = p.id
WHERE pi.id IS NULL;

-- Products by catalog source (shopify vs context-dev vs llm).
SELECT platform, COUNT(*) AS n,
       AVG(price_cents) / 100.0 AS avg_price,
       SUM(CASE WHEN price_cents IS NOT NULL THEN 1 ELSE 0 END) AS priced
FROM products GROUP BY platform;

-- Did we mirror images? (R2-backed URLs all share the workers.dev host.)
SELECT
  CASE WHEN url LIKE 'https://brandnana-api.%/assets/%' THEN 'mirrored' ELSE 'vendor' END AS source,
  COUNT(*) AS n
FROM product_images
GROUP BY source;

-- ============================================================
-- Brand identity (palette / fonts / descriptors from context.dev)
-- ============================================================

-- Brand palette as one row per hex.
SELECT b.domain, b.name, value AS hex
FROM brands b, json_each(b.palette_json);

-- Pull a specific descriptor field out of the JSON blob.
SELECT domain, name,
       json_extract(descriptors_json, '$.slogan') AS slogan,
       json_extract(descriptors_json, '$.industry.name') AS industry
FROM brands;

-- Font families per brand (descriptors_json.fonts[].font).
SELECT b.domain, json_extract(font.value, '$.font') AS font_family
FROM brands b, json_each(json_extract(b.descriptors_json, '$.fonts')) AS font
WHERE b.descriptors_json IS NOT NULL;

-- ============================================================
-- Ads
-- ============================================================

-- Recent ads for a brand, with media count.
SELECT a.body, a.cta, datetime(a.first_seen_at/1000, 'unixepoch') AS first_seen,
       COUNT(am.id) AS media_count
FROM ads a
LEFT JOIN ad_media am ON am.ad_id = a.id
WHERE a.brand_id = (SELECT id FROM brands WHERE domain = 'example.com')
GROUP BY a.id
ORDER BY a.first_seen_at DESC
LIMIT 20;

-- Ad-library coverage by source.
SELECT source, COUNT(*) AS n,
       datetime(MIN(first_seen_at)/1000, 'unixepoch') AS oldest,
       datetime(MAX(last_seen_at)/1000, 'unixepoch') AS newest
FROM ads
GROUP BY source;

-- Meta ad creative bodies (raw_json.ad carries the full payload —
-- drill into snapshot.body.text for the ad copy).
SELECT
  json_extract(raw_json, '$.ad.snapshot.page_name') AS page,
  json_extract(raw_json, '$.ad.snapshot.body.text') AS body,
  json_extract(raw_json, '$.ad.snapshot.cta_type') AS cta,
  json_extract(raw_json, '$.ad.snapshot.link_url') AS link
FROM ads
WHERE source = 'meta'
ORDER BY first_seen_at DESC
LIMIT 10;

-- Active ads only (Meta marks is_active on the snapshot).
SELECT COUNT(*) AS active
FROM ads
WHERE source = 'meta'
  AND json_extract(raw_json, '$.ad.is_active') = 1;

-- Cross-source dedup check: same external_id across providers?
SELECT external_id, GROUP_CONCAT(source) AS sources, COUNT(*) AS n
FROM ads
GROUP BY external_id
HAVING n > 1;

-- ============================================================
-- Audit / freshness
-- ============================================================

-- Last 10 sync runs (any kind) — quick health check.
SELECT
  datetime(started_at/1000, 'unixepoch') AS started,
  kind, source, ok,
  (finished_at - started_at) AS duration_ms,
  substr(error, 1, 80) AS error
FROM sync_runs
ORDER BY started_at DESC
LIMIT 10;

-- Failed runs since yesterday.
SELECT datetime(started_at/1000, 'unixepoch') AS started, kind, source, error
FROM sync_runs
WHERE ok = 0 AND started_at > strftime('%s', 'now', '-1 day') * 1000
ORDER BY started_at DESC;

-- Brand last-fetched recency.
SELECT domain, name, datetime(fetched_at/1000, 'unixepoch') AS fetched
FROM brands
ORDER BY fetched_at DESC;
