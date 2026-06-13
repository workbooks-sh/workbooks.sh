# Crash / process-exit resilience — the backup plan

The machine sometimes crashes and the Claude Code process can exit mid-run; background agents lose their
in-process state when that happens (it already cost us rayon + DuckDB-v2 once). This is the standing plan so
work is never lost and a runaway can always be killed.

## 1. Git is the durable store — commit every win immediately
Every proven/wired capability is committed + pushed the moment it's verified (lane + test + canon). A crash
then loses at most uncommitted *reasoning*, never landed code. Never sit on a green result.

## 2. Heavy/long agents checkpoint to disk
Long agents (builds, sweeps) write an incremental STATUS file to `runtime/.campaign/forge-runs/<name>.md`
at every milestone: what's done, last-known-good state, the verdict-so-far, and the exact next command.
A crash then leaves a *resumable trail*, not nothing. On resume, read the checkpoint and continue from it
rather than restarting. (Agent /tmp build artifacts survive a process crash on the same machine — it's the
agent's reasoning/verdict that's lost, so persist THAT.)

## 3. Resource-bound the killer builds — the "kill it" backstop
Wrap machine-threatening builds (DuckDB-scale C++ compiles, libstd rebuilds) so a runaway can't OOM/crash
the box:
- `timeout <N>m <cmd>` — hard wall-clock cap.
- `ulimit -v <KB>` in the subshell — cap virtual memory so a 25MB-TU codegen blowup dies instead of
  taking the machine down.
- Prefer many moderate TUs (split builds) over one giant TU (the single-25MB-TU DuckDB amalgam is exactly
  what OOMs clang.wasm).
- Run heavy builds with `run_in_background` + poll, never a single blocking call that ties up the budget.

## 4. In-flight registry — know what to resume + what to kill
`runtime/.campaign/forge-runs/IN-FLIGHT.md` lists currently-running background agents (agentId + mission +
checkpoint path). Update it on launch and on completion. On session resume, read it to know what was running;
to kill a runaway use `TaskStop <agentId>`.

## 5. Resume protocol (on session restart)
1. Read `IN-FLIGHT.md` + any `forge-runs/<name>.md` checkpoints.
2. For each agent that `failed` (process exited) without a verdict: re-launch from its checkpoint.
3. `git log`/`git status` to confirm what already landed (don't redo committed work).
