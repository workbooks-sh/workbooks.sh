# Strategist PARALLEL PRE-READ — feasibility, what shipped, follow-ups

Branch: `brandnana-remediation-p0`. Status: implemented (true parallel
sub-agents), with the residual follow-ups below tracked for a later pass.

## Problem

The brandnana strategist (`minimax/minimax-m3`) over-reads: it serially
greps the Stage-1 substrate (`brand.org`, `catalog/products.org`, `ads.org`,
`social/*.org`) for ~40-70 turns before authoring a single `:insight:`. That
bloats its context, pressures compaction, and compaction can wipe the very
facts it was about to cite (and reset cwd). The book gets *worse* the longer
it reads.

## Fix shipped

A **PARALLEL PRE-READ** as STEP 0 of the strategist flow (before
`strategize`): fan out ~5 sub-agents, each given ONE slice + a tight brief to
read it and **write a small report** to
`$WD/analysis/reports/<slice>.org` (key findings + the real `:point:` ids to
cite — a few KB, not a raw dump). A barrier waits for all reports, then the
strategist authors `analysis/*.org` from the **compiled reports only**, not
by re-grepping the raw substrate. Each child burns its own context on the raw
bytes; the strategist's stays clean for reasoning.

### Feasibility finding — agent-triggered spawn IS accessible

- **Trigger:** `wb agent spawn <slug> --prompt "..."` (cli/wb/src/cli.rs
  `AgentCmd::Spawn`) → POSTs `/api/agents/spawn`
  (runtime/engine/.../api/router.ex:74) → `AgentController.spawn_agent/2` →
  `SubAgent.spawn/5` → child runs as a real `SessionRunner` under
  `SubAgent.DynamicSupervisor`.
- The parent session is resolved automatically from `WB_SESSION_ID`, which
  the engine injects into every agent's bash env
  (tool_registry.ex:188-192). So inside the strategist's bash,
  `wb agent spawn brand-scout --prompt ...` "just works" — no `--parent-session`.
- The strategist already declares `:ALLOW_SPAWN: t`, `:SPAWN_DEPTH: 2`,
  `:MAX_CHILDREN: 4`, `:CAN_GRANT: bash wb brandnana`, and has the `wb`
  toolkit — capability gating passes.

### The one gap that blocked it — child workdir (now fixed)

`AgentController.spawn_agent/2` built the `SubAgent.spawn` opts as only
`[prompt:, worktree_repo:, llm_opts:]` — **`:workdir` was never passed.** With
no `worktree_repo` (the fan-out case — children share state, not isolated
worktrees), `SubAgent.build_child_opts` (sub_agent.ex:166) falls back to
`Keyword.get(opts, :workdir)` → `nil` → `SessionRunner` defaults to
`System.tmp_dir!()`. So a spawned child ran in a *throwaway* dir and could
neither read the parent's substrate nor drop a report the parent could read.

**Engine change shipped (minimal, mix-compile + tests green):**

- `SessionRunner.workdir/1` + `handle_call(:get_workdir, ...)` — read a live
  session's workdir (mirrors the existing `agent/1` accessor; safe to call on
  the spawn path, same as `agent/1`, since the parent is between turns inside
  a synchronous bash dispatch when its bash runs `wb agent spawn`).
- `AgentController.spawn_agent/2` — resolve the child's workdir with
  precedence: explicit `workdir` in the request → **else the parent
  session's live workdir** (the fan-out default) → else nil (legacy tmp_dir).
  `worktree_repo` still wins downstream, so isolated children are unaffected.

Net: a spawned child with no `worktree_repo` now inherits the parent's brand
workdir, reads `brand.org`/`ads.org`/etc. directly, and writes its report
into `<workdir>/analysis/reports/`. The file-drop **is** the result-collection
channel.

### Files

- `runtime/engine/lib/workbooks_runtime/session_runner.ex` — `workdir/1` +
  `:get_workdir` handler.
- `runtime/engine/lib/workbooks_runtime/api/agent_controller.ex` —
  `spawn_agent/2` threads the (inherited) workdir into `SubAgent.spawn`.
- `substrates/brandnana/profile/skills/pre-read.org` — NEW skill: the reports
  contract, the spawn brief, the barrier (file-existence poll), the AUTHOR
  step, and a deterministic single-pass FALLBACK.
- `substrates/brandnana/profile/agents/brandnana-strategist.org` — wires the
  pre-read in as STEP 0 (the default first step), adds it to the skill
  playbook list, and rewrites Method step 1.

### Reports contract

Five files under `$WD/analysis/reports/`: `brand.org` (voice/tone/positioning
+ palette), `ads.org` (ad-ideas/copy/hooks + AD_IDs), `catalog.org` (what they
sell + price bands), `social.org` (audience + follower scale + HANDLEs),
`reviews.org` (quoted testimonials). Each is small structured org: one
`:report:` headline, several `:finding:` headlines, every finding carries a
`:GROUNDS:` listing the **real** Stage-1 `:point:` ids it rests on (the exact
anchor forms `write-analysis.org` expects). A finding with no real point is
dropped — no fabrication; `analysis check` would reject it anyway.

## Residual follow-ups (not blocking; the above works today)

1. **No true async barrier primitive.** Collection is **file-existence
   polling** (the barrier loop in `pre-read.org` waits for
   `reports/*.org` to appear, up to ~5 min). This is correct and durable
   (`SubAgent`/`SessionRunner` are async/fire-and-forget — `wb agent spawn`
   returns the child id immediately, not the result). A nicer follow-up: a
   `wb agent await <child_session_id...>` verb that blocks on the
   lifecycle table (`SubAgent.status/2` → `:done`) and/or the `on_complete`
   hook, so the barrier is engine-side instead of a disk poll. Until then the
   disk poll is the contract — it's also more robust to a crashed child (a
   missing report file is visible; a lost callback isn't).

2. **`MAX_CHILDREN: 4` vs 5 slices.** The strategist's cap is 4; the pre-read
   wants 5 concurrent children. `pre-read.org` handles this by spawning in two
   waves (the barrier is wave-agnostic). A trivial follow-up is bumping
   `:MAX_CHILDREN:` to `5` (or `6`) in `brandnana-strategist.org` so all five
   slices fan out in one wave. Left at 4 deliberately for now (conservative;
   the two-wave path is tested by the same barrier).

3. **Shared-workdir concurrency.** Five children writing into one
   non-worktree workdir is safe here because each writes a **distinct** file
   (`reports/<slice>.org`) — there is no write contention. If a future
   pre-read had children touching the same file, it would need either the
   worktree path (`worktree_repo` + `claimed_paths`, already supported by
   `SubAgent.spawn`/`Orchestrator.lease`) or a per-child scratch dir. The
   distinct-file design avoids both.

4. **`wb agent spawn` doesn't forward `--workdir`.** The engine now *inherits*
   the parent workdir when the request omits it, so the CLI doesn't need a
   `--workdir` flag for this use case. If a future caller wants to spawn a
   child into a *different* dir than the parent, add `--workdir` to
   `AgentCmd::Spawn` (cli/wb/src/cli.rs) and forward it in the payload — the
   endpoint already honors an explicit `workdir` param (it takes precedence
   over the inherited one).
