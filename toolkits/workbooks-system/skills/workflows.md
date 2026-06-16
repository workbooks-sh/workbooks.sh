# workbooks-system — workflows

# When to use this

Read this when your work is driven by an org board, workflow, or lifecycle
spec — selecting the next task, advancing states, satisfying acceptance
gates. The principle (the org outline IS the spec, and specs are loaded
artifacts that hot-swap) is in `concepts`; this is how you operate from the
task seat.

# The outline is the state machine

A native TODO outline run as a workflow has no custom tags — the outline
itself carries everything:

- *TODO keywords are states.* Default set: =TODO NEXT WAITING DOING STARTED
  BLOCKED= → `DONE CANCELLED CANCELED`. A `#+TODO:` line overrides it.
- *Heading nesting* = sub-workflow (a parent with children is composite) vs.
  unit of work (a leaf you execute from its heading + body).
- *`:ORDERED: t`* on a parent → children run sequentially (a pipeline);
  absent → children are independent / parallel.
- *`:BLOCKER:`* = an explicit edge: wait for that task id before starting.

Property keys are read from the `:PROPERTIES:` drawer AND from bare
`:KEY: value` lines in the body (drawer wins on conflict), and keys are
upcased on parse (`:next:` ≡ `:NEXT:`).

# How task selection works (your seat)

- Already-`DONE` tasks are skipped, so a run is *resumable* — pick up where
  the outline left off, don't redo finished leaves.
- Honor ordering: under `:ORDERED:` take the next undone child in sequence;
  otherwise any unblocked leaf is fair game.
- Respect `:BLOCKER:` edges — a blocked leaf is not ready until its blocker
  is `DONE`.
- A leaf is the work you do from its heading + body. A composite parent is
  not a task; descend into it.

# done-when discipline (the acceptance gate)

A leaf reaches `DONE` only when its validation passes — this is "unit tests
for org mode". The gate can be:

- a `:DONE-WHEN:` shell command that must exit 0, or
- a `#+begin_src sh :check` block in the body.

No check declared → your own completion judgment stands, but be honest: if
the heading implies a verifiable outcome, prove it before marking `DONE`.
Don't mark `DONE` to advance the board; mark `DONE` because the gate passed.

# Boards and verdicts driving selection

A run shares a `scratch/` working-memory dir and writes step telemetry plus
a sealed ledger. When a board/lifecycle process emits *verdicts*, they are
applied mechanically to the plan: `pick up` → `NEXT`, `put down` → `TODO`,
`cancel` → `CANCELLED`. So the right way to influence what runs next is to
move state through the proper keywords/verdicts, not to hand-pick out of
band.

# Component-DAG workflows (the other shape)

When the spec is a `:workflow:`-tagged DAG rather than a TODO outline:
`:component:` children are tasks, `:out`→`:in` header args are edges, nested
`:workflow:` headings are sub-workflows, and a `#+begin_src agent` component
runs an agent loop (its source block is the system prompt, the piped input
is the task). Running executes topologically, piping along edges. To see the
schedule WITHOUT executing: `wb tangle <file.org>` (or =?plan=1=).

# Lifecycle state machines

A deterministic state machine in org, one transition per keeper tick.
Headings are states; the drawer carries `:NEXT:` (the edge), `:REPEAT:`
(hold N successful ticks before advancing), `:MIN-INTERVAL:` / `:INTERVAL-MS:`
(time gates), and `:KIND:` (`wake` = run the agent | `rem` = dream). Failure
semantics: a successful tick advances toward `:REPEAT:`; a failed/killed
tick *holds the same state and retries next tick*, so cadence is never lost.
Position persists across restarts. You don't author these as an in-runtime
task usually — but recognize one so you don't fight its cadence.

# Done-when (for this skill's work)

Board work is done when: you selected a genuinely-ready leaf (ordering +
blockers respected), did the work, the leaf's `:DONE-WHEN:` / `:check` gate
passed, and you moved state through the proper keyword. Leave the outline in
a resumable state for the next run.
