# Keeper lifecycle — the agent's true workflow (wb-2ku.3)

Start state: `wake_add`

The orchestrator agent's LIFECYCLE state machine. Headings are STATES;
properties are the deterministic edges and gates. The runtime
(`Workbooks.Lifecycle`) executes one transition per keeper tick. The
non-deterministic interior of each state (what the agent actually does) is the
agent def's job — this file owns only the deterministic skeleton: the order of
states, how many ticks each holds, time gates, and the failure rule.

Properties honored per state:

- `KIND` — `wake` | `rem`. wake runs the agent def; rem dreams (no agent).
- `REPEAT` — N. Hold this state for N consecutive successful ticks before
  taking `NEXT` (default 1).
- `NEXT` — `<state>`. The edge taken once `REPEAT` is satisfied.
- `MIN-INTERVAL` — `<dur>`. Time gate: don't ENTER work until this long has
  passed since this state last ran (e.g. 45m, 2h, 90s). A gated tick is a
  no-op; position holds.
- `INTERVAL-MS` — N. Optional per-state keeper tick override (advisory).

Failure rule (global, not declared per state): a killed / failed run does NOT
advance position — the same state is retried on the next tick, so the cadence
(e.g. "3 adds then audit") is preserved across crashes and timeouts.

## wake_add

- KIND: wake
- REPEAT: 3
- NEXT: wake_audit

Add work: read the dream + plan, do one unit of waking work, commit. Three
consecutive successful add-ticks accrue before an audit is due.

## wake_audit

- KIND: wake
- NEXT: rem

Audit: critique the recent adds against the plan and the page; correct drift.

## rem

- KIND: rem
- NEXT: wake_plan
- MIN-INTERVAL: 10m

Dream: consolidate the cycle's telemetry into a rem/ entry. Time-gated so we
dream at most once per ~audit cycle; then the loop returns to adding.

## wake_plan

- KIND: wake
- NEXT: wake_add
