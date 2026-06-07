# bn-engine is stale — the loop's work isn't live yet (2026-06-05, wb-syjo)

## Finding

The live `bn-engine` was built `2026-06-05T03:37:46Z`; this session's deck-v2 +
observability commits run through ~`06:24Z`. So NONE of the loop's 15 iterations
are in the deployed image. Proven from a real Tecovas run
(sess-JduW0sqSdPpdLpoAhnXNnw): the trace carries provider `prompt_tokens`
(5375→18583 over 40 turns — a real over-read climbing) but **NO
`context_utilization`** — the over-read diagnostic this loop built. In current
`main` the `assistant_turn` broadcast carries `context: context_metrics(...)` and
the trace persists it (session_runner.ex:490,523; session_trace latest_context
reads payload.context), so a redeploy makes it appear. The code is correct; it's
just not shipped.

## The fix is `wb deploy` (not a custom script)

`wb deploy validate deploy-kit/deployments/brandnana.org` fails one coherence
check: `:DATABASE: postgres` needs a DSN. The recipe reads `$WB_DATABASE_DSN`
from the deployer env (deploy.rs:620 — like the S3 creds; not committed to the
file). The DSN is a Fly secret on bn-engine (`WB_DATABASE`), NOT in the local env.

### Unblock (operator — has the DSN)

    export WB_DATABASE_DSN='postgres://…'      # the bn-engine Postgres DSN
    wb deploy update deploy-kit/deployments/brandnana.org

This rebuilds bn-engine from current main (Dockerfile.engine-profile → current
substrates/brandnana/profile + engine code), making live: context_utilization in
the trace, the deck-v2 mapper, `book insight-slides`, the analysis gates
(no-duplicates, quote-provenance), pre-call token estimate, tool-result tokens.

## Then

Re-run a real book on the fresh engine and read the full `wb trace` — the
context-pressure / over-read finally visible on a production run. (The current
stale run also shows the strategist doing Stage-1 harvest itself + 39 `--help`
probes — an off-nominal dispatch; the proper flow harvests via brand-scout first.)

## RESOLVED 2026-06-05 — redeployed, validated

bn-engine is now v92 (built_at 06:37Z), current main. Did it with raw `fly deploy
--strategy immediate` (NOT bluegreen — bn-engine has no healthchecks, so bluegreen
errors "app not in valid state"; filed wb-7to2). No DSN needed: the code redeploy
keeps the live WB_DATABASE secret. VALIDATION: a fresh brand-scout harvest
(sess-xFLnaeT2K_bfmFbo2F6NvA) shows `context_utilization` in the durable trace
(0.0084→0.0127→0.0158) — the over-read diagnostic, absent on the stale image, is
now live. est_input_tokens/result_tokens ride the OTel spans → Langfuse (not the
trace JSON), by design.
