# Toolkit eval suites — ship a toolkit with its own evaluations

Date: 2026-06-09
Related: AUTHORING.md (the skill/manifest standard), ../runtime/docs/TOOLKITS-V3.md

## Why
A toolkit already ships **skills** (how to use it) and, for command/posix kinds,
a **CLI**. An **eval suite** is the third leg: the author's own evaluations,
bundled IN the toolkit, so

- the AUTHOR proves the toolkit does what the skills claim, and
- a CONSUMER can run those evals against their own runtime/data to validate it
  before trusting it (or extend them).

It is the behavioral complement to `work kit verify`: **verify** asks "does it
load / is the contract satisfiable" (structural + `:role pre`); **eval** asks
"does it DO the right thing." Both run under the same default-deny sandbox.

## Location & shape
One case per file under `toolkits/<name>/evals/*`. A case is an
`eval`-tagged node + a header declaring the expectation. Two tiers; an
author ships whichever fits (a toolkit may ship both).

### Tier 1 — deterministic (BUILT: `work kit eval <id>`)
A `:role eval` bash block + an `EXPECT:` substring. The block runs under
`Workbooks.Sandbox` (network-denied, fs-confined, wall-clock-capped) — the
SAME executor as verify's `:role pre` — and ONLY when `WB_TOOLKIT_EXEC=1`.
PASS = exit 0 AND stdout contains `EXPECT:` (when set).

```
Title: git toolkit — version sanity
EXPECT: git version

Case (eval): "git is on PATH and reports a version"
  bash :role eval
    git --version
```

### Tier 2 — agent + judge (BUILT, telemetry-scored)
For "does an AGENT use this toolkit correctly." A case is Tier 2 when it
declares a `TASK` property. The harness runs an agent on the TASK (the
toolkit's `overview` skill is injected so it knows the surface), then a judge
model scores the agent's RESULT + its tool trace against the `RUBRIC`. This
is the "evaluate against the original author's evaluations" path.

```
Case (eval): "the agent explains what git status shows"
  TASK:      In one sentence, explain what `git status` shows.
  RUBRIC:    Names the working-tree state — staged vs unstaged + untracked.
  EXEC:      false      # true ⇒ grant the real-CLI tool (needs WB_TOOLKIT_EXEC)
  MAX_STEPS: 2          # optional; agent step cap (default 6)
  SYSTEM:    ...        # optional; overrides the default system prompt
```

Models: the agent + judge default to `xiaomi/mimo-v2.5` (override the agent
with `WB_EVAL_MODEL`, both with `WB_LLM_MODEL`). Needs an LLM key
(`OPENROUTER_API_KEY`); `EXEC: true` additionally needs `WB_TOOLKIT_EXEC=1`.
The judge's verdict is its first line (`PASS`/`FAIL`) + one line of reasoning.

## Running
- `work kit eval <id>`      — run a toolkit's eval suite (Tier 1 + Tier 2).
- `work dev eval [toolkit]`     — dev-service entry: list eval suites / run them.
- Gating: Tier-1 bash runs only with `WB_TOOLKIT_EXEC=1` (else reported SKIPPED,
  like verify). Tier-2 needs a runtime + an LLM key.

## Authoring checklist
- [ ] `evals/` holds one `eval` case per file; Tier-1 cases carry `EXPECT:`
      + exactly one `:role eval` block.
- [ ] Deterministic cases are hermetic (no network; the sandbox denies it).
- [ ] Tier-2 cases carry `TASK` + `RUBRIC` and name the toolkit verbs the
      agent should reach for.
- [ ] `work kit eval <id>` passes locally (with `WB_TOOLKIT_EXEC=1`).

## See also
- AUTHORING.md — the manifest + skill standard (verify, :role pre/post).
- ../runtime/docs/TOOLKITS-V3.md — EXEC modes + the trust boundary.
