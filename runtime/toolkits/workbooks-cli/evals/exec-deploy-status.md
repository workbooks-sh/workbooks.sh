# workbooks-cli — EXECUTION: actually check deploy status (Tier 2)

## the agent runs deploy status, not from memory

- **TASK:** Is a Workbooks runtime deployed / running right now? Don't guess from memory — actually check it now with your tools, then report the concrete status you observe.
- **RUBRIC:** EXECUTION eval. PASS only if the tool trace shows the agent ACTUALLY RAN a status check (the `wb` tool used, steps >= 1 — `wb deploy status`) and reports the concrete runtime state it got back (e.g. up + the URL, or down / microVM absent). A purely-from-memory answer with no tool call FAILS.
- **EXEC:** true
