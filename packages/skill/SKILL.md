---
name: brandnana
description: Pull brand intelligence — logos, fonts, colors, competitor ads, product catalogs, and campaign briefs — from brandnana.net. Use when the agent needs real brand data instead of generic defaults: scaffolding a video, researching a brand identity, extracting design tokens from a website, or pulling live competitor ads.
---

# Brandnana — Skill for AI Agents

Brandnana is a managed brand-intelligence API. Agents call it through a
single CLI binary; users see the same data on a web dashboard. Your job
as an agent is to use the CLI to fetch brand, ad, design, and catalog
data on behalf of the user — never scrape these by hand, never invent
sources, never quote prices without going through the cost ledger.

## When to use Brandnana

Reach for `brandnana` when the user asks about:

- A **brand's identity**: logo, fonts, colors, tagline, social handles
- **Live ads** running on Meta / TikTok / Google for a domain or page
- A **competitor's catalog** (product names, prices, hero imagery)
- **Design assets** (logo dominant colors, glyph extraction, font detection)
- **Brief generation** from a brand or campaign reference
- **Social** profile resolution across networks

If the request is "render a video", "edit this audio", or "build a workbook" —
that's Wavelet / Workbook territory, not Brandnana. Stay in your lane.

## Install + auth

```bash
# 1. Install (one time)
npm i -g @brandnana/cli

# 2. Sign in (GitHub device flow — opens your browser once)
brandnana auth login

# 3. Confirm
brandnana auth whoami
```

The CLI stores the API key in the OS keychain. For headless / CI use,
pass `BRANDNANA_API_KEY=adk_live_...` via env.

## Core verbs

Every verb supports `--json` for machine output. Default output is
human-readable monospace.

| Verb | What it does |
|---|---|
| `brandnana brand fetch <domain>` | Logo + palette + fonts (with CSS @font-face URLs) + page screenshot + styleguide. Default `--include=fonts,screenshot`; `--minimal` skips side-fetches |
| `brandnana brand product <domain> <url>` | Extract a single product page: name, price, images, features, SKU |
| `brandnana brand fonts <domain>` | Font detection via CSS parsing (CDN-independent — works when brand fetch's fonts are unavailable) |
| `brandnana brand logo <domain>` | Logo + alternate marks, with dominant colors |
| `brandnana ads search <domain>` | Currently-running ads (Meta Ad Library, TikTok, Google) |
| `brandnana catalog crawl <url>` | Product catalog pull — paginated, snapshot to R2 |
| `brandnana brief generate <ref>` | Campaign brief from a brand or competitor reference |
| `brandnana design palette <image>` | Dominant-color palette from an image |
| `brandnana resolve <query>` | Disambiguate a brand name to its canonical domain |
| `brandnana social profile <handle>` | Cross-network social profile data |
| `brandnana usage` | Per-day spend, per-call cost, model breakdown |

### `brand fetch` response shape

```jsonc
{
  "brand": {
    "id": "...", "domain": "...", "name": "...",
    "logo_url": "https://cdn.../logo.png",
    "palette_json": "[\"#ff0000\", ...]",
    "descriptors_json": "{ slogan, colors, fonts (names only), socials, ... }",
    "fetched_at": 1716840000000
  },
  "extras": {
    "fonts": [
      {
        "name": "Helvetica Neue",
        "family": "Helvetica Neue",
        "fallbacks": ["Arial", "sans-serif"],
        "css_url": "https://fonts.googleapis.com/...",  // null if no CDN
        "usage": { "percent_elements": 78.2, "percent_words": 65.4 }
      }
    ],
    "styleguide": { "typography": {...}, "components": {...} },
    "screenshot_url": "https://api.context.dev/screenshots/..."
  }
}
```

For generative-video work: drop `extras.fonts[N].css_url` into a
`<link rel="stylesheet">` in the scene HTML, then reference
`extras.fonts[N].family` in CSS. Pick the highest-`percent_elements`
font for display copy, the next-highest for body. If `css_url` is
null for a font, fall back to a typographically-defensible web-safe
pair — NEVER monospace, NEVER system-ui defaults.

Run `brandnana <verb> --help` for the full flag set on any subcommand.

## Cost discipline

Every paid call emits a `[brandnana-cost]` marker line to stderr. The
CLI parses these into `.brandnana-trace.jsonl` next to the cwd, and
the dashboard shows the running tally. Treat the API like metered
infrastructure:

- **Read the trace before retrying.** If `brandnana brand fetch foo.com`
  already ran and produced a tier-2 result, re-running silently spends
  more money. The trace records the last result; check it.
- **Quote the user before expensive ops.** Anything that paginates
  (`catalog crawl`) or hits multiple vendors (`brief generate`) can
  spend dollars, not cents. Surface the projected cost (`--dry-run`
  on most verbs) before committing.
- **Don't double-pay for the same data.** The API caches per-tenant.
  Use `--from-cache` to read prior pulls; only fall back to a live
  fetch when the user explicitly asks for fresh data.

## Connecting external accounts

Some verbs require the user to connect their own external accounts (so
Brandnana doesn't pay a shared rate-limited key on their behalf).
Examples: Meta Ads Library tokens, TikTok Marketing API.

```bash
# OAuth bounce — opens browser once per provider.
brandnana connect meta
brandnana connect tiktok

# Status of connected providers (keys, last refresh, scopes).
brandnana connect status
```

If you encounter `error: connection_required: meta`, do NOT prompt the
user inside your loop. Print the exact `brandnana connect meta` command
and let them run it themselves. The OAuth flow needs a browser handoff.

## Failure modes

- **`auth_required`** — User isn't signed in. Print `brandnana auth login`.
- **`connection_required: <provider>`** — Print `brandnana connect <provider>`.
- **`rate_limited: <provider>`** — Don't retry in a tight loop. Surface
  the `retry_after_ms` field and back off.
- **`tier_limit_exceeded`** — Hit the user's monthly cap. Surface their
  current usage (`brandnana usage`) and stop.
- **`unknown_domain`** — Resolution failed. Don't guess; ask the user.

## What this skill is NOT

- A general web-scraper. If the user wants "everything about X", use
  `brandnana brand fetch X` and `brandnana ads search X` — don't
  shell out to `curl`.
- A video / audio / workbook tool. Those are separate substrates.
- A free service. Every CLI verb except `auth` and `usage` spends money.

## MCP server (Claude Desktop / Claude Code / Cursor)

`brandnana mcp` starts an MCP stdio server that exposes every brandnana
verb as an MCP tool. Add this to your MCP config to connect:

```json
{
  "mcpServers": {
    "brandnana": {
      "command": "brandnana",
      "args": ["mcp"]
    }
  }
}
```

For Claude Desktop the config lives at
`~/Library/Application Support/Claude/claude_desktop_config.json`.
For Claude Code add it to `.claude/settings.json` under `mcpServers`.

Inspect the available tools without starting the server:

```bash
brandnana mcp --list-tools
```

## Reference

- CLI source: `projects/brandnana/apps/cli/`
- MCP command: `projects/brandnana/apps/cli/src/commands/mcp.ts`
- API source: `projects/brandnana/apps/api/`
- Dashboard: `projects/brandnana/apps/dashboard/` (web UI for users)
- Schema: `projects/brandnana/packages/schema/`
- Pricing: `projects/brandnana/apps/api/src/pricing.ts`
- Cost ledger: `projects/brandnana/apps/api/src/cost.ts`
