# In-flight background agents (update on launch + completion)

Kill a runaway with `TaskStop <agentId>`. On resume, re-launch any that `failed` without a verdict.

| agentId | mission | checkpoint | status |
|---|---|---|---|
| ae30a823064dd86fd | rayon on the threads lane | n/a | DONE — proven, blocked on codegen_c.cpp futex patch |
| ab497938c906e0ad7 | DuckDB-v2 split-amalgamation, measured verdict | (no checkpoint — pre-protocol launch) | running |
| a6504755b492925be | mrustc codegen patch (rayon futex + SIMD intrinsics) | forge-runs/mrustc-codegen-patch.md | running |

_Note: these two launched before the checkpoint convention; if the process crashes again they restart from
scratch. Future launches must include checkpoint-to-forge-runs instructions + resource-bounded builds._
