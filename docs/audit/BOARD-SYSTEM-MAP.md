# Workbook Board orchestration — map + 3-agent plan (2026-06-05, wb-syjo)

How the board navigates, generates tasks, dispatches, and gates — and the gaps
to make it the real orchestrator for Scout/Strategist/Designer.

## How it works (engine: board.ex + board/dispatcher.ex + board/acceptance.ex)

- **Navigation / lifecycle (board.ex):** an acyclic task DAG. Each tick: pick
  READY tasks (`Loader.ready_tasks` — a task whose deps are done and isn't
  in_progress), dispatch up to `:concurrency` (default 4), on `{:task_complete,
  id, outcome}` call `Sync.advance_task/3` to advance disk state, repeat.
  Completes `:done` when every task is terminal, `:stalled` if non-terminal
  tasks remain that no longer dispatch (blocked/input_required/review). THAT is
  "moving up/down/around" — it's dependency-ordered ready-task picking, not
  manual navigation.
- **Dispatch seam (board/dispatcher.ex):** per task → resolve its `%AgentDef{}`
  (`:agent_resolver` from `assigned_to`) → synthesize a parent def granting
  exactly the task's capabilities → `SubAgent.spawn/5` in a LEASED WORKTREE →
  on the sub-agent's terminal state run the verifier → ONLY a verified success
  merges the worktree back and reports `:done`; a failed run or failed
  verification reports `{:failed, reason}` and ABANDONS the worktree ("bad work
  never lands"). Same SessionRunner path as /api/run, but worktree-isolated +
  acceptance-gated.
- **Acceptance gates (board/acceptance.ex + task `acceptance[]`):** e.g.
  gather-org-data → `command:wb query "(and (tags point) (not (property STATUS
  failed)))" harvest-provenance.org`; compose-deck → `artifact:book.html` +
  `command:wb unbundle book.html ... && test -f .../brand.org`. Evaluated on
  completion; this is the BOARD's gate (distinct from the agent's own DONE_CHECK).
- **Task schema (tasks/*.json):** id, state, assigned_to[], capabilities[],
  acceptance[] (+ deps). STATIC hand-authored JSON.

## The gaps (why the board isn't the orchestrator yet)

1. **NOT DEPLOYED.** Dockerfile.engine-profile:173 copies only
   `substrates/brandnana/profile` → /opt/profile. `substrates/brandnana/boards/`
   is NOT baked, so `/api/run-plan {board_dir}` has no brand-book board on
   bn-engine. → the board can't run in prod today.
2. **NOT USED.** Nothing in prod calls `/api/run-plan` (zero hits in the worker
   or skills). Prod = /v1/agent (CF worker) or ad-hoc /api/run single-agent. The
   board engine is built but dormant for brandnana.
3. **STATIC task-gen only.** Tasks are hand-authored JSON; dynamic per-page board
   growth (editor authors N page-tasks from data) is unbuilt (BRANDBOOK-STATUS
   §3.4.3).
4. **2 agents, not 3.** agents.json = brand-scout + brandnana-strategist;
   compose-deck.json assigned_to = brandnana-strategist (strategist does BOTH
   analysis AND deck). USER wants Scout / Strategist / Designer.

## Plan: make the board the orchestrator with 3 agents

1. **Designer agent** — new `profile/agents/designer.org` owning the DECK
   (compose-deck + publish-workbook + make-image + visual-review); Strategist
   narrows to analysis (pre-read + write-analysis + gate), hands off after
   `analysis check` PASS. Scout unchanged (harvest).
2. **agents.json** += designer; **compose-deck.json** assigned_to → designer.
3. **Bake boards/** into Dockerfile.engine-profile (COPY substrates/brandnana/
   boards) so /api/run-plan finds it. (Confirm Board writes to a workdir, not
   board_dir, so the baked def can be read-only.)
4. **Dispatch via /api/run-plan** {board_dir: brand-book} instead of ad-hoc
   /api/run — the board orchestrates Scout→Strategist→Designer with worktree
   isolation + acceptance gates.
