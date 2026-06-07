// /v1/skills/* — downloadable skill bundles for agent runtimes.
//
// A "skill" here is a markdown file the agent reads to learn HOW to use
// brandnana. Claude Code reads them from `~/.claude/skills/<name>.md`,
// Cursor reads them via @brandnana.md mentions, etc.
//
// Endpoints:
//   GET /v1/skills/list                   → JSON catalog
//   GET /v1/skills/bundle.tar.gz?target=<…> → tar.gz of all skill files
//
// No bearer required for the catalog or the bundle download — they're
// public documentation.

import { Hono } from "hono";
import type { Bindings } from "../env.js";
import { tarGz } from "../book/tar.js";

const skills = new Hono<{ Bindings: Bindings }>();

interface SkillFile {
  path: string;
  title: string;
  description: string;
  content: string;
}

function getSkills(): SkillFile[] {
  return [
    {
      path: "brandnana.md",
      title: "brandnana",
      description: "Top-level skill — auth + verbs + book pipeline overview.",
      content: SKILL_BRANDNANA,
    },
    {
      path: "brandnana-book.md",
      title: "brandnana book",
      description: "Build a brand book from any domain.",
      content: SKILL_BOOK,
    },
    {
      path: "brandnana-brand.md",
      title: "brandnana brand",
      description: "Fetch brand identity (logo, palette, fonts, voice).",
      content: SKILL_BRAND,
    },
    {
      path: "brandnana-catalog.md",
      title: "brandnana catalog",
      description: "Crawl a brand's product catalog.",
      content: SKILL_CATALOG,
    },
    {
      path: "brandnana-ads.md",
      title: "brandnana ads",
      description: "Search creative ad libraries.",
      content: SKILL_ADS,
    },
  ];
}

skills.get("/list", (c) => {
  return c.json({
    skills: getSkills().map(({ path, title, description }) => ({ path, title, description })),
  });
});

skills.get("/bundle.tar.gz", async (c) => {
  const target = c.req.query("target") ?? "generic";
  const encoder = new TextEncoder();
  const files = getSkills();
  const readme = encoder.encode(makeReadme(target, files));
  const tarFiles = [
    { path: "README.md", bytes: readme },
    ...files.map((f) => ({ path: f.path, bytes: encoder.encode(f.content) })),
  ];
  const bytes = await tarGz(tarFiles);
  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": "application/gzip",
      "content-disposition": `attachment; filename="brandnana-skills-${target}.tar.gz"`,
      "cache-control": "public, max-age=300",
      "x-brandnana-skill-count": String(files.length),
      "x-brandnana-skill-target": target,
    },
  });
});

skills.get("/file/:path", (c) => {
  const path = c.req.param("path");
  const file = getSkills().find((s) => s.path === path);
  if (!file) return c.text(`Skill not found: ${path}`, 404);
  return new Response(file.content, {
    status: 200,
    headers: {
      "content-type": "text/markdown; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
});

function makeReadme(target: string, files: SkillFile[]): string {
  const installLines: Record<string, string> = {
    "claude-code":
      "Drop the .md files into `~/.claude/skills/` (or your project's `.claude/skills/`). Claude Code auto-loads them.",
    cursor: "Drop the .md files into your project's `.cursor/rules/` directory or `@`-mention them in chat.",
    generic: "Drop the .md files wherever your agent reads tool/verb documentation.",
  };
  const installLine = installLines[target] ?? installLines.generic;
  return `# brandnana skills — for ${target}

${installLine}

## Files

${files.map((f) => `- \`${f.path}\` — ${f.description}`).join("\n")}

## Setup

You need a brandnana API key. Get one at https://app.brandnana.net or run:

\`\`\`sh
brandnana login
\`\`\`

Then export it:

\`\`\`sh
export BRANDNANA_KEY=adk_live_…
\`\`\`

Every skill assumes \`$BRANDNANA_KEY\` is set.
`;
}

// ── Skill content ────────────────────────────────────────────────────────────

const SKILL_BRANDNANA = `# brandnana

Brand intelligence in one call. brandnana fetches a brand's identity, products,
ads, and competitors and packages them as a single-file brand book.

## Setup

\`\`\`sh
export BRANDNANA_KEY=adk_live_…    # from https://app.brandnana.net
\`\`\`

## Core verbs

- \`brandnana book <domain>\`              — produce a complete brand book .html
- \`brandnana brand <domain>\`             — identity (logo, palette, fonts, voice)
- \`brandnana catalog <domain>\`           — product catalog crawl
- \`brandnana ads search <query>\`         — search Meta / TikTok / Google ads
- \`brandnana brief generate <domain>\`    — generate a creative brief

## HTTP

All verbs are available as POST endpoints under \`https://api.brandnana.net/v1/\`:

\`\`\`sh
curl -X POST https://api.brandnana.net/v1/book \\
  -H "Authorization: Bearer $BRANDNANA_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"domain":"aesop.com"}'
\`\`\`

Response: \`application/gzip\` tar.gz containing \`<slug>.html\` and \`SKILL.md\`.
`;

const SKILL_BOOK = `# brandnana book

Build a single-file brand book from any domain.

## CLI

\`\`\`sh
brandnana book aesop.com
brandnana book sweetgreen.com --competitors cava.com,choptsalad.com
brandnana book vercel.com --with-video        # include video assets
brandnana book spotify.com --link-only        # skip media downloads
\`\`\`

Output: \`<slug>-brand-book.tar.gz\` containing:
- \`<slug>.html\` — the self-contained brand book (open in any browser)
- \`SKILL.md\` — generated docs for re-loading into an agent

## HTTP

\`\`\`sh
curl -X POST https://api.brandnana.net/v1/book \\
  -H "Authorization: Bearer $BRANDNANA_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"domain":"aesop.com","competitors":["lelabofragrances.com"]}' \\
  > aesop.tar.gz
\`\`\`

## Pre-built demo books

\`\`\`sh
# View any of the 5 seed brand books in the browser:
open https://api.brandnana.net/books/aesop.html
open https://api.brandnana.net/books/sweetgreen.html
open https://api.brandnana.net/books/vercel.html
open https://api.brandnana.net/books/spotify.html
open https://api.brandnana.net/books/liquid-death.html
\`\`\`
`;

const SKILL_BRAND = `# brandnana brand

Fetch a brand's visual + verbal identity.

## CLI

\`\`\`sh
brandnana brand fetch nike.com
\`\`\`

Returns: logo, color palette (with extended colors), font usage stats,
descriptors, voice notes, industry classification, social handles.

## HTTP

\`\`\`sh
curl -H "Authorization: Bearer $BRANDNANA_KEY" \\
  "https://api.brandnana.net/brand/fetch?domain=nike.com"
\`\`\`

## Subverbs

- \`brand fetch <domain>\`       — full identity
- \`brand fonts <domain>\`       — font usage with percent-of-words ranking
- \`brand colors <domain>\`      — color palette only
- \`brand logo <domain>\`        — logo URL (SVG when available)
`;

const SKILL_CATALOG = `# brandnana catalog

Crawl a brand's product catalog.

## CLI

\`\`\`sh
brandnana catalog crawl nike.com --max-products 200
brandnana catalog status <crawl-id>
brandnana catalog list <crawl-id>
\`\`\`

The crawl is streaming — partial results stream over WebSocket as the
crawler finds products. Resumable via \`crawl-id\`.

## HTTP

\`\`\`sh
curl -X POST https://api.brandnana.net/catalog/crawl \\
  -H "Authorization: Bearer $BRANDNANA_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"domain":"nike.com","max_products":200}'
\`\`\`
`;

const SKILL_ADS = `# brandnana ads

Search creative ad libraries across Meta, TikTok, and Google.

## CLI

\`\`\`sh
brandnana ads search "nike running" --country US --providers meta,tiktok
brandnana ads competitor adidas.com --country US
\`\`\`

## HTTP

\`\`\`sh
curl -X POST https://api.brandnana.net/ads/search \\
  -H "Authorization: Bearer $BRANDNANA_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{"query":"nike running","country":"US","providers":["meta","tiktok"]}'
\`\`\`

Returns ad records with: headline, platform, landing URL, media URL,
first/last seen, advertiser handle.
`;

export default skills;
