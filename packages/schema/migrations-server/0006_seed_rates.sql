-- Seed: vendor rate cards and a default customer markup card.
--
-- IMPORTANT: Prices below are estimates as of 2026-05. Verify against
-- vendor pricing pages before relying on these for billing:
--   - OpenRouter: https://openrouter.ai/models
--   - Exa: https://exa.ai/pricing
--   - Firecrawl: https://www.firecrawl.dev/pricing
--   - E2B: https://e2b.dev/pricing
--   - Brandfetch: https://brandfetch.com/pricing
--   - logo.dev / context.dev: https://context.dev/pricing
--   - ScrapCreators: https://scrapecreators.com/pricing
--   - Meta Ads Library: free (public API, no per-request charge)

INSERT OR IGNORE INTO vendor_rate_cards (id, provider, model, unit, price_usd_per_unit, effective_from, source, created_at, created_by) VALUES
  ('vrc_openrouter_gemini35flash_input',    'openrouter', 'google/gemini-3.5-flash', 'token_input',  0.075/1000000,  strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_openrouter_gemini35flash_output',   'openrouter', 'google/gemini-3.5-flash', 'token_output', 0.30/1000000,   strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_openrouter_gemini3pro_input',       'openrouter', 'google/gemini-3-pro',     'token_input',  1.25/1000000,   strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_openrouter_gemini3pro_output',      'openrouter', 'google/gemini-3-pro',     'token_output', 5.00/1000000,   strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_exa_request',                       'exa',          NULL, 'request', 0.005,    strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_firecrawl_request',                 'firecrawl',    NULL, 'request', 0.003,    strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_e2b_second',                        'e2b',          NULL, 'second',  0.000056, strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_brandfetch_request',                'brandfetch',   NULL, 'request', 0.001,    strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_logo_dev_request',                  'logo_dev',     NULL, 'request', 0.0,      strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_scrapecreators_request',            'scrapecreators', NULL, 'request', 0.01,   strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_meta_ads_library_request',          'meta',          NULL, 'request', 0.0,     strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system'),
  ('vrc_context_dev_request',               'context_dev',   NULL, 'request', 0.002,   strftime('%s','now')*1000, 'vendor_docs', strftime('%s','now')*1000, 'system');

-- Default customer rate: 3x markup on all verbs (catch-all), untagged draft.
-- Tag this card once pricing is locked in for production.
INSERT OR IGNORE INTO customer_rate_cards (id, tag, verb_id, price_strategy, markup_multiplier, effective_from, created_at, created_by) VALUES
  ('crc_default_markup', NULL, '*', 'markup_multiplier', 3.0, strftime('%s','now')*1000, strftime('%s','now')*1000, 'system');
