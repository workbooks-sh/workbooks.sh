# archive/

Code moved out of the compile path (`elixirc_paths: ["lib"]`) but kept for salvage.

## constellation/ — experimental local two-brain inference lane (archived 2026-07-05)

`Nexus.Constellation` was an opt-in, off-by-default experiment: two local model
lanes shaped by machine resources (a parallel CPU autoregressive lane + a
serialized GPU diffusion lane), scheduled from nexus. It never joined a live
path — no callers, no tests, `enabled?` defaulted to `false`, and the app
supervisor's `ether` children were empty in every real deploy.

**Superseded by** the autopoet-specific `Autopoet.Micro` decision limb, which is
narrower (one local model, procedural tool-decisions only) and rides the existing
`Nexus.Llm` money boundary instead of a bespoke scheduler.

**Worth salvaging:** `constellation/lane.ex` — a clean, generic bounded-concurrency
work queue (`GenServer` parameterized by `slots`) in front of a local model
endpoint. If `Autopoet.Micro` ever needs to bound concurrent substrate callers
hitting the 1B, lift `Lane` back into `lib/` rather than rewriting it. `tier.ex`
(machine→model/quant tables) and `router.ex` (prompt→lane classification) are the
experimental parts and can stay archived.

To restore: `git mv archive/constellation lib/constellation` + re-add the
`application.ex` opt-in gate.
