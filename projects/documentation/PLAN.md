# Workbooks Docs — plan

> Temporary scaffold. A detached `PLAN.md` is exactly the "fuzzy detached docs"
> the Literate Programming page argues against — this exists only until the plan
> is folded into the workbook itself. Replaces the deleted `web/learn/`.

## Locked decisions (from grill, 2026-06-19)

- **Build model:** pure `.work` end-to-end — the docs site *is* a workbook. A
  `.work` file is literate programming that compiles any supported language
  (`elixir rust zig python svelte solid js ts c go wit`). Svelte-in-a-workfile is
  lesson one. Block grammar: `<kind> [lang] :name … do … end`.
- **Composition:** `index.work` is the app spec (pages, sidebar, theme). Teach
  `weave` a **site-mode** that reads `index.work` + sibling pages and emits a
  **full SPA** (the workbook output) driven by **our own language-agnostic central
  router** — not SvelteKit's, so multi-language `client` islands compose. Today
  `weave` only folds a folder → one HTML with a flat `wb-nav`
  (`nexus/lib/weave.ex`); site-mode is a **new primitive to build**.
- **Routing:** History-API path routes (`/literate-programming`) + host catch-all
  → SPA. Weave also emits per-page raw markdown + `llms.txt` / `llms-full.txt`.
- **Chrome:** clone the cloud-portal sidebar's visual DNA — petal + wordmark +
  theme toggle, DNA-strip accent, paper/ink dark-light, Geist + mono,
  `darkreader-lock`; reuse the dashboard's CSS tokens. Switchers → grouped
  doc-nav tree. Search box on top; footer → GitHub + portal. Ref:
  `web/cloud-dashboard/src/routes/+layout.svelte`.
- **Search:** client-side static index emitted at weave time (reuse
  `web/search.js` / `search.css`); titles + headings + body.
- **Tone:** junior-developer voice — educational, kind, plain, but technically
  correct and concrete. Concept pages warmer; language teardown reference-grade.
- **Examples:** static `Nexus.Literate`-highlighted snippets everywhere + a few
  genuinely live-rendered `client` blocks on signature pages.
- **Ergonomics:** per-page copy-as-markdown + copy-as-prompt; site-wide
  `llms.txt` / `llms-full.txt`; per-snippet copy buttons; one CLI-agent
  onboarding page (not a per-page widget).

## Information architecture

- **Introduction** — `Literate Programming` (one rich page: `## Knuth →
  ## The agent turn → ## What agent harnesses get wrong` [detached docs make code
  fuzzy; LOC buildup/drift, the Gary-Tan 30k-LOC sprawl] `→ ## Why Elixir`
  [concurrency, architecture fit, learnable; org-mode / MDX lineage] `→
  ## Radical simplicity` [cite https://www.radicalsimpli.city/happier-developers:
  one engine + one language, kill glue code, force the agent to simplify]) →
  `What is a workbook / .work file / Nexus / work CLI / Workbooks Cloud`
  - **What is the Nexus** — "the engine you own": one command · dev ≡ prod ·
    isolation (every agent/tenant/code = its own process, wasm on BEAM) · backs
    server units, agents, data, sync, compile/weave. **Economics angle:**
    microservices/serverless cost an arm and a leg at scale; here you **scale by
    RAM** (far cheaper), and what you prototype deploys as a **multi-tenant
    production app immediately** — prod works exactly the same at scale. Threads
    back to `## Radical simplicity`.
  - **What is the work CLI** — two-tier: lifecycle narrative
    (author → `check`/`lint` → `weave`/`build` → `dev` → `deploy`) + per-verb
    reference cards. Verbs (Zig reactor, binary `work`): `init new check lint why
    near wit graph weave build dev deploy`. (`wbx` Rust crate is dead — n/a.)
  - **What is Workbooks Cloud** — concept + when-to-use vs self-deploy + BYO-infra
    lane + link into the live portal. Don't mirror portal UI docs (they drift).
- **The .work language** — two-tier: narrative concept pages (anatomy / four
  lanes → block grammar → prose lane & refs → declarations → placement &
  languages) + one dense **per-kind reference** index + `Elixir in Markdown`.
- **Running & deploying** — `Running the Nexus` (local, one command) · `Deploy`
  (two canonical targets: local krunvm + cloud Fly to your own account, via
  `work deploy`) · `Workbooks Cloud` (managed/hosted — may cross-link the intro
  Cloud page).
- **Agents & tooling** — `Get started with your CLI agent` (skill install).

## Build sequence

1. `weave` site-mode + our own router (prove on a tiny throwaway workbook to
   surface real weave drift/errors).
2. Chrome — portal-sidebar clone, theme, search, ergonomics.
3. Content — Introduction section first, then language teardown, then tooling.

Skills get authored **from** these docs, later.

## Still open — minor

- Docs domain/deploy host confirmation (`docs.workbooks.sh`, Cloudflare Pages).
- Versioning (likely none for v1).

Economics narrative: woven into the Nexus page as `## The economics: scale by
RAM`, cross-linked from `## Radical simplicity`.
