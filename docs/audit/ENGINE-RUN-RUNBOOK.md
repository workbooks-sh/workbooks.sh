# Running a real deck-v2 book on the engine (bn-engine) — WORKS (2026-06-05)

The production CF worker /v1/agent dies on long book builds (PROD-AGENT-RUN-FAILURE.md).
The ENGINE (bn-engine, Fly) runs the real deck-v2 pipeline with a durable trace.
Verified live: a Tecovas strategist run dispatched + harvesting against vendor APIs.

## Runbook (multi-tenant; token minted inside the machine)

    fly ssh console -a bn-engine -C "/bin/sh -lc '
      TOK=\$(/app/bin/workbooks_runtime_container rpc \
        \"WorkbooksRuntime.Api.TenantToken.mint(\\\"bn-engine\\\") |> elem(1) |> IO.puts()\" \
        2>/dev/null | tail -1)
      WD=/tmp/run-\$(date +%s); mkdir -p \"\$WD\"
      curl -sS -X POST http://localhost:4000/api/run \
        -H \"Authorization: Bearer \$TOK\" -H \"Content-Type: application/json\" \
        -d \"{\\\"agent_slug\\\":\\\"brandnana-strategist\\\",\\\"prompt\\\":\\\"Build a brand book for tecovas.com\\\",\\\"workdir\\\":\\\"\$WD\\\"}\"
    '"
    # → {"session_id":"sess-…"}

## Read the trace (the loop's observability, live)

    fly ssh console -a bn-engine -C "/bin/sh -lc '
      TOK=\$(/app/bin/workbooks_runtime_container rpc \
        \"WorkbooksRuntime.Api.TenantToken.mint(\\\"bn-engine\\\") |> elem(1) |> IO.puts()\" 2>/dev/null | tail -1)
      curl -sS http://localhost:4000/api/session/<SID>/trace -H \"Authorization: Bearer \$TOK\"
    '"

## Facts

- Engine: PORT=4000, multi-tenant (organization model), WB_TENANT_TOKEN_KEY set.
- Profile: /opt/profile (current substrates/brandnana/profile), agents brandnana-
  strategist + brand-scout present. brandnana + wb CLIs on PATH.
- First verified run: sess-JduW0sqSdPpdLpoAhnXNnw — strategist read pre-read.org,
  recognised "Stage-1 harvest first", ran `brandnana brand fetch tecovas.com
  --mirror`; turn 8, running, no failmodes. minimax/minimax-m3, ~$0.0018/turn.

## Next: wire this as a first-class path

This is the wb-3uh3 cutover target made real. Productize: a `brandnana book`
verb (or the worker) should POST /api/run to the engine instead of running
executePlan in the CF Worker. run-book.sh should gain an --engine mode.

## CORRECTION: dispatch the BOARD, not the strategist alone

The first run used `POST /api/run {agent_slug:brandnana-strategist}` on an EMPTY
workdir → the strategist hand-harvested Stage-1 itself (39 `--help` probes, an
over-read in its own context). That's off-nominal. The full pipeline is a BOARD:

    POST /api/run-plan  { "board_dir": "<.../substrates/brandnana/boards/brand-book>" , ... }

The brand-book board runs gather-org-data (brand-scout, Stage-1 harvest, acceptance
`wb query "(and (tags point) (not (property STATUS failed)))" harvest-provenance.org`)
→ author-analysis + compose-deck (strategist, Stage-2), each verification-gated.
`AgentController.run_plan` starts a worktree-isolated `WorkbooksRuntime.Board`;
`GET /api/board` / `show_board` polls it. THIS is the production deck-v2 run.
