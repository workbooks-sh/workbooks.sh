# Production /v1/agent fails silently on full book runs (2026-06-05, wb-syjo)

LIVE FINDING from an actual Tecovas run (`do it yourself`).

## What happened

- `POST /v1/agent {query:"brand book for tecovas.com"}` → 200, planned a
  presentation, returned slug `tecovas-com-presentation-mq0j57ev` + a status_url.
- ~7+ min later: book URL still **404**, status manifest **never written** (R2
  `agent-jobs/<slug>/status.json` → "key does not exist"), `wrangler tail` idle.
- Net: **no book, no error surfaced, no trace.** Silent death.

## Root cause (high confidence)

`/v1/agent` runs `executePlan` in the CF Worker via `c.executionCtx.waitUntil`.
A full presentation build (scrape → multi-LLM analysis → image gen → compose)
exceeds the Worker's execution budget and is killed mid-flight, before it can
`ASSETS.put` either the book or the status manifest. The `plan_only` phase (sync,
~2s, one deepseek call) works fine — confirming the dispatch + auth + planner are
healthy; only the long async EXECUTE dies.

## Why this matters / connection to the cutover

This is the concrete evidence for **wb-3uh3** (cut over to the Workbooks Engine on
Fly). Long-running agent book builds DON'T fit a CF Worker. The engine pipeline
(`bn-engine`, `strategist.org` skills, the deck-v2 work this loop hardened) exists
precisely to run this work with no time limit AND full `wb trace` observability.
The 14 loop iterations are validated as necessary: the engine is the only place a
real deck-v2 book can complete.

## Observability gap

Even the failure is invisible: no manifest = the status endpoint says "unknown"
forever, indistinguishable from "still running". A real run needs the engine's
durable trace (`wb trace`), not a best-effort R2 manifest written only on success.

## Next

Run the book through the ENGINE (`bn-engine`), not the worker — exercises the
deck-v2 pipeline + emits a durable trace. See wb-sxqs (run-book.sh targets the
worker /v1/agent; needs an engine-dispatch variant).
