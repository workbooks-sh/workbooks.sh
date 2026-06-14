# brandnana

An ad + brand intelligence substrate. `brandnana` gives an agent brand identity, ads, social, catalog, design tokens, and brief + brand-book composition — a self-contained CLI that fronts `api.brandnana.net`, so the agent never speaks HTTP directly: it shells out to verbs and gets text or `--json`.

## When to reach for it

Reach for `brandnana` when a workbook or agent needs real brand signal — a logo, fonts, palette, live ad creatives, organic social, or a product catalog — and wants to turn that signal into a creative brief or a publishable brand-book. The logo cascade (homepage → Wikipedia SVG → logo.dev → simpleicons) is the reliable way to actually retrieve a brand's mark.

## Example

```
brandnana resolve "the running shoe brand with the swoosh"   # fuzzy → domain
brandnana brand fetch nike.com                                # identity
brandnana logo nike.com                                       # logo cascade
brandnana ads search nike --platform meta                     # live ad creatives
brandnana book compose ... && brandnana book publish-rendered
```

## What it grants

- Verb groups: `brand` (logo/fonts/palette/product), `logo` (the cascade), `ads` (Meta/Google/TikTok search), `social` (IG/TikTok/LinkedIn), `catalog`, `design` (tokens), `brief`, `book` (brand-book compose/query/install), `resolve`, plus `usage`, `simulate`, `audit-trace`, and an `mcp` stdio server.
- A per-session verb trace + cost ledger; a `simulate` dry-run to preview a pipeline without spending.

## Maturity

Experimental (v0.1.0). Requires `BRANDNANA_API_KEY` (read from the environment — the toolkit holds no creds). The `logo` command optionally uses `LOGO_DEV_TOKEN` and `GROQ_API_KEY` if present; both degrade gracefully. Note: lifestyle/PDP imagery and reliable logo retrieval have been weak spots in past runs — verify output rather than assuming completeness.
