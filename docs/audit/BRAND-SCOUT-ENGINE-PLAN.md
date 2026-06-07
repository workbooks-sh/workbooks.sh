# BRAND-SCOUT-ENGINE-PLAN — Engine-Driven Harvest Agent (build plan)

> Status: BUILD PLAN (read-only recon synthesis, no code written). Date: 2026-06-03.
> Scope: Stage-1 "Brand Scout" harvester moved OFF the single Worker request and INTO the
> workbooks Elixir engine, where an uncapped session (or a verification-gated board) shells the
> `brandnana` CLI over time and writes an OQL-queryable org + R2 media substrate for the brand book.
> Prereqs proven elsewhere: Stage-1 harvest LOGIC + bypass fixes live in the Worker
> (`book/harvest.ts`); `catalog crawl --mirror` proven live (tecovas, 250 products). This plan is
> the ENGINE execution layer for that logic.
>
> Companion docs: `BRAND-BOOK-PLAN.md` (board/page model, media policy, OQL gates),
> `BRAND-DATA-HARVEST.md` (manifest, escalation policy, verify predicates, fail-loud contract).
> Every engine/CLI claim below is cited `file:line`.

---

## 1. How engine agents run (the mechanics the Brand Scout uses)

The engine is `runtime/engine` (Elixir/Phoenix). An agent IS an org headline, not a code class.

**Definition.** An agent is a `:agent:`-tagged headline with an `:ID:` and a conventional
`** System prompt` subsection, parsed by `WorkbooksRuntime.AgentDef`
(`agent_def.ex:30-33,131-140,210-238`). Properties read off the drawer: `:MODEL:`, `:TOOLKITS:`,
`:CAPABILITIES:`, `:ALLOW_SPAWN:`, `:SPAWN_DEPTH:`, `:MAX_CHILDREN:`, `:CAN_GRANT:`
(`agent_def.ex:226-232`). Resolution chain for an `agent_slug`: project `.workbooks/agents/` →
user `<engine_dir>/agents/` → **profile `$WB_PROFILE_DIR/agents`** → builtin priv
(`agent_controller.ex:293-301,398-418,440-445`). The cloud cell bakes the profile at
`/opt/profile` and sets `WB_PROFILE_DIR=/opt/profile` (`Dockerfile.engine-profile:114,125`), so a
new agent file dropped at `substrates/brandnana/profile/agents/<slug>.org` is reachable by slug.

**The one tool is bash.** `ToolRegistry.catalog/0` exposes exactly one descriptor, `bash`
(`tool_registry.ex:35-56`). Every capability (resolve, fetch, catalog, social, ads, mirror, book
publish) is the `brandnana` CLI binary invoked through bash. The descriptor itself tells the agent
toolkits are on PATH and discoverable via `<toolkit> --help` / `cat skills/<toolkit>/SKILL.md`
(`tool_registry.ex:37-40`). `:TOOLKITS:` names resolve to `:toolkit:` headlines in the Context
Tree; the token `bash` is silently dropped because bash is the one tool, not a toolkit
(`agent_def.ex:240-257`).

**Invocation — two surfaces.**
- `POST /api/run` → starts ONE `SessionRunner` GenServer (`agent_controller.ex:44-96`,
  `router.ex:66`). The loop runs until the agent stops calling tools, errors, or is cancelled —
  **NO iteration cap**; wall-clock (caller TIMEOUT_MS / OS cancel) is the only bound
  (`session_runner.ex:24-27,215-247`). This is the natural seat for a single long harvest.
- `POST /api/run-plan` → starts a `WorkbooksRuntime.Board` for a posted `board_dir`
  (`agent_controller.ex:100-118`, `router.ex:67`). The board fans ready tasks to worktree-isolated,
  **verification-gated** sub-agents via `Board.Dispatcher` (`board/dispatcher.ex:46-163`): claim →
  spawn child `SubAgent` → on terminal state run the acceptance gate → only a verified pass merges
  the worktree and reports `:done`; a failed run/verify abandons the worktree (bad work never lands,
  `dispatcher.ex:138-163`). This is the seat for the FAN-OUT harvest (one sub-agent per
  section/platform). Both POSTs are unauthed-shape-checked then auth-gated by `AuthPlug`
  (`router.ex:22-25,50-75`).

**Tools / secrets / workspace.** bash dispatch (`session_runner.ex:313-332`) routes through
`ToolRegistry.dispatch/3`, then either the VmHost sandbox or in-process `System.cmd`
(`tool_registry.ex:84-159`); cloud runs `WB_VMM_BACKEND=process` so the Fly machine itself is the
boundary (`Dockerfile.engine-profile:113`). Child env is SCRUBBED — a secret-substring blocklist
(`API_KEY|SECRET|TOKEN|...`) drops anything sensitive (`tool_registry.ex:166-209`), EXCEPT names
the deploy lists in `WB_FORWARD_SECRETS`, which are forwarded past the scrub
(`tool_registry.ex:194-218`). The deploy assembles that allowlist in `recipe/common.sh:113-135`
(`OPENROUTER_API_KEY` always + `WB_FORWARD_SECRETS` names) and forwards the allowlist itself so the
engine knows what to inject. **Workspace** = the agent's `workdir` (`session_runner.ex:88`), and
durable engine state is `WB_DATA_ROOT` (`data_root.ex:9-14`).

**Persistence.** A finished session is recorded in `SessionTrack` for terminal-state lookup
(`session_runner.ex:179`, `agent_controller.ex:183-199`) — but there is **no rich durable session
mirror**; the list endpoint only sees live processes (`agent_controller.ex:161-179`,
moduledoc `:30-31`). So the durable record of a harvest is NOT the sessions API — it is the org +
R2 substrate on disk/R2.

**R2 / media.** The agent never owns R2. It shells `brandnana catalog crawl <domain> --mirror`,
which streams products into local SQLite and batches images to `client.mirror.images`, rewriting
each `product_images.url` to the R2 `/assets/<sha>` URL (`catalog.ts:42-72,183,190-194`,
`sdk/index.ts:846-848`). Singletons (logo, screenshot, ad creatives) hit `POST /mirror/images`
(sha256, dedup, 8MiB cap) → `https://api.brandnana.net/assets/<sha>.<ext>`
(`mirror/routes.ts:3-4,18-19,67-108`). The book is published by shelling `brandnana book` (the
cloud compose-and-publish flow, `book.ts:34,458-459`) — the brandnana API owns the renderer, the
R2 bucket, and the canonical URL.

---

## 2. Current cloud-agent state — works-today vs still-broken

**WORKS TODAY (live-verified, app `bn-engine`):**
- The engine is up: `fly status bn-engine` shows machine `78452eec237348`, **1/1 checks passing**,
  image `deployment-01KT81RF86WF06PRYGBPBKJ5CY`. `/api/run`, `/api/run-plan`, `/api/board`,
  `/api/agents`, `/api/agents/spawn`, `/api/gitwork/*`, `/api/workspace/*` are all routed and live
  (`router.ex:66-95`) — strictly more surface than the one-shot `creative analyze` a prior session
  drove.
- The brandnana binary runs on the machine (prior session ran `creative analyze` live; binary baked
  at `/usr/local/bin/brandnana`, `Dockerfile.engine-profile:124`). The harvest secrets forward via
  `WB_FORWARD_SECRETS` (`tool_registry.ex:194-218`).
- The agent loop is uncapped (`session_runner.ex:24-27`), so a multi-minute harvest fits a single
  `/api/run`. `node`/`jq`/`wb` are not needed for the harvest leaf ops; `listen.json` + `WB_DAEMON`
  are moot in HTTP mode.

**STILL BROKEN — gaps to close BEFORE the harvest agent can run durably:**

1. **Config drift — the toml points at the brandnana-LESS Dockerfile.** `fly.bn-engine.toml:13`
   declares `dockerfile = "Dockerfile.engine"`, and the lean `cloud/Dockerfile.engine` has NO
   brandnana-cli stage, NO `/usr/local/bin/brandnana`, NO `WB_PROFILE_DIR`/`WB_TOOLKITS_ROOT`
   (confirmed: only `FROM hexpm…` + `FROM wolfi-base`, no brandnana COPY). **A deploy from this toml
   breaks every harvest verb AND hides the profile agent.** The live machine is currently on the
   profile image; the toml is what the NEXT deploy uses. **P0 fix: repoint to
   `Dockerfile.engine-profile` and verify `command -v brandnana` in CI.**

2. **No Fly volume → ephemeral workspace.** `fly volumes list -a bn-engine` is **EMPTY**, and
   `fly.bn-engine.toml:19` sets `WB_DATA_ROOT = "/tmp/wb"` on the container rootfs. The org
   substrate, the catalog SQLite (`.brandnana/brandnana.sqlite`, `catalog.ts:82`), and any
   in-progress harvest are **lost on machine restart**; only R2 (mirrored media) survives. **This is
   the headline blocker for a "harvest over time" agent.** P0 fix: add a Fly volume + set
   `WB_DATA_ROOT` to it, OR gitwork-push the substrate to R2 per checkpoint (`/api/gitwork/push`,
   `router.ex:92`).

3. **Completed sessions are in-memory only.** No durable rich session record
   (`agent_controller.ex:26-31,161-179`). Treat the R2 book + the (volume- or gitwork-) persisted
   substrate as the durable record, never the sessions API.

4. **Singleton-media mirror seam unconfirmed for ad/social.** `catalog --mirror` proven for product
   images; logo/screenshot/ad/social singletons must go through `POST /mirror/images` (curl with the
   bearer) or via the harvest's own mirror — and we must confirm the ad/social prefix is the SAME
   `brandnana-assets` bucket the catalog mirror writes (`BRAND-BOOK-PLAN.md` OPEN DECISION 4).
   This is a verification item, not a code blocker.

---

## 3. The Brand Scout build — exact FILES to create/edit (P0 / P1)

The Brand Scout is **a producer profile agent** that drives the `brandnana` CLI (the engine already
holds the toolkit). The Stage-2 consumer (`brandnana-strategist`) already exists; we add the
producer and the board that seams them. Filesystem handoff in one workspace, per
`BRAND-DATA-HARVEST.md:168-183`.

### P0 — make a deploy runnable + define the producer agent

| # | File | Action | Why |
|---|------|--------|-----|
| P0-1 | `deploy-kit/cloud/fly.bn-engine.toml` | **EDIT** `dockerfile = "Dockerfile.engine-profile"` (`:13`); change `WB_DATA_ROOT` off `/tmp/wb` to the volume mount, e.g. `/data` (`:19`); add `[[mounts]] source="wb_data" destination="/data"`. | Closes blockers §2.1 + §2.2 in one toml. Without it the next deploy ships a brandnana-less, volume-less engine. |
| P0-2 | (Fly volume) `fly volumes create wb_data -a bn-engine -r iad -s 10` | **CREATE** (one-shot, not a repo file) | Durable workspace for org substrate + catalog SQLite across restarts. |
| P0-3 | `substrates/brandnana/profile/agents/brand-scout.org` | **CREATE** | The producer agent. Drawer: `:ID: brand-scout`, `:MODEL:` (a capable harvest model), `:TOOLKITS: bash brandnana`, `:ALLOW_SPAWN: t`, `:SPAWN_DEPTH: 2`, `:MAX_CHILDREN: 8` (the §5 fan-out cap from `BRAND-BOOK-PLAN.md:190-193`), `:CAN_GRANT: bash brandnana`. System prompt = the §4 harvest loop: run the dependency-ordered sweep (resolve → identity → company → catalog `--mirror` → social → ads → creative-vision → provenance), VERIFY each point against its predicate, ESCALATE on resistance, FAIL LOUD (`status=failed` in `harvest-provenance.org`), write the org substrate (§4 below). Model the file's structure on the sibling `brandnana-strategist.org:1-131`. |
| P0-4 | `substrates/brandnana/profile/skills/harvest-sweep.org` | **CREATE** | The deep playbook the agent `cat`s on demand (mirrors the `brand-research.org` pattern). The full per-point manifest, the escalation chain (`BRAND-DATA-HARVEST.md:96-109`), the per-type verify predicates (palette ≥6 swatches with roles; catalog >12 products w/ prices; screenshot byte-validates; social has a follower count; `:158-164`), and the loud-failure / true-negative contract (`:108-109`). |
| P0-5 | `substrates/brandnana/profile/skills/write-substrate.org` | **CREATE** | How to emit the OQL-queryable org files (§4 schema below) + the R2 lanes: `catalog --mirror` for products, curl `POST /mirror/images` for singletons. Cites the four canonical templates so the producer's org matches what the strategist's OQL gates query. |

### P1 — the board seam (producer → consumer) + the durable-checkpoint glue

| # | File | Action | Why |
|---|------|--------|-----|
| P1-1 | `substrates/brandnana/boards/brand-book/agents.json` | **CREATE** | Board agent roster, `version:1`, two agents: `brand-scout` (producer) + `brandnana-strategist` (consumer), each `{id,name,type,status,capabilities}`. Model on `wb-orch/agents.json` fixture (`test/fixtures/wb-orch/agents.json:1-20`). |
| P1-2 | `substrates/brandnana/boards/brand-book/tasks/gather-org-data.json` | **CREATE** | The harvest task: `assigned_to:["brand-scout"]`, `capabilities:["bash"]`, no `blocker`. `acceptance:["command:wb query \"(and (tags point) (not (property STATUS failed)))\" ..."]` over `harvest-provenance.org` — the gate from `BRAND-DATA-HARVEST.md:181-183`. This task is the common blocker for ALL authoring tasks. Task JSON shape per `loader/task.ex:16-57` (`id,title,state,created_by,created_at,description,parent,tags,assigned_to,capabilities,acceptance,blocker`). |
| P1-3 | `substrates/brandnana/boards/brand-book/tasks/author-*.json` (one per chapter) | **CREATE** | Stage-2 authoring tasks, `assigned_to:["brandnana-strategist"]`, each `blocker:["gather-org-data"]`. Acceptance = the per-page OQL/vision/packaging gates from `BRAND-BOOK-PLAN.md:103-193`. (These can land incrementally; the producer + the gather task are the load-bearing P1.) |
| P1-4 | `substrates/brandnana/profile/skills/checkpoint-substrate.org` | **CREATE** | The durable-checkpoint discipline: after each sweep stage, `gitwork push` the substrate so a machine restart doesn't lose it (mitigation for §2.2 if the volume isn't added). Cites `/api/gitwork/push` (`router.ex:92`). |
| P1-5 | `deploy-kit/recipe/common.sh` (verify only) | **VERIFY** `WB_FORWARD_SECRETS` includes `BRANDNANA_API_KEY` (+ `GEMINI_API_KEY` if video creative analysis is in scope). | The forward allowlist is what lets the harvest verbs auth (`tool_registry.ex:194-218`); already wired for `BRANDNANA_API_KEY` per the live `creative analyze`, confirm `GEMINI_API_KEY` if §6-D is yes. |

**No engine code change is required for the happy path.** The runtime already supports uncapped
sessions, board fan-out, secret forwarding, profile-agent resolution, and gitwork push. The build is
**substrate files (agent + skills + board) + one toml/volume fix** — all data, no Elixir.
(`define_agent` POST is a 501 stub, `agent_controller.ex:225-234`, so agents MUST be files, not API
calls — which is exactly the profile-dir path.)

---

## 4. The OQL-queryable org substrate schema (so Stage 2 can query it)

OQL extracts headlines from the `wb-source-bundle` and normalizes each to
`{id, document_path, level, title, tags, properties{}}` (`oql/headlines.ex:11-22,126-139`). Every
queryable FACT must be a headline and/or a `:PROPERTIES:` key with meaningful `:tags:`. Conform to
the four existing templates so the strategist's OQL gates resolve. The producer writes these files
into `brand-<slug>/` in the shared workspace:

| Org file | Conforms to | Key headlines / tags | Primary OQL gate (Stage-2 reads) |
|----------|-------------|----------------------|-----------------------------------|
| `brand.org` | `brand.org.template:1-64` | `* <brand> :brand:` (DOMAIN/CATEGORY/TAGLINE/FOUNDED/HQ); `*** Primary palette :palette:primary:` (PRIMARY_HEX…); `*** Extended palette :palette:extended:` (≥6 swatches → satisfies palette≥6); `*** Typography :fonts:`; `*** Logo :logo:` (PRIMARY_URL/SVG_PATH); `** Social handles :social:` | `tags CONTAINS palette` → ≥6 swatch rows; `tags CONTAINS brand` → DOMAIN present |
| `catalog/products.org` | `products.org.template:1-67` | `***** <name> :product:` per product (SKU/PRICE/CURRENCY/COLORS/**IMAGES** = R2 URLs/URL/CATEGORY/COLLECTION/PRICE_BAND); 5 index sections (`:index:category:` … `:index:price-band:`) | `tags CONTAINS product` → rows >12 (catalog gate) |
| `social/<platform>.org` | NEW (extend brand schema) | `* <platform> :social:<platform>:` (FOLLOWERS/HANDLE/URL/VERIFIED); `** Top posts` with R2 thumb URLs | FOLLOWERS present per in-scope platform |
| `ads.org` | uses `competitor`/ad fields | `** <ad> :ad:<source>:` (AD_ID/MEDIA_URL=R2/CTA/LANDING_URL/HOOK/MOOD) | `tags CONTAINS ad` → rows >0 (or recorded true-negative) |
| `harvest-provenance.org` | `timeline.org.template:1-21` | `** <ts> — <point> :event:<status>:` (POINT/STATUS=ok\|failed/TOOL/DURATION_MS/VENDOR_COST + ERROR body on failure) | the FAIL-LOUD gate: `(and (tags point) (not (property STATUS failed)))` |

**Media-in-OQL.** Each media row carries its R2 URL (or inline-blob id) as a property so
"all ad creatives for brand X" is a query that returns R2 links (`BRAND-BOOK-PLAN.md:291-294`).
Policy: logos (SVG) + 1-2 heroes inline; ALL other images + ALL video R2-by-reference; the org
carries only the R2 URL. The harvest's `MediaAsset` array (`harvest.ts:127-131`) becomes the Media
rows. **Tag convention:** every harvested data point also carries the `:point:` tag so the
provenance gate (`tags point`) and the per-point STATUS check span the whole substrate.

---

## 5. Tecovas end-to-end verification plan

Run the agent, then ASSERT the substrate. Two run modes; assertions are identical.

**Run.** `POST https://bn-engine.fly.dev/api/run` (Authorization: Bearer `$WB_PUBLIC_BEARER`)
with `{"agent_slug":"brand-scout","prompt":"Harvest the full brand substrate for tecovas.com",
"workdir":"/data/brand-tecovas"}` (workdir on the volume from P0-1). Poll
`GET /api/sessions/:id` until terminal (`agent_controller.ex:183-199`). For the fan-out mode,
`POST /api/run-plan` with `board_dir=/data/boards/brand-book` instead, poll `GET /api/board`.

**Assert (all over the produced org, via `wb query` / OQL):**
1. **Palette ≥6.** `brand.org`: `tags CONTAINS palette:extended` → ≥6 swatch rows each with a hex.
   (Stage-1 union+vision recovers 8-12 for tecovas, `BRAND-DATA-HARVEST.md:153,193`.)
2. **Catalog >12.** `catalog/products.org`: `tags CONTAINS product` → >12 rows with PRICE
   (proven live: 250 products via `catalog crawl --mirror`; tecovas host-variant→sitemap→Firecrawl,
   `BRAND-DATA-HARVEST.md:158,164`). Spot-check that `IMAGES` values are
   `https://api.brandnana.net/assets/<sha>` (R2, mirrored), not hot-links.
3. **Screenshots in R2.** `brand.org` `*** Homepage`/screenshot property is an R2 `/assets/<sha>`
   URL that byte-validates as an image (HEAD 200, image content-type), not an mshots hot-link.
4. **Social + ads + company present.** `social/tiktok.org` FOLLOWERS ≈ 200k+
   (`BRAND-DATA-HARVEST.md:159`); `social/youtube.org` SUBS present; `ads.org` Google source rows >0
   (5 live creatives, `:161`); LinkedIn recorded as a TRUE-NEGATIVE (status:ok, empty) not a failure
   (`:162`); `brand.org` company props (name/desc/tagline + socials) present, firmographic nulls
   flagged `needs_key` not stubbed green.
5. **Fail-loud provenance.** `harvest-provenance.org`: every `:point:` has a STATUS; the gather-task
   acceptance `(and (tags point) (not (property STATUS failed)))` PASSES iff no point silently
   empty-failed. Deliberately blocked points (firmographics key, video Gemini) appear as explicit
   `status=needs_key`/`failed` rows with an ERROR body — the editor can skip or re-harvest, never
   ships an empty catalog (`BRAND-DATA-HARVEST.md:181-183`).
6. **Durability.** Restart the machine (`fly machine restart`), re-poll/query — the substrate
   survives on the volume (validates P0-1/P0-2). Mirrored media survives regardless (R2).

---

## 6. Open decisions for the user

- **A. Durability mechanism.** Add a Fly volume (P0-1/P0-2, simplest, survives restart) OR
  gitwork-push-per-checkpoint to R2 (P1-4, no volume, more moving parts)? Recommend the volume; it's
  one toml block and removes the only hard blocker.
- **B. Run mode for v1.** Single uncapped `/api/run` (brand-scout fans its own sub-agents up to
  `MAX_CHILDREN 8`) OR the full board (`/api/run-plan`, gather-task blocks authoring tasks)?
  Recommend `/api/run` for the Tecovas proof, board once the producer is verified.
- **C. Ad/social media bucket.** Confirm the ad/social singleton mirror prefix is the SAME
  `brandnana-assets` bucket `catalog --mirror` uses (`BRAND-BOOK-PLAN.md` OPEN DECISION 4) — a
  verification, blocks nothing.
- **D. Video creative analysis.** Provision `GEMINI_API_KEY` (add to `WB_FORWARD_SECRETS`) for real
  video analysis, or accept the poster-frame still fallback for v1? (`BRAND-BOOK-PLAN.md:338`.)
- **E. Firmographics page.** Drop it, or mark `status=needs_key` (THE_COMPANIES_API_KEY orphan,
  `BRAND-BOOK-PLAN.md:336-338`)? Recommend `needs_key` so the editor sees the gap.
- **F. Retire the standalone Worker harvester?** The engine path is strictly more capable; confirm
  whether the live `book/harvest.ts` Worker harvestBrand stays as a fast one-shot fallback or is
  retired in favor of the engine producer.

---

## RETURN

### 12-line summary
1. The Brand Scout is a PRODUCER profile agent — an org headline with `:TOOLKITS: bash brandnana`, parsed by `AgentDef` (`agent_def.ex:210-238`), resolved by slug from `WB_PROFILE_DIR=/opt/profile` (`agent_controller.ex:293-301`, `Dockerfile.engine-profile:114`).
2. Its one tool is bash (`tool_registry.ex:35-56`); it shells the brandnana CLI for every harvest verb — no HTTP, no second tool.
3. Run it via `POST /api/run` (uncapped single session, no MAX_TURNS — `session_runner.ex:24-27`) or `POST /api/run-plan` (board fan-out, verification-gated — `dispatcher.ex:138-163`).
4. Secrets reach the harvest because `WB_FORWARD_SECRETS` forwards `BRANDNANA_API_KEY` past the env scrub (`tool_registry.ex:194-218`); the deploy wires it in `recipe/common.sh:113-135`.
5. Media: products via `catalog crawl --mirror` (SQLite→R2, proven live tecovas — `catalog.ts:42-72,190-194`); singletons via `POST /mirror/images` → `api.brandnana.net/assets/<sha>` (`mirror/routes.ts:67-108`); the book is published by `brandnana book`.
6. The durable record is the org substrate + R2 — NOT the sessions API (in-memory only, `agent_controller.ex:26-31`).
7. WORKS TODAY: bn-engine up, 1/1 checks, brandnana binary live, all run/board/spawn/gitwork APIs routed (`router.ex:66-95`).
8. BLOCKER #1 (config drift): `fly.bn-engine.toml:13` points at the brandnana-LESS `Dockerfile.engine` — next deploy breaks every verb; repoint to `Dockerfile.engine-profile`.
9. BLOCKER #2 (ephemeral workspace): no Fly volume, `WB_DATA_ROOT=/tmp/wb` (`fly.bn-engine.toml:19`) — substrate + catalog SQLite lost on restart, only R2 durable; add a volume.
10. The substrate conforms to four existing templates (`brand`/`products`/`competitor`/`timeline`.org.template) so the strategist's OQL gates query it; provenance is the fail-loud gate `(and (tags point) (not (property STATUS failed)))`.
11. Build = substrate FILES (agent + 4 skills + board agents.json + gather-task), one toml/volume fix — zero Elixir; `define_agent` is a 501 stub so agents must be files (`agent_controller.ex:225-234`).
12. Tecovas proof: run brand-scout → assert palette≥6, catalog>12 with R2 image URLs, screenshots byte-valid in R2, social+ads+company present, LinkedIn true-negative, fail-loud provenance gate passes, substrate survives a machine restart.

### Prioritized FILE / BUILD list
P0 (deploy runnable + producer defined):
- EDIT `deploy-kit/cloud/fly.bn-engine.toml` — dockerfile → `Dockerfile.engine-profile`; `WB_DATA_ROOT` → volume mount `/data`; add `[[mounts]]`.
- CREATE Fly volume `wb_data` on `bn-engine` (one-shot `fly volumes create`).
- CREATE `substrates/brandnana/profile/agents/brand-scout.org` (producer agent; model on `brandnana-strategist.org`).
- CREATE `substrates/brandnana/profile/skills/harvest-sweep.org` (manifest + escalation + verify predicates + fail-loud).
- CREATE `substrates/brandnana/profile/skills/write-substrate.org` (org schema + R2 lanes).

P1 (board seam + durable checkpoint):
- CREATE `substrates/brandnana/boards/brand-book/agents.json` (brand-scout + brandnana-strategist, `version:1`).
- CREATE `substrates/brandnana/boards/brand-book/tasks/gather-org-data.json` (harvest task; acceptance = provenance OQL gate; common blocker).
- CREATE `substrates/brandnana/boards/brand-book/tasks/author-*.json` (Stage-2 tasks, `blocker:["gather-org-data"]`; incremental).
- CREATE `substrates/brandnana/profile/skills/checkpoint-substrate.org` (gitwork-push checkpoint discipline).
- VERIFY `deploy-kit/recipe/common.sh` `WB_FORWARD_SECRETS` includes `BRANDNANA_API_KEY` (+ `GEMINI_API_KEY` if video).

### Open decisions
A. Volume vs gitwork-checkpoint for durability (recommend volume).
B. `/api/run` vs `/api/run-plan` board for v1 (recommend `/api/run` for the proof).
C. Confirm ad/social mirror writes the same `brandnana-assets` bucket as catalog `--mirror`.
D. Provision `GEMINI_API_KEY` for video creative analysis, or accept poster-frame fallback?
E. Firmographics page: drop, or mark `needs_key` (recommend `needs_key`)?
F. Retire the standalone Worker `harvestBrand`, or keep as a fast one-shot fallback?
