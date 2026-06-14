# Org Substrate Engine — one substrate, swappable projection engine

*Design memo. Date: 2026-06-14. Companion to `docs/POSTGRES-NOVELTY-RESEARCH.md` (#1) and `docs/HOSTED-NEXUS-ECONOMICS.md` §5. Answers the three questions the Postgres direction raises: (a) what changes for LOCAL deployments, (b) are we now maintaining two versions of the org substrate (drift?), (c) where does this leave us long term.*

---

## The one principle that makes the rest fall out

**There is ONE substrate. Org files + git are the canonical source of truth, everywhere — local, desktop, cloud. Postgres (and the SQLite we use today) is never a second source of truth; it is a *derived, rebuildable projection* of the org corpus.**

That single rule is the whole answer to the drift fear. The classic "two databases drift apart" failure happens when you have **two masters** — two places that can both be authoritative, that must be kept in sync. We never have that. We have:

- **Master (Mutation):** org + git. The human and the agent edit diffable org text. Always.
- **Projection (Retrieval + Derivation):** an *index* built **from** the master by a deterministic projector. Throw it away, rebuild it from git, get the identical result. It cannot "drift from" the master any more than a search index drifts from the documents it indexes — it's a pure function of them.

So the question is **not** "SQLite substrate vs Postgres substrate." It is "which **engine** projects and serves the one substrate." That's a swappable backend behind one interface — componentization (Golden Rule #3), the opposite of duplication.

```
            ┌─────────────────────────────────────────────┐
            │  CANONICAL SOURCE OF TRUTH  (Mutation)        │
            │  org files + git   — byte-identical everywhere│
            └───────────────────────┬─────────────────────┘
                                    │  projector (deterministic, replayable)
                       ┌────────────┴─────────────┐
                       ▼                           ▼
        ┌──────────────────────────┐   ┌──────────────────────────┐
        │  EMBEDDED engine          │   │  POSTGRES engine          │
        │  (default, zero-infra)    │   │  (cloud / opt-in tier)    │
        │  SQLite + OQL reparse +   │   │  relational + pgvector    │
        │  baked/external embedder  │   │  (a SUPERSET of embedded) │
        └──────────────────────────┘   └──────────────────────────┘
              one Retrieval / Derivation INTERFACE, two adapters
```

This is not a new pattern for us — `Workbooks.DB` **already** abstracts SQLite vs Postgres behind one URL with portable `?1→$1` SQL, and `Workbooks.Vector` **already** has both the brute-force-SQLite and the pgvector path behind that same seam. We are extending a pattern the codebase already uses for the structured stores up to the org/Retrieval/Derivation layer — not inventing a fork.

---

## The two engines, concretely

| | **Embedded engine** (default) | **Postgres engine** (opt-in) |
|---|---|---|
| **Trigger** | no `WB_DATABASE_URL` | `WB_DATABASE_URL` set → resolved per-tenant via the DSN registry |
| **Retrieval** | `oql.wasm` re-parses org text per call; SQLite lookups | indexed relational queries over the projected tables |
| **Derivation** | recomputed per request (re-parse) | materialized views, refreshed by the projector |
| **Semantic memory** | SQLite vectors-as-JSON + brute-force cosine, O(n), warns past ~25k; baked ~30 MB embedder | `pgvector` ANN, scales past the warn line; external/hosted embedder (drops the 30 MB image weight) |
| **Scope it can answer** | **one instance / one workdir** at a time | **cross-workbook, cross-session, cross-instance, fleet** |
| **Infra required** | none (file + SQLite) | a Postgres (Neon in our cloud; or BYO) |
| **Where it runs** | desktop, local, offline, any self-host | hosted nexus, or any tier that opts in |

The Postgres engine is deliberately a **superset**: it answers everything the embedded engine answers, *plus* the queries the per-instance silos structurally can't (the cross-* and at-scale ones), *plus* the provider-engine features (Neon branching, §2 of the research memo).

---

## (a) What changes for LOCAL deployments? → Nothing is forced; Postgres is opt-in at *every* tier

**Default local / desktop deploy ships zero database infrastructure and behaves exactly as it does today.** The embedded engine is the floor. This is non-negotiable and protects two brand lodestars already on record: *zero-infra default* and *desktop offline-first boot* (the desktop must boot and view workbooks with no engine/DB gate).

Crucially, **Postgres is not "the cloud version of the runtime." It's an opt-in engine available at any tier:**

- **Local default:** no DB. Embedded engine. Offline, zero-infra. Same as today.
- **Local power user / self-hoster:** *may* attach their own Postgres to a local nexus and get the scaled tier (cross-workbook queries, pgvector ANN) on their own box. Optional, never required.
- **Dev parity:** point a local nexus at a local Postgres (or a Neon branch) to test the cloud tier's behavior before deploying. Optional.
- **Our cloud (Fly + Neon):** the Postgres engine is provisioned for the tenant as the managed, scaled tier.

So the answer to *"do we deploy local with Postgres?"* is: **only if someone asks for the scaled tier.** The default local deploy has no Postgres, the same workbook runs identically, and a workbook authored locally carries **byte-identical org source** to the cloud — the cloud simply builds a richer index over those same bytes. Nothing about a workbook is "Postgres-shaped" or "SQLite-shaped"; the org is the org.

---

## (b) Are we maintaining two versions of the org substrate? → No. One substrate, one interface, two adapters

We are **not** maintaining two org substrates. The org substrate (org + git) is singular and identical everywhere. What we maintain is **two adapters behind one Retrieval/Derivation interface** — the same way we already maintain a SQLite adapter and a Postgres adapter behind `Workbooks.DB`.

The real, honest risk is narrower and manageable: **feature drift between the two adapters** — a query the Postgres engine can serve that the embedded engine can't (or serves differently). We contain it with three disciplines:

1. **The interface is the contract.** Retrieval/Derivation is defined as a behaviour (`@callback`s), exactly like the existing `Workbooks.Storage` and `Workbooks.DB` seams. Both engines implement it.
2. **A shared conformance suite** that both adapters must pass for the **common subset** (the queries the embedded engine is expected to answer). If the embedded engine can't answer a "floor" query, that's a bug, caught in CI — not silent divergence.
3. **Explicit tiering of superset features.** Postgres-only capabilities — instant Neon branching, cross-tenant fleet analytics, ANN past ~100k vectors — are **named cloud-tier extensions**, not surprises. The embedded engine is the *guaranteed floor*; the Postgres engine is *floor + documented extensions*. Tiering is a product decision we make on purpose, not drift that happens to us.

And the structural safety net that makes this fundamentally safe: **because Postgres is a rebuildable projection, there is no canonical data trapped in it.** Drop the entire Postgres index, replay the projector over git history, and you're whole. The split-brain / two-masters failure mode — the thing "drift" usually means — *literally cannot occur*, because there is only ever one master.

### The one net-new module that enforces this: the projector

The projector is what keeps the projection faithful to the source. It runs on **org commit** and **run-complete**, and projects:

```
org headlines / properties / tags   ─►  relational tables (indexed)
session steps / transcripts / ledger ─►  sessions + telemetry tables
agent memory                         ─►  pgvector rows (tenant-scoped)
autopoet backlog                     ─►  queryable issues table
derivation rollups                   ─►  materialized views
```

It is **idempotent and content-addressed** (same org input → same projected rows), so it can be re-run any time and **replayed from git history** to rebuild the index from scratch. Because the projection is a *pure function of the org corpus*, it cannot diverge from it — re-running the projector is the reconciliation. This is the module that makes "Postgres is derived, never canonical" true in code rather than in a slide.

---

## (c) Where does this leave us long term?

**One substrate, two engines — permanently, and as a feature, not a tax.** It extends a pattern the runtime already runs (`Workbooks.DB` SQLite/PG behind one URL) up to the org layer, so it isn't new surface area to babysit; it's the same seam, one level higher.

What each engine buys us long term:

- **The embedded engine keeps the promises that make Workbooks *Workbooks*:** zero-infra, offline, desktop-native, a single `.html`/local nexus that needs no server. We never trade this away — it's the floor and the brand.
- **The Postgres engine is the scale/cloud tier** that turns the Context Tree pivot from a slide into a running engine: Retrieval/Derivation get a real query engine, the 30 MB baked embedder is replaced by scalable pgvector ANN, and the cross-workbook / cross-session / fleet queries (and later Neon branching, and later substrate-as-backend) become possible. These are the differentiated, non-commodity capabilities — and they degrade gracefully to the embedded floor, so they're never a cage.

**The discipline to hold long term** (so this stays clean):

- **Org + git is the only master. Forever.** Every new capability must be expressible as a projection of org, or it doesn't belong in the substrate. (Mirrors the existing canon: *behavior belongs in the config layer.*)
- **The interface is sacred; conformance tests guard the floor.** A feature is either in the common subset (both engines) or an explicitly named superset extension. No third category.
- **Don't let cloud-only capabilities leak into floor expectations.** Docs and UX must be honest that branching/fleet/ANN-at-scale are the Postgres tier.

Net: this is not "SQLite Workbooks vs Postgres Workbooks." It is one Workbooks whose org substrate can be served by a zero-infra embedded engine or a scaled Postgres engine, with the org files as the portable, canonical truth that lets a workbook move between them losslessly. That's the same shape as the platform canon (*one frontend, many targets; swap providers behind one seam*) applied to the substrate layer.

---

## Practical build sequence (all behind the one interface)

1. **Tenant→DSN registry** — the keystone (today `WB_DATABASE_URL` is one process-global in `db.ex`). Required by every Postgres direction and by economics §5. Build first.
2. **Retrieval/Derivation interface + conformance suite** — define the behaviour; make today's SQLite/OQL path the embedded adapter that passes it. (Largely formalizing what exists.)
3. **The projector** — org/sessions/memory/telemetry → tables + pgvector, idempotent, git-replayable. The one substantial net-new module.
4. **Postgres adapter + derivation materialized views** — implement the superset behind the interface; flip the already-written pgvector path on via the registry.
5. **External embedder → pgvector** — drop the 30 MB baked model for a hosted embedder feeding pgvector (also trims the image, economics §1).

Each step is shippable and reversible; none of them changes the default local deploy, which keeps running on the embedded engine throughout.
