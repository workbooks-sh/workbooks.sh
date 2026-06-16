# crew — the bit.ml multi-agent keeper manifest (wb-wc0.2)

A CREW MANIFEST: each entry is an AGENT; its properties are its config.
Point `WB_CREW_DEF` at this file and `Workbooks.Keeper.Crew` starts one
keeper worker per member — each with its own def, its own lifecycle, and
persistence keys namespaced by the agent's name. Workers start staggered
(`WB_CREW_STAGGER_MS`, default 30s) and share a global concurrency cap
(`WB_CREW_MAX_CONCURRENT`, default 2 — the rest queue).

Properties honored per agent:

- `DEF: <path>` — REQUIRED. The agent def to run each wake tick. A member
  without `DEF` is skipped.
- `LIFECYCLE: <path>` — OPTIONAL. A lifecycle state-machine spec (see
  `examples/lifecycle.md`). Absent → plain interval ticks.
- `INTERVAL: <dur>` — fallback cadence (10m | 2h | 90s | bare ms). Default 1h.

Board claims are a DEF-LEVEL protocol, NOT runtime-enforced: when crew members
share a task board, the claiming agent commits a board state change + an
`AGENT` property to git BEFORE doing the work, visible to peers. The runtime
only isolates runs (per-worker state) and throttles concurrency.

## members

- **wren** — DEF: `/data/agents/writer.html`, LIFECYCLE: `/data/lifecycles/writer.md`, INTERVAL: 10m.
  The writer: drafts new sections on its lifecycle (wake_add ×N → audit → rem).
- **moss** — DEF: `/data/agents/editor.html`, INTERVAL: 20m.
  The editor: interval ticks (no lifecycle), tightening + correcting drift.
