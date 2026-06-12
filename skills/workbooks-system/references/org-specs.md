# Org-file surfaces — the specs the runtime executes

Workbooks has no DSL. Native Org outlines ARE the specs: TODO keywords are
states, nesting is sub-structure, the `:PROPERTIES:` drawer carries edges and
gates. These are **loaded artifacts** — they hot-swap on a live engine (a spec
is re-read each tick), unlike the host engine code. Property keys are upcased on
parse, so `:next:` and `:NEXT:` are equivalent.

TOC: agent def · workflow (component DAG) · workflow TODO outline · lifecycle
state machine · dream journal · toolkit manifest · deployment/publish configs

## Agent definition (`:agent:` node)

An agent is authored as Org and discovered like a toolkit. The first
`:agent:`-tagged headline is the agent; its `** System prompt` subsection is the
system prompt.

- `:ID:` — the agent id (the headline's id).
- `:MODEL:` — the LLM model id (honored by the run; overridable per call).
- `:TOOLKITS:` — a whitespace-separated list of toolkit ids the agent may use.
  These are auto-injected into the system prompt as a compact index (progressive
  disclosure tier 1); the skill bodies stay on demand via the `wbx` tool.
- `:TAGLINE:` — a short description.
- **System prompt** — everything under `** System prompt`, up to the next level-1
  or -2 heading (so deeper `***` subsections like Recipes stay part of it).

A running agent has one tool worldview: a WASM-sandboxed `shell` plus `search`,
`wbx`, `fetch`, `vfs_read/write`, and `done`. Trusted agents also get a real-CLI
`run` escape hatch (granted by `exec`), being retired as CLIs become WASM commands.

## Workflow — component DAG (`:workflow:` node)

A `:workflow:`-tagged headline IS the orchestration DAG; there is no separate
board model:

- `:component:` children are the **tasks**.
- `:out`→`:in` header args are the **edges** (output piped to input).
- nested `:workflow:` headings are **sub-workflows** (recursed into).
- a component with `#+begin_src agent` runs the agent loop (its source block is
  the system prompt, the piped input is the task) — so a workflow can fan out
  sub-agents. Any other component is a WASM filter.

Running a workflow executes it topologically, piping along edges, yielding nested
run records with the schedule surfaced. `?plan=1` (or `wb tangle`) returns the
schedule without executing.

## Workflow TODO outline (native org states)

A native TODO outline run as a workflow — no custom tags. The outline IS the
state machine:

- **TODO keywords are task states.** Default set: `TODO NEXT WAITING DOING
  STARTED BLOCKED` → `DONE CANCELLED CANCELED`. Override with a `#+TODO:` line.
- **Heading nesting** = sub-workflows (a parent with children is composite) vs.
  units of work (a leaf is a task an agent executes from its heading + body).
- **`:ORDERED: t`** on a parent → its children run **sequentially** (a pipeline);
  its absence → children are independent and run **in parallel**.
- **`:BLOCKER:`** = an explicit edge (wait for that task id).
- **`done-when` / `:check`** = the acceptance gate ("unit tests for org mode"). A
  leaf reaches `DONE` only when its validation passes: a `:DONE-WHEN:` shell
  command (exit 0), or a `#+begin_src sh :check` block in the body. No check →
  the agent's own completion stands.
- **`#+begin_src retrieve :k N`** in a leaf body = a native (non-LLM) semantic
  recall step: search the working context, write the result to `scratch/`, hand
  it downstream.
- Already-`DONE` tasks are skipped, so a run is resumable. Each run shares a
  `scratch/` working-memory dir and writes `_steps.jsonl` + a sealed ledger.

Property keys are read from the `:PROPERTIES:` drawer **and** bare `:KEY: value`
lines anywhere in the body (drawer wins on conflict), since an agent may write either.

## Lifecycle state machine (the orchestrator's true workflow)

A deterministic state machine in native Org, executed one transition per keeper
tick (separate from the never-completing task DAG). Activated by
`WB_LIFECYCLE_DEF`. Headings are **states**; the `:PROPERTIES:` drawer carries
edges and gates:

- `#+START:` — the start state (else the first heading).
- `:KIND:` — `wake` (run the agent def) | `rem` (dream instead). Default `wake`.
- `:REPEAT:` — hold N successful ticks in this state before taking `:NEXT:`
  (default 1).
- `:NEXT:` — the edge once `:REPEAT:` is satisfied.
- `:MIN-INTERVAL:` (or `:MIN_INTERVAL:`) — a time gate: `45m` / `2h` / `90s` /
  bare ms. Until that long has passed since the state last ran, the tick is a
  no-op and position is held.
- `:INTERVAL-MS:` — an explicit interval override (ms).

**Failure semantics:** `:done` increments hits (and advances at `:REPEAT:`);
`:failed`/`:killed` hold the SAME state and retry next tick, so cadence is never
lost. Position `{state, hits}` persists on the data volume and survives
restarts/redeploys. A canonical example: `wake_add ×3 → wake_audit → rem → loop`.

## Dream journal (REM entries, agent-written)

The dreaming process writes one Org entry per cycle into `rem/` in the tenant
repo. Each entry MUST contain exactly these top-level headings, in order:
`* tale` · `* goals` · `* blue sky` · `* fears` · `* verdicts` · `* carry`.
`* verdicts` lines are applied mechanically to `plan.org` (`pick up` → NEXT,
`put down` → TODO, `cancel` → CANCELLED); `* carry` is the resume-state handoff
to the next waking run. Malformed entries (missing headings) are discarded.

## Toolkit manifest (`:toolkit:` node)

A toolkit directory's `manifest.org` carries a `:toolkit:`-tagged front-door node
plus build keywords:

- `#+TAGLINE:` — the one-line description shown by `wbx toolkit list`.
- `CLI_BIN` / `CLI_*` — the command the toolkit wraps.
- `#+EXEC:` — the exec shape: `command` | `posix` | `task` | `federation` |
  `kernel` (and `component`).
- `#+BUILD_SRC:` — `crate:<name>` | `git+<url>` | `path:<dir>` | `wasm:<url>` |
  `archive:<url>`. (`git+` is **not yet implemented** by `wbx toolkit build` — use
  `crate:`/`path:`.)
- `#+BUILD_LANG:` — `rust` | `go` | `js` | `py` | `c` | `zig` | `ts`.
- `#+TRUST:` — e.g. `first-party`.
- `skills/*.org` — the recipes, read on demand. A skill may carry `:role pre`
  (verify-time setup), `:role task` (run-time, invoked by `wbx toolkit run`), and
  `:role eval` blocks; `evals/*.org` cases use `:role eval` + `#+EXPECT:` (Tier
  1) or a `:TASK:` LLM judge (Tier 2). `#+CAPTION` lines form a skill's TOC.

## Deployment / publish configs

`deployment.org` (`:deployment:` node) and `publish.org` (`:publish:` node) are
described in `cli/deploy.md` and `cli/workbook.md`. Both follow the same
declarative shape: a tagged node with a `:PROPERTIES:` drawer; secrets live in
ENV, never the file.
