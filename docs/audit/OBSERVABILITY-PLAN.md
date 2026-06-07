# Observability Adoption Plan — Workbooks Engine

**Goal: stop guessing what agent runs are doing.** Researched live (June 2026), then
corrected against the actual codebase (`runtime/engine`, `WorkbooksRuntime.*`).

## Recommendation

| Layer | Choice | Why |
|---|---|---|
| **Backbone** | **OpenTelemetry** (already in tree: `opentelemetry`, `opentelemetry_exporter`) | Polyglot stack (Elixir engine + TS worker + agent bash); backend-agnostic via `OTEL_EXPORTER_OTLP_ENDPOINT`. |
| **Agent-run UI** | **Langfuse** (self-host, MIT, Docker) | Native OTLP ingest at `/api/public/otel`; reads `gen_ai.*` + `session.id`; trace tree + sessions + cost/token rollups + evals. ~27k stars, lowest-risk. |
| **UI backup** | **Arize Phoenix** (ELv2) | Better built-in LLM-as-judge evals + Agent Graph view; OTLP HTTP+gRPC. Pick if evals/path-viz lead. |
| **Metrics** | keep `telemetry_metrics_prometheus_core` (already wired) | rates / latency / error counts. |
| **System of record** | **keep the org `:LOGBOOK:` / JSONL session-trace** | durable, git-native, replayable. OTel is the *lens*, not the store. Do NOT migrate the trace into OTel. |

## Ground-truth corrections (verified in code)

1. **The OTel bridge is ALREADY started** — `application.ex` → `Workbench` supervises `Otel.Bridge` + Prometheus + Stdout exporters. Phase 1 is "point it at a UI + fix 3 bugs," not from-scratch wiring.
2. **The spawn tree will NOT form automatically (load-bearing fix).** The bridge stores span ctx in `Process.put`; sub-agents are separate BEAM processes and OTel ctx does not cross process boundaries. `sub_agent.spawned` carries `parent_session_id`/`child_session_id` but no span link. → add explicit OTel span **links** across the spawn boundary.
3. **LLM attrs are `llm.model`/`llm.tokens.in`, not `gen_ai.*`** (zero `gen_ai` hits) → remap to the GenAI semconv Langfuse/Phoenix key off.
4. `llm.turn.*` events lack `session_id` → add it for correlation.

## Phased plan

- **Phase 1 (highest leverage, low effort):** point the OTLP exporter at a self-hosted Langfuse; add the spawn-boundary span links; remap LLM spans to `gen_ai.*`; stamp `session_id`. → a real agent-run UI: spawn tree, search, cost/token, latency — replacing hand-reading with `wb-trace.py`.
- **Phase 2:** propagate `traceparent` from the engine into the TS worker (OTel JS / OpenLLMetry) and wrap agent bash steps → one unified trace across engine + worker + tools.
- **Phase 3:** turn on evals (Langfuse scores or Phoenix LLM-as-judge) on real runs.

## Failure-modes-as-org (the harness idea) — feasible, half-built

The harness already has the primitives: a `Validator` trait + `ValidatorRegistry`
(`substrates/oql/crates/oql-validators`), org declares `:validator:` headlines with
`:KIND:`/`:ARG_CMD:`, and **trace-reading detectors already exist**
(`projects/wavelet/src/plan/validators/trace.rs` reads a `.jsonl` trace → `{reason, hint}`).
Missing = the *binding* for the **failure** direction.

Design: a first-class `:failmode:` headline (or `* Failure modes` block) declaring
`{symptom, detector (cmd/regex/trace-check), recovery-hint}`, watched during a run via the
session trace + the done-check. Turns "fumbled 20 turns" → "FAILURE: vision-batch-schema →
run `creative analyze --file`". Seed it with this session's real failures: vision-batch,
citation-anchors (property-vs-tag), legacy-book, pre-read-barrier. Complements OTel — declared
failure modes become labeled spans/alerts.

## Don't

- Don't adopt two UIs. Don't migrate the session-trace into OTel. Don't add a vendor SDK when raw OTLP suffices.
