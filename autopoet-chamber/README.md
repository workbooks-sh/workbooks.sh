# Autopoet Chamber

An isolated spike chamber for **Autopoiesis v3** — giving the existing autopoet
(`nexus/lib/autopoet/`, epic wb-a6u3, shipped + live) a *learning system*: real,
proven math for plasticity, attention, and credit assignment, running on the BEAM
with no gradients and no GPU.

The v2 autopoet has an immune system and a constitution (ceiling-in-index, the
human-gated structural triad, leases, eval-in-scratch, typed requests). What it does
not have is a nervous system: its brain is a stub (`worker.ex:178` returns `:skip`)
and its "learning" is append-only prose lessons. This chamber validates the three
mechanisms that would close that gap, each in its smallest honest form.

## Spikes

| # | Mechanism | Science | Result (deterministic seeds) |
|---|-----------|---------|------------------------------|
| 1 | Hebbian plasticity on the workspace graph | bounded Hebb + decay + spreading activation | top-3 next-access 0.783 vs 0.757 counts baseline; post-drift 0.748 vs 0.686, recovery 500 vs 622 events |
| 2 | Surprise-gated cognition | decayed-count predictor; escalate-on-miss + install handler (JIT cognition) | quality 1.000 at **1.3%** of always-LLM cost; anomaly attention spikes 4.7x at regime switches, self-quenches |
| 3 | Economic credit assignment | Wilson ZCS (1994) + Grefenstette profit sharing (1988) | 6-mux 0.970; two-layer chain **invents a 1-bit protocol** from outcome-only credit, 0.947 |
| 4 | Integration probe (real parser) | — | `Nexus.Literate.parse/1` node `:refs` feed the Hebbian rule directly; only persistence is missing |

Full numbers, honest failures (strict bucket brigade sat at chance; the fix is in
the file), and the Nexus integration map: **[FINDINGS.md](FINDINGS.md)**.
The consensus plan: **[PLAN.md](PLAN.md)**.

## Run

```sh
./run.sh            # spikes 1–3 (standalone Elixir, ~16s total on a laptop)
cd ../nexus && mix run --no-start ../autopoet-chamber/spikes/04_nexus_probe.exs
```

Everything is deterministic (fixed seeds). Spikes 1–3 have zero dependencies;
spike 4 needs the nexus app compiled.

## Iterating

Each spike is a single `.exs` with the hypothesis, the KPI, and the knobs in a
`Cfg`/head comment. Change one variable, re-run, compare. Add a spike per new
mechanism (predictive coding, reservoir-over-events, selection pressure variants)
rather than growing existing ones.
