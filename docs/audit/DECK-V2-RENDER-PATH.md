# Deck-v2 render path — §3.3 reality check (2026-06-05, loop wb-syjo)

A loop iteration tracing the §3.3 "data-driven slide mapper" found the backlog
framing is partly stale. Recording it so the next iterations target the real
lever.

## What BRANDBOOK-STATUS §3.3 says

> The deck is STILL a fixed ~10-slide template (`presentation-shell.ts`)... build
> the `analysis/*.org` → slide mapper so deck content is data-driven.

## What the shipped code actually does

`apps/cli/src/commands/book.ts` (the agent's `brandnana book` toolkit) is explicit:

- **CANONICAL path:** the strategist **AUTHORS the deck HTML itself** using the
  design-system component library documented in `compose-deck.org` +
  `publish-workbook.org`, then `book publish <slug> <deck.html>` uploads it
  verbatim. This is the 42-section deck-v2.
- **`composeBookData` / `renderPresentation` (`presentation-shell.ts`) is the
  GUARDED LEGACY path** — the old 10/13-slide server-rendered deck behind
  `POST /v1/book`, reachable only via `--legacy-generate`. The bare `book <domain>`
  verb now refuses and points at the author+publish recipe.

So the data-driven deck is **the agent's authoring job** (a skill-level concern),
not the legacy TS renderer.

## Where iterations 4–5 landed (still useful, not the primary lever)

- `analysis-slides.ts` (`parseInsights` / `insightsToSlides` / `analysisFilesToSlides`)
  is a correct, tested, deterministic `analysis/*.org` → slide-data mapper.
- It is wired into `presentation-shell.ts` (the legacy renderer) — so the legacy
  fallback is now data-driven, which is fine but secondary.
- The mapper itself is path-agnostic. Its real value: give the AGENT a
  deterministic structure instead of re-deriving slide order/grouping by hand
  every run (cheaper, more consistent, observable).

## Corrected §3.3 direction (filed as wb-syjo children)

1. Expose the mapper to the agent path: a `brandnana book insight-slides
   <analysis-dir>` CLI verb that emits ordered slide JSON from `analysis/*.org`,
   so `publish-workbook.org` authors FROM a deterministic outline rather than
   improvising slide structure. This is the seam that makes real runs data-driven.
2. Code health: `book.ts` is 879 LOC, OVER the 800 cap — split before extending.

## HIGH finding (2026-06-05): deployed-profile drift

Two brandnana deploy paths disagree on the profile source:

- `services/brandnana-agent/Dockerfile:83` → `COPY services/brandnana-agent/profile
  /opt/brandnana-profile` (entrypoint stages `$PROFILE_SRC/Engine/.`). Layout:
  `profile/Engine/{agents,skills}`.
- `deploy-kit/deployments/brandnana.org` → `:PROFILE: substrates/brandnana/profile`.
  Layout: `profile/{agents,skills}` (no `Engine/` wrapper).

`services/brandnana-agent/profile/Engine/skills/compose-deck.org` is **422 lines
behind** `substrates/brandnana/profile/skills/compose-deck.org` — it predates the
whole Stage-2 analysis-gate + visual-review architecture. If the
`services/brandnana-agent` image is the live one, the deployed strategist is
running PRE-Stage-2 skills and NONE of the deck-v2 / analysis-gate / insight-slides
work reaches production.

Canonical source = `substrates/brandnana/profile` (deploy-kit + the strategist
header point there). Fix options (do NOT blind-change deploy config in the loop):
(a) make the Dockerfile COPY from `substrates/brandnana/profile` (needs the
`Engine/` layout reconciled), or (b) delete the stale `services/.../profile` and
make `services/brandnana-agent` consume the deploy-kit profile. Filed as a HIGH
child of wb-syjo.

## Why this matters for the loop

The observability (wb trace context-pressure, per-result tokens) watches the
agent authoring the deck. The lever to make that deck data-driven is the
authoring skill + a deterministic mapper verb — not the legacy renderer. Aim
there next.
