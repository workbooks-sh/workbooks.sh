# Postgres-as-Capability: Novelty Research

*Strategy memo. Date: 2026-06-14. Companion to `docs/HOSTED-NEXUS-ECONOMICS.md` §5 (the Neon cost analysis). This memo answers a different question than §5: not "what does a DB addon cost" but "where does adding Postgres make the WHOLE NEXUS qualitatively better." A commodity "want a database too?" upsell is explicitly rejected — developers would BYO and it doesn't fit the brand.*

---

## TL;DR — the ranking

| # | Direction | What it unlocks | Non-commodity? | Build cost |
|---|---|---|---|---|
| **1** | **Postgres becomes the org substrate's derivation/retrieval backend** (Context Tree + sessions + memory + telemetry, one queryable corpus across workbooks/sessions, pgvector ANN replacing the baked embedder) | Cross-workbook / cross-session **queryable history + semantic memory** that the per-instance SQLite/jsonl silos *structurally cannot* do | **Yes** — the value is OUR substrate schema + tenant-scoping + Derivation layer, not "a database." BYO-DB gets you an empty Postgres, not this. | **Low–Med** (~60% built) |
| **2** | **Neon branching as the org-state time-machine** — agent "what-if" branches, workbook preview environments, durable point-in-time rollback of the whole nexus state, merge-back | A first-class **branch/preview/what-if** primitive for an entire nexus's state in seconds, at near-zero idle cost | **Yes** — copy-on-write fork of a *live multi-GB org+vector corpus* is a Neon storage-engine feature; you cannot DIY it on a raw Postgres URL | **Med** |
| **3** | **"We vendor our multi-tenant org layer" — the nexus gives the USER'S app a managed multi-tenant backend** | The tenant's own app inherits our tenant-scoping + org/vector/telemetry substrate on top of Postgres, for free | **Yes** — it's the substrate-as-a-service, not raw SQL | **Med–High** |
| 4 | **Cross-tenant fleet analytics for the operator** (telemetry warehouse) | Operator-grade fleet observability over all sessions/runs | Partial — useful but more "ops feature" than brand-defining; folds into #1 | Low |

**#1 is the recommendation.** It is the cheapest (the seams already exist), the most brand-true (it makes the *Context Tree pivot* real instead of aspirational), and it's the one a developer fundamentally cannot replicate by connecting their own empty Postgres — because the value is the **schema + tenant-scoping + Derivation layer we vendor on top of it**, not the SQL engine. #2 is the high-magic follow-on once #1 puts real state in Postgres. #3 is the eventual platform play. #4 is a free byproduct of #1.

---

## Grounding: how the nexus stores state TODAY, and the wall each store hits

Every durable surface in the runtime today is a **per-instance / per-workdir silo of flat files or single-file SQLite**. That is fine for one box and one workbook. It is the exact shape that *cannot* answer a cross-workbook, cross-session, or fleet-wide question — and that limit is structural, not a tuning problem.

| Surface | Store today | File | The wall |
|---|---|---|---|
| **Org files / workbooks / Context Tree** | per-tenant **git repo** (`WB_DATA/<tenant>`); "queries" are `oql.wasm` **re-parsing org text in WASM** every call (`parse_headlines`, `(tags :toolkit:)`) | `git.ex`, `oql.ex`, `toolkits.ex` | No relational query, no joins, no index. Every Context-Tree query is a full re-parse of text. Mutation is **line-level text surgery** (`org_edit.ex`) — no transactions, no concurrent-writer safety. **The Context Tree's Retrieval/Derivation layers have no engine** — they're string-grep over org. |
| **Instance state (working tree, agent memory)** | **one SQLite file per Instance** (VFS), Litestream→R2 | `vfs.ex`, `litestream.ex`, `instance.ex` | Hard per-instance silo by design. Two instances cannot query each other's state. Memory volume dies with the instance unless replicated; there is no cross-instance memory. |
| **Session history / transcripts** | `_steps.jsonl` appended per-workdir; `wb-sessions.jsonl`; per-run transcript JSON | `agent.ex` (`log_step`), `session_ledger.ex`, `ledger.ex` | Flat append-only files. "List my sessions" = read a jsonl and reverse it. **No query** ("which runs touched workbook X", "what did the agent learn last Tuesday", "every tool call that failed across all sessions") — that's a full-scan-and-parse, and it's siloed per workdir. |
| **Semantic memory / search** | `Workbooks.Vector`: **SQLite = vectors-as-JSON + brute-force cosine in Elixir, O(n)**, warns past 25k vectors. Embeddings from a **baked ~30 MB Model2Vec** (dim 256, in every image). | `vector.ex`, `embed.ex` | Brute-force semantic search doesn't scale; the in-image embedder is a fixed small model shipped in every tenant container (§1 of economics flags it as 30 MB dead weight). **`vector.ex` ALREADY HAS a complete pgvector path** — it's just gated behind `WB_DATABASE_URL`. |
| **Autopoet metacognitive backlog** | org files `WB_DATA/autopoet/issues/*.org` | `autopoet.ex` | The system agent's backlog is ungueryable text files. "What capabilities have tenants asked for, ranked by frequency across the fleet" = ls + regex. |
| **Durable KV** | per-tenant SQLite, 64 MB cap | `storage_broker.ex` | Fine as KV; no relational shape. |
| **The BYO-DB seam** | `Workbooks.DB`: SQLite default, **Postgres the instant `WB_DATABASE_URL` is set** — one URL, any provider. Drives Vector, vars, the ledger index. | `db.ex` | **This is the lever.** It already speaks Postgrex behind a URL with portable `?1→$1` SQL. Today the URL is **one process-global**; a per-tenant fleet needs a tenant→DSN registry (the only real greenfield piece, also noted in economics §5). |

**The through-line:** the runtime's *structured* stores all already route through one seam (`Workbooks.DB`) that is Postgres-ready, and the vector store already has the pgvector implementation written. What's missing isn't code — it's **putting the org substrate's Retrieval/Derivation layers onto a real relational+analytical engine instead of WASM-re-parsing org text and brute-forcing cosine.** That's where Postgres stops being a commodity database and becomes the engine the Context Tree pivot has been describing.

---

## #1 — Postgres as the org substrate's Retrieval + Derivation engine  ★ RECOMMENDED

### What it is

Stand up the **Context Tree's three layers (Retrieval / Mutation / Derivation)** on Postgres for a hosted nexus. Concretely: the runtime continues to keep org files as the human-facing, diffable, git-versioned **source of truth** (Mutation stays org + git — "behavior belongs in the config layer"), but it **projects** that org corpus — plus session history, agent memory, telemetry, and the autopoet backlog — into a **relational + pgvector** schema in the tenant's Postgres. Retrieval and Derivation then run as *real queries* instead of WASM org-reparse and O(n) cosine.

This makes possible, in one nexus, the queries the silo architecture structurally can't answer:

- "Across **every workbook and every past session**, what has this agent learned about X?" — one pgvector ANN over the whole tenant corpus instead of per-instance brute force on a 30 MB baked model.
- "Which runs touched workbook X, failed at tool Y, and what changed in the org tree afterward?" — a join across the (today siloed) `_steps.jsonl`, ledger, and org-headline projections.
- Derivation views: live materialized rollups (kanban state, toolkit inventory `(tags :toolkit:)`, session leaderboards, memory freshness) that today are recomputed by re-parsing text on every request.

### What it replaces / improves

- **Replaces** the baked ~30 MB Model2Vec + SQLite brute-force cosine with **pgvector ANN** — the code path is *already written* in `vector.ex`; flipping `WB_DATABASE_URL` activates `CREATE EXTENSION vector`, `vec <=> query::vector` ANN. Server-side semantic search that scales past the in-image model and past 25k vectors (the current warn line). Also trims the per-tenant image (economics §1 lever 5).
- **Replaces** per-workdir `_steps.jsonl` / `wb-sessions.jsonl` / transcript-JSON scans with a **queryable session+telemetry table** — cross-session, cross-workbook, indexed.
- **Upgrades** Context-Tree Retrieval from "re-parse org text in WASM each call" to indexed relational lookup; Derivation gets a real place to live (materialized views) instead of being recomputed per request.
- **Keeps** org+git as Mutation/source-of-truth — Postgres is the *derived, queryable projection*, never the canonical store. This is the brand-correct split: the human edits diffable org; the system queries the projection.

### Why it's NON-COMMODITY (a dev can't DIY it)

If a developer BYO-connects their own empty Postgres, they get… an empty Postgres. The value here is **the substrate we vendor on top of it**: the org→relational projection, the tenant-scoping-by-construction (`tenant` is the first column of every row — already true in `Workbooks.Vector` and `StorageBroker`), the pgvector schema dimensioned to our embedder, the session/telemetry/ledger model, and the Derivation views. **You're not selling Postgres; you're selling the Context Tree with an engine under it.** That is precisely the thing the "Context Tree pivot" memory describes (one org substrate + Retrieval/Mutation/Derivation) — Postgres is what makes the Derivation layer real instead of a slide.

### Brand fit

Dead center. It honors: *Context Tree pivot* (gives Retrieval/Derivation an engine), *OQL as a query language* (OQL/org stays the query surface; Postgres becomes one of its backends — the same way `Workbooks.DB` already abstracts SQLite/PG), *behavior belongs in the config layer* (mutation stays org+git; PG is derived), and *autopoet* (the backlog becomes queryable, so the system agent can reason over fleet-wide capability demand). It is convenience **and** a genuine capability the nexus lacks today.

### Build cost — **Low–Med** (~60% already exists)

- **Done:** `Workbooks.DB` Postgrex seam + portable SQL; `Workbooks.Vector` full pgvector path; tenant-scoping convention; `Workbooks.Embed.OpenRouter`/`Http` external-embedder adapters (so you can drop the baked model for a hosted embedder feeding pgvector).
- **To build:** (a) **tenant→DSN registry** + `DB.open` resolving DSN by tenant (the one real greenfield piece, also called out in economics §5 — needed for ANY per-tenant DB feature); (b) the **org→relational projector** (headlines/props/tags/sessions/steps → tables) running on commit/run-complete; (c) Derivation **materialized views**; (d) point the hosted embedder at pgvector (drop the 30 MB image weight). The projector is the only net-new substantial module.

### No-lock-in

Strict. Org files + git remain the canonical source of truth — Postgres is a *rebuildable projection*. BYO-DB still works: set `WB_DATABASE_URL` to your own Postgres and you get the same substrate; omit it and the nexus runs on SQLite + the baked embedder exactly as today (just slower/smaller, with the brute-force warn). Nothing about #1 cages the user — it's the managed, scaled tier of a capability that degrades gracefully to local.

---

## #2 — Neon branching as the org-state time-machine

### What it is

Use **Neon's copy-on-write branching** as a runtime primitive over the whole projected nexus state (the #1 corpus). Three concrete products:

1. **Agent "what-if" branches.** Before a risky multi-step agent run, branch the org+vector+session state; the agent operates against the branch; the operator diffs and **merges back or discards**. Today an agent mutating org is committing to one timeline (git WIP snapshots in `git.ex` are the closest, and they only cover the org files, not memory/vectors/telemetry).
2. **Workbook preview environments.** A branch = a full preview of the nexus's queryable state at a point in time, spun in seconds at near-zero idle cost (Neon branches are CoW + scale-to-zero).
3. **Point-in-time rollback of the entire nexus state**, not just the git org tree — including derived memory and telemetry.

### Why non-commodity

A copy-on-write fork of a **live, multi-GB org + pgvector + telemetry corpus in seconds** is a property of Neon's storage engine (branch = pointer into the shared page store). You **cannot** reproduce it by connecting a raw Postgres URL — vanilla Postgres has no instant CoW branch; you'd be doing `pg_dump`/restore (minutes to hours, full storage cost). This is the clearest case where the *managed provider's engine feature itself* is the moat, layered on top of #1's substrate.

### Brand fit / build cost / lock-in

Brand: strong — "branch your agent's reality, merge what worked" is a genuinely novel, on-brand capability (agents editing a declarative substrate, now with safe what-if). Cost: **Med** — needs #1 first (you can only branch state that's IN Postgres), plus the Neon Projects/Branch API wiring and a merge-back/diff UX (the hardest part — reconciling a branched org tree back onto main; git already does org-file merge, so scope branching's merge to the *derived* tables + let git own org-file merge). Lock-in: branching is a **convenience tier** — BYO-Postgres users simply don't get instant branching (they can still snapshot the slow way); the core nexus is unaffected. No cage.

---

## #3 — "We vendor our multi-tenant org layer" — the user's app gets a managed backend

### What it is

The strongest version of the upsell-inversion. Because the runtime's substrate is **already tenant-scoped by construction** (`tenant` first column everywhere; `:multi` tenancy enforces JWT-org identity, `tenancy.ex`), a hosted nexus + Neon can expose **that same substrate as a backend for the user's OWN application** — their app inherits our org/vector/telemetry/multi-tenant model on Postgres, rather than us handing them a blank DB. The nexus stops being "where my agents run" and becomes "the managed, multi-tenant, queryable backend my product is built on."

### Why non-commodity / brand fit

Non-commodity because the product is **the substrate-as-a-service** (tenant isolation, org/relational projection, pgvector memory, the Derivation layer) — not raw SQL. A dev with their own Postgres rebuilds all of that themselves; here it's inherited. Brand fit is good and forward-looking (it's the platform endgame of the Context Tree pivot), but it's the **biggest leap from today's product** ("software built in workbooks" → "build your product on our backend") and needs a real external API contract + multi-tenant hardening (economics §8's unhardened-root-container risk lands hardest here, since now the *user's customers'* data is in the shared substrate).

### Build cost / lock-in

**Med–High** — needs #1, a stable external query/API surface, quotas, and the isolation hardening from economics §3/§8 before it's safe to sell. Lock-in: must be designed as "your data, your Postgres, exportable" — the org-source-of-truth discipline from #1 is what keeps it non-cage. Sequence it *after* #1 proves the substrate and #2 proves branching.

---

## #4 — Cross-tenant fleet analytics (operator telemetry warehouse)

Project all sessions/steps/ledger/autopoet across the fleet into Postgres for **operator-grade observability** (per-tenant usage metering — the exact thing economics §7.5 needs to make cost `C` measured rather than estimated; capability-demand ranking for the autopoet; fleet health). Useful and **Low** cost, but it's an internal ops capability more than a brand-defining customer feature — and it falls out **for free** as a byproduct of #1's projector and tenant→DSN registry. List it, don't lead with it.

---

## Recommendation

**Build #1.** It is the cheapest (the DB seam and the entire pgvector path already exist — the only substantial net-new module is the org→relational projector, which is also the prerequisite for everything else), the most brand-true (it turns the Context Tree pivot's Retrieval/Derivation layers from aspiration into a running engine, replaces the baked 30 MB embedder with scalable pgvector ANN, and unlocks the cross-workbook/cross-session queries the per-instance SQLite/jsonl silos *structurally cannot* serve), and the most defensibly non-commodity (the value is **our substrate vendored on Postgres**, not the database — a developer who BYO-connects an empty Postgres gets nothing of it). Crucially it **degrades gracefully**: no `WB_DATABASE_URL` ⇒ the nexus runs exactly as today on SQLite + the baked embedder, and any BYO Postgres URL gets the same managed substrate — convenience and capability, never a cage.

Then layer **#2 (Neon branching)** as the high-magic follow-on once real state lives in Postgres, and hold **#3 (substrate-as-backend)** as the platform endgame pending the multi-tenant isolation hardening that economics §3/§8 already flags. **#4** ships for free alongside #1.

**One open dependency gates all of these** (and is independently required by economics §5): the **tenant→DSN registry** — today `WB_DATABASE_URL` is a single process-global in `db.ex`. Build that registry first; it's the keystone for every Postgres direction.
