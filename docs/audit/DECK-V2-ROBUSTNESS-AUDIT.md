# Deck-v2 pipeline robustness audit (2026-06-05, wb-syjo)

Workflow wf_52873066 — 5 parallel find-agents + per-finding adversarial verify (36 agents, 2.1M tokens). **28 of 31 candidates CONFIRMED real.**

ROOT THEME: no client-side request timeout in the SDK/CLI, AND cut bash orphans the OS child — so every slow op relies on the engine bash timeout (300s), which cuts it, leaving server work orphaned -> retry/partial. Catalog crawl was the first instance.

STATUS: SDK client timeouts + waitForCrawl deadline/partial-data FIXED (commit 707d009fd). Remaining tracked below.

## HIGH (3)

### Cut bash leaves the OS child process (the brandnana CLI + its in-flight API call) orphaned and still running — the exact server-side-crawl class, now at the BEAM/OS boundary
- **surface:** runtime/engine/lib/workbooks_runtime/tool_registry.ex:174; runtime/engine/lib/workbooks_runtime/vm_host/backend/process.ex:34; runtime/engine/lib/workbooks_runtime/hooks/exec/bash.ex:29  
- **class:** bash-timeout-cut | **dimension:** bash-timeout  
- **fix:** Capture the OS pid and kill the process group on timeout. Spawn through a wrapper that exec's into a new session (`setsid bash -c …` or `System.cmd("bash", ["-c", "exec setsid …"])`) or use `Port.open({:spawn_executable, …})` and on timeout `:os.cmd('kill -TERM -<pgid>')`. At minimum, document and standardize the kill in one shared helper so process/inline/hooks paths share it, instead of three copies that all only brutal_kill the Task.  
- **verified:** VERIFIED REAL. Every cited fact holds against the actual code, and I empirically confirmed the load-bearing claim.

1. The three cited paths are real and identical. All three run the command via `Task.async(fn -> System.cmd("bash"/bin, ...) end)` then `Task.yield(task, timeout) || Task.shutdown(task

### deck-gate.sh DONE_CHECK can exceed the 120s done-check ceiling (render-slides has no client timeout), and each timeout is a COUNTED fail that burns DONE_CHECK_MAX even on a perfect deck
- **surface:** substrates/brandnana/profile/skills/deck-gate.sh:74,113,130 + projects/brandnana/apps/cli/src/commands/book.ts:247-255 + runtime/engine/lib/workbooks_runtime/session_runner.ex:423,648,661-664  
- **class:** bash-timeout-cut | **dimension:** agent-skills  
- **fix:** Add `--max-time` to the render-slides path (and an AbortController in book.ts fetchRenderSlides), and either raise WB_DONE_CHECK_TIMEOUT_MS for this agent or split the gate so the expensive render/analysis run during compose (TIER-2), leaving DONE_CHECK to fast deterministic grep/curl only. Distinguish a transport timeout from a structural fail so a cut doesn't consume the DONE_CHECK_MAX budget.  
- **verified:** VERIFIED REAL — every load-bearing cited line holds up against the actual code.

deck-gate.sh (substrates/brandnana/profile/skills/deck-gate.sh): line 74 is `HTML="$(curl -fsSL --max-time 45 "$DECK_URL" ...)"`; line 113 is `SLIDES_JSON="$(brandnana book render-slides "$DECK_URL" --json ...)"`; line 

### 409-wait path leaves local SQLite with the PARTIAL (pre-timeout) catalog; substrate build/check render+validate that partial and pass
- **surface:** projects/brandnana/apps/cli/src/commands/catalog.ts:196-218 (wait path) + substrate.ts:1057-1078 (build reads local SQLite) + substrate-check.ts:187-203 (count check)  
- **class:** partial-data | **dimension:** substrate-chain  
- **fix:** On the wait path, do not trust the silent local partial. After waitForCrawl returns finished, either (a) re-stream the finished crawl into local SQLite (implement the promised --force/resync that actually pulls rows), or (b) record the server total (waited.products) into a crawl-completeness marker (e.g. catalog/crawl.json {products, source:'server'} or a sync_runs.expected_count column) and have substrate-check.checkProductCount compare dbCount against that server total, failing loud when dbCou  
- **verified:** VERIFIED REAL. Every load-bearing claim in the finding checks out against the actual code.

1. waitForCrawl writes nothing to local SQLite — CONFIRMED. catalog.ts:237-253 only polls GET /catalog/status and returns the server status; it issues no insertProduct/insertImage. The only local writes are i

## MEDIUM (16)

### SDK call()/stream() set NO request timeout or AbortSignal — every harvest verb relies on the bash timeout, and any slow upstream (not just catalog crawl) gets cut mid-flight
- **surface:** projects/brandnana/packages/sdk/src/index.ts:918-945 (call), 947-988 (stream)  
- **class:** bash-timeout-cut | **dimension:** harvest-verbs  
- **fix:** Add a default per-request timeout in the SDK transport: thread an `AbortSignal.timeout(ms)` (configurable via BrandnanaClientOptions, default ~60-120s) into both `call()` and `stream()` RequestInit, so a hung upstream surfaces as a BrandnanaError that propagates to runAction→emitError (exit 1) instead of being silently truncated by the outer bash timeout. Keep it BELOW the agent's TIMEOUT_MS so the CLI, not bash, owns the deadline.  
- **verified:** VERIFIED REAL against actual code. All cited evidence holds:

1. SDK transport has no timeout/AbortSignal. In `call()` (index.ts:918-945) the RequestInit is `{ method, headers }` + optional body (920-926) — no `signal`. Same in `stream()` (init at 951-957). Constructor binds `globalThis.fetch` with 

### `ads sync` (Meta) is a multi-account loop with no resume — a bash timeout mid-loop leaves some accounts synced, some not, and re-running re-fetches everything from account #1
- **surface:** projects/brandnana/apps/cli/src/commands/ads.ts:245-257  
- **class:** partial-data | **dimension:** harvest-verbs  
- **fix:** Checkpoint per account: write each account's ads + a 'last synced' marker as soon as its fetch returns (already does upsert per acct), and make the loop skip accounts whose marker is fresh on re-run, or accept `--ad-account-id` resume + emit which accounts remain. Pair with the SDK timeout so a single slow account fails loud instead of dragging the whole loop past the bash deadline.  
- **verified:** Verified against the actual code; every citation holds.

CITATIONS ACCURATE:
- ads.ts:247-253 — `for (const acct of accounts) { ... await client.ads.meta.fetch(acct.id, limit); upsertAds(db, result.ads, ...); totalAds += ...; }` matches verbatim.
- ads.ts:246 — the whole loop is wrapped in a single 

### `catalog crawl` 409-wait branch tells the agent to 're-run with --force', but `catalog crawl` has no --force flag — the server-side products are never synced to local SQLite (partial data + dead-end guidance)
- **surface:** projects/brandnana/apps/cli/src/commands/catalog.ts:208-212 (message) vs 77-86 (option list)  
- **class:** partial-data | **dimension:** harvest-verbs  
- **fix:** Either add a real `--force` (or `--resync`) that, after the wait, pulls the finished crawl's rows from the server into local SQLite, OR change the wait branch to fetch and insert the completed crawl's products/images itself before emit() so the success actually reflects local state. Until then, drop the false '--force' instruction from the message.  
- **verified:** Verified every checkable claim against the actual code; the finding holds up.

1. The `--force` claim is exactly right. `grep -i force` over catalog.ts returns only two hits: line 43 (an unrelated biome `// ...would force a circular import` comment) and line 211 (the wait-branch message). The `catal

### Timed-out bash surfaces to the agent as opaque `ERROR: {:timeout, 300000}` with no signal that the work may still be running server-side — the spin enabler
- **surface:** runtime/engine/lib/workbooks_runtime/tool_registry.ex:163,177; runtime/engine/lib/workbooks_runtime/session_runner.ex:1279  
- **class:** silent-error | **dimension:** bash-timeout  
- **fix:** Preserve the helpful message and make timeout self-describing to the model: return e.g. `{:ok, "exit -1\nTIMED OUT after #{ms}ms — the command was killed but any server-side work it started (async crawl/sync) may STILL be running. Do NOT blindly re-run; poll status or use a wait verb."}`. Carry process backend's stdout through vm_result_to_dispatch instead of dropping it.  
- **verified:** VERIFIED — every cited line holds up against the actual code.

Surface claims confirmed:
- tool_registry.ex:163 — `defp vm_result_to_dispatch(%{status: :timeout}, timeout), do: {:error, {:timeout, timeout}}`. Verbatim. The function head pattern-matches ONLY `%{status: :timeout}` and binds neither `s

### waitForCrawl polls up to 10 min but the agent bash timeout is 5 min — the fix can outlive its own bash budget and get cut mid-wait, re-arming the spin
- **surface:** projects/brandnana/apps/cli/src/commands/catalog.ts:241; runtime/engine/lib/workbooks_runtime/tool_registry.ex:54  
- **class:** bash-timeout-cut | **dimension:** bash-timeout  
- **fix:** Make waitForCrawl's deadline fit inside the bash budget (read an env like WB_BASH_TIMEOUT_MS or a CLI `--wait-timeout`, default ≤ 4 min), OR have the verb exit early with a distinct 'still running, poll again' code so the agent's NEXT short bash resumes the poll instead of one long blocking wait. Pin the relationship in a comment so the two timeouts can't drift apart.  
- **verified:** VERIFIED against actual code. The timeout-mismatch is real.

EVIDENCE CONFIRMED:
- projects/brandnana/apps/cli/src/commands/catalog.ts:241 — `const deadline = Date.now() + 10 * 60 * 1000; // 10 min`, polling every 5s (line 250), entered on 409 crawl_in_progress (line 203). Exact as cited.
- runtime/

### SDK call()/stream() have no request timeout or AbortController — a stalled api.brandnana.net stream hangs until the agent's bash timeout cuts it, generalizing the spin to every harvest verb
- **surface:** projects/brandnana/packages/sdk/src/index.ts:918-988  
- **class:** async-no-wait | **dimension:** bash-timeout  
- **fix:** Add an AbortController with a finite per-request timeout (and an inter-chunk watchdog for stream()) in the SDK, surfacing a typed timeout error so the CLI can exit with a distinct, actionable code rather than hanging until the harness kills it. Mirror the engine's own LLM client which added a finite receive_timeout for exactly this hang (llm.ex:411-418).  
- **verified:** VERIFIED — the finding holds against the actual code on every load-bearing claim.

Core claim (SDK has no client-side timeout/abort):
- `call<T>` at projects/brandnana/packages/sdk/src/index.ts:918-945 does `const res = await this.fetchFn(url, init)` (line 927) with `init` containing only method/hea

### No per-agent or per-harvest-step bash timeout — a 1358-product `catalog crawl --mirror` realistically exceeds the global 5-min default, and AgentDef has no timeout field
- **surface:** runtime/engine/lib/workbooks_runtime/tool_registry.ex:54-71; runtime/engine/lib/workbooks_runtime/agent_def.ex:109-112; projects/brandnana/apps/cli/src/commands/catalog.ts:40,191-195  
- **class:** bash-timeout-cut | **dimension:** bash-timeout  
- **fix:** Add an optional per-step timeout: either a `:DEFAULT_BASH_TIMEOUT_MS:` property on AgentDef (used as the dispatch default when the agent omits timeout_ms), or have the harvest-sweep skill explicitly pass a longer `timeout_ms` for catalog crawl. Bump the global default toward the catalog reality (or document that --mirror crawls MUST set a larger timeout) so the first honest crawl isn't structurally guaranteed to be cut.  
- **verified:** VERIFIED — every load-bearing claim holds against the actual code.

(1) Global-only timeout, no per-agent/per-verb default. tool_registry.ex:54 `@default_timeout_ms 300_000`; env-tunable only via WB_BASH_TIMEOUT_MS (lines 60-71). dispatch reads `Map.get(args, "timeout_ms") || bash_default_timeout()`

### deck-gate.sh runs book render-slides on EVERY DONE loop under the 120s done-check ceiling — the gate itself can be cut mid-render and counted as a failed check toward done_check_max
- **surface:** substrates/brandnana/profile/skills/deck-gate.sh:113 + runtime/engine/.../session_runner.ex:423 (@default_done_check_timeout_ms 120_000) / :609 (done_check_max)  
- **class:** bash-timeout-cut | **dimension:** strategist-stage2  
- **fix:** Have deck-gate.sh render a bounded sample (or pass --max-slides small) for the structural count check rather than the whole deck on every loop, OR raise/separate the done-check ceiling for this gate, OR move render-slides out of the per-loop TIER-1 gate (the header already calls render a TIER-1 step but it is the one model-free-but-slow operation). Bound the gate's own wall-clock so render time can't masquerade as a structural failure.  
- **verified:** VERIFIED REAL. Every cited file:line holds up against the actual code.

deck-gate.sh IS the strategist's `:DONE_CHECK:` (substrates/brandnana/profile/agents/brandnana-strategist.org:16 → `command:bash /opt/profile/skills/deck-gate.sh .`, DONE_CHECK_MAX:6 at :17). On EVERY DONE attempt the script run

### A deck with >60 slides can NEVER pass deck-gate.sh: the gate calls render-slides with no --max-slides, server caps at 60, reports truncated:true, gate fails forever
- **surface:** substrates/brandnana/profile/skills/deck-gate.sh:113,124-126 + api/src/book/render-slides.ts:43 (MAX_SLIDES_CAP=60) / browser.ts:185 (DEFAULT_MAX_SLIDES=60)  
- **class:** retry-spin | **dimension:** strategist-stage2  
- **fix:** Pass `--max-slides 200` (the server clamp ceiling, render-slides.ts:99-102 clamps [1,200]) in deck-gate.sh:113 so the gate reviews every slide it can, and treat truncated:true only when total exceeds the hard clamp. Keep the cap consistent between the gate, compose-deck.org guidance, and the server default.  
- **verified:** VERIFIED REAL — every cited fact holds against the actual code, and the mechanism is a genuine retry-spin of the same class as the original bug.

Evidence confirmed:
- /Users/shinyobjectz/Apps/workbooks/substrates/brandnana/profile/skills/deck-gate.sh:113 calls `brandnana book render-slides "$DECK_U

### make-image OpenRouter image-gen and asset-upload curls have no timeout and a silent-drop fallback — a slow/hung gen blocks the bash slot and a swallowed failure ships a deck with a missing image
- **surface:** substrates/brandnana/profile/skills/make-image.org:57-98,127-147  
- **class:** silent-error | **dimension:** strategist-stage2  
- **fix:** Add `--max-time` to both curls so a hung gen/upload is bounded instead of consuming the bash slot. Check the response shape (jq // empty + a non-empty PNG size assert) before upload so an error body isn't silently shipped as a broken image. The fail path already notes gaps — make that a structured/queryable signal the gate can verify rather than relying on prose.  
- **verified:** Verified every concrete claim against the actual code; all hold up.

TIMEOUT CLAIM (TRUE): substrates/brandnana/profile/skills/make-image.org:57 `curl -s https://openrouter.ai/api/v1/chat/completions` and :89 `curl -s -X POST "https://api.brandnana.net/v1/asset/upload"` both use plain `curl -s` with

### creative analyze (the per-slide vision gate) has no client timeout and returns fail-soft analyses with an `error` field that the gate/agent can silently pass over
- **surface:** projects/brandnana/apps/cli/src/commands/creative.ts:139 (analyzeViaServer fetch) + creative-vision.ts:146,151,184-189 (normalize-with-error fail-soft)  
- **class:** partial-data | **dimension:** strategist-stage2  
- **fix:** Add a bounded timeout to analyzeViaServer fetch. Make `--json` consumers (the compose-deck loop and any gate) treat a present `analysis.error` (or empty summary+hook) as a NOT-REVIEWED slide, not a pass. Surface a non-zero/distinct exit or a count of errored analyses so a partially-vision-reviewed deck cannot quietly satisfy the acceptance criterion.  
- **verified:** Verified against the actual code; every cited line holds and the mechanism is real on the DEFAULT agent path, not just the --local mirror.

TIMEOUT GAP (confirmed): analyzeViaServer's fetch at projects/brandnana/apps/cli/src/commands/creative.ts:139 has NO AbortController/signal/timeout — grep for A

### Strategist pre-read barrier discards child ids, so a brand-scout child that crashes before writing its report stalls the agent for the full 300s timeout
- **surface:** substrates/brandnana/profile/agents/brandnana-strategist.org:92-95 (DEFAULT FLOW) + substrates/brandnana/profile/skills/pre-read.org:131-174  
- **class:** async-no-wait | **dimension:** agent-skills  
- **fix:** Make the DEFAULT spawn capture each child_session_id and pass them to `wb agent wait` alongside `--for-files`, so a child reaching completed/failed/cancelled (or 404) lifts the barrier immediately (cli.rs:2161-2176) instead of waiting out the timeout. Promote pre-read.org:191-199 from 'optional' to the canonical flow; demote the file-only form to the fallback.  
- **verified:** VERIFIED against the actual code — the mechanism is real and every load-bearing citation holds.

Default flow discards child ids: strategist.org:94 and pre-read.org:131-135 spawn with `>/dev/null`; the canonical barrier (pre-read.org:168-174) is file-glob-only with `--all`. The id-capturing form is 

### Pre-read barrier timeout (300s) equals the engine bash tool timeout (300s), so the barrier can be cut by the bash ceiling before it emits its own clean 'which slices are missing' message
- **surface:** substrates/brandnana/profile/skills/pre-read.org:174 vs runtime/engine/lib/workbooks_runtime/tool_registry.ex:54  
- **class:** bash-timeout-cut | **dimension:** agent-skills  
- **fix:** Set `--timeout-secs 240` (or lower) on the barrier so the CLI's own clean timeout + missing-glob report always wins over the bash kill. General rule: any `wb agent wait` / long blocking call must use a timeout comfortably below WB_BASH_TIMEOUT_MS (300s).  
- **verified:** Every cited fact verified against the actual code:

- cli/wb/src/cli.rs:1061 — `--timeout-secs` is `#[arg(long, default_value_t = 240)]`. Confirmed: default 240. ✓
- substrates/brandnana/profile/skills/pre-read.org:174 (and again :198) — the barrier overrides with `--timeout-secs 300`. ✓
- runtime/e

### resolve stage has no empty-domain guard — an unresolved name leaves $DOMAIN empty and every downstream stage runs against an empty string instead of one clean resolve=failed + stop
- **surface:** substrates/brandnana/profile/skills/harvest-sweep.org:138-143 (+ downstream :164-166, :237)  
- **class:** silent-error | **dimension:** agent-skills  
- **fix:** Add a hard guard right after line 141: `if [ -z "$DOMAIN" ]; then` retry with a higher `--limit`, and if still empty, record resolve STATUS=failed with the candidate dump and ABORT the sweep (or return needs_data) — never let an empty $DOMAIN flow downstream. Consider a brand-scout :failmode: that detects repeated verbs invoked with an empty domain argument.  
- **verified:** Verified against the actual file /Users/shinyobjectz/Apps/workbooks/substrates/brandnana/profile/skills/harvest-sweep.org. The cited lines match exactly:
- :141 `DOMAIN="$(jq -r '.candidates[0].domain // empty' raw/resolve.json)"`
- :142 is genuinely only a COMMENT ("# Verify: a non-empty canonical 

### fm-pre-read-barrier cmd detector misfires (spurious 'don't busy-poll') when the recent trace window has no completed tool_result — test "" -lt 120000 exits 2 = symptom-present
- **surface:** substrates/brandnana/profile/agents/brandnana-strategist.org:369 + runtime/engine/lib/workbooks_runtime/session_runner.ex:796-806  
- **class:** silent-error | **dimension:** agent-skills  
- **fix:** Default the value so empty never reaches test: `... | tail -1)" ; v=${v:-0}; test "$v" -lt 120000` or fold a `// 0` floor with a numeric coercion (e.g. wrap the jq in `(... ) // 0` AND `| add // 0`-style guard, or `printf %d`). Mirror the fm-over-read-corpus guard pattern so the no-tool_result window reads as clear.  
- **verified:** VERIFIED REAL. Every cited fact holds against the actual code, and the behavioral claim is reproduced.

DETECTOR (substrates/brandnana/profile/agents/brandnana-strategist.org:369, mirrored at services/brandnana-agent/profile/Engine/agents/brandnana-strategist.org:95): exact match — `:DETECTOR: cmd`,

### First timeout-cut crawl leaves a partial DB with no consultable completeness signal: sync_runs row stuck ok=0/finished_at=NULL is never read by build or check
- **surface:** projects/brandnana/apps/cli/src/sync-runs.ts:27-31 (inserts ok=0) + catalog.ts:144-189 (crawl inside withSyncRun) + substrate.ts / substrate-check.ts (no sync_runs read)  
- **class:** partial-data | **dimension:** substrate-chain  
- **fix:** Make substrate-check read the latest sync_runs row for kind='catalog': fail the product_count check (or add a 'catalog crawl completed' check) unless the most recent catalog run has ok=1 AND finished_at IS NOT NULL. Fix the wait path so a server-side success marks its sync_run ok=1 with the server total, not ok=0 from the swallowed 409.  
- **verified:** VERIFIED REAL against actual code (finding's path/line cites are off but the substance maps exactly).

Corrected locations: sync-runs.ts:26-29 (insert ok=0), :33-36 (flip ok=1 on resolve), :40-44 (ok=0+error on throw); the catalog crawl wrapped by withSyncRun is at commands/catalog.ts:143-188 (NOT t

## LOW (9)

### withSyncRun leaves an orphaned ok=0 'running' row when bash is cut — partial runs are indistinguishable from genuine failures, defeating the audit trail it exists for
- **surface:** projects/brandnana/apps/cli/src/sync-runs.ts:19-47  
- **class:** partial-data | **dimension:** harvest-verbs  
- **fix:** On CLI startup (or before a new run of the same kind/domain), sweep sync_runs for rows with finished_at IS NULL older than a threshold and mark them error='aborted (process exited before completion)'. This makes the partial-data state legible to the agent and to audit-trace, mirroring how the crawl DO status distinguishes running/finished/failed.  
- **verified:** VERIFIED — real, low-severity. Every claim checks out against the actual code:

1. withSyncRun inserts the row with ok=0 BEFORE running fn: projects/brandnana/apps/cli/src/sync-runs.ts:26-29 (`INSERT INTO sync_runs (...) VALUES (?, ?, ?, ?, ?, 0)`). Confirmed.
2. ok=1 is only written in the try-succ

### `brand fetch --mirror` swallows screenshot-mirror failure with say() before runAction — a failed mirror is invisible in --json/--quiet (the agent path) and the command still exits 0
- **surface:** projects/brandnana/apps/cli/src/commands/brand.ts:74-87  
- **class:** silent-error | **dimension:** harvest-verbs  
- **fix:** Use warn() (stderr, prints in human+quiet, structured-suppressed only in json) instead of say(), or surface the mirror outcome in the emitted payload (e.g. `extras.screenshot_mirrored: false, mirror_error: msg`) so the agent and audit-trace see that the asset is a hotlink, not a green R2 URL. Don't fully swallow it on the json path.  
- **verified:** The core mechanism is REAL and verified against the actual code:

1. brand.ts:84-86 — the screenshot mirror is wrapped in its own try/catch INSIDE the action and on failure calls `say(\`screenshot mirror failed: ${(e as Error).message}\`)`. Confirmed verbatim.
2. output.ts:29-33 — `say()` writes to 

### brandnana CLI collapses every error exit code to 1 — a propagated 409 crawl_in_progress is indistinguishable from any other failure to the agent
- **surface:** projects/brandnana/apps/cli/src/output.ts:55-75  
- **class:** exit-code | **dimension:** bash-timeout  
- **fix:** Exit with the meaningful code: `process.exit(code && code >= 1 ? Math.min(code, 255) : 1)` (or a small mapped table 409→a reserved code). Then the agent / engine can distinguish 'collision, wait' from a hard error without parsing the JSON body.  
- **verified:** The literal code claim is verified and accurate. In /Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/cli/src/output.ts:58 `emitError` computes `const code = e instanceof BrandnanaError ? e.status : 1;` and then line 74 `process.exit(typeof code === "number" && code > 0 ? 1 : 1)` — both ter

### withSyncRun records ok=0 with the 409 error even when waitForCrawl then succeeds — stale local audit row contradicts the actual outcome
- **surface:** projects/brandnana/apps/cli/src/commands/catalog.ts:144-206; projects/brandnana/apps/cli/src/sync-runs.ts:31-46  
- **class:** partial-data | **dimension:** bash-timeout  
- **fix:** Either move the 409 handling inside the withSyncRun callback so success can be recorded, or after a successful waitForCrawl update the latest catalog sync_run row to ok=1 (note 'completed via server-side wait'). Keeps the local audit log consistent with the emit() summary the agent prints.  
- **verified:** VERIFIED against actual code — the finding holds on every load-bearing claim.

Control flow (projects/brandnana/apps/cli/src/commands/catalog.ts):
- Line 141: `try` opens. Line 144: `await withSyncRun(db, { kind: "catalog", source: strategy }, async () => {...})` runs the crawl stream INSIDE the try

### book render-slides has no client-side timeout; a slow synchronous server render can be cut by the agent bash timeout and re-run as the SAME class as the crawl bug
- **surface:** projects/brandnana/apps/cli/src/commands/book.ts:247 (fetchRenderSlides) and api/src/scrape/browser.ts:228-348 (renderDeckSlides)  
- **class:** bash-timeout-cut | **dimension:** strategist-stage2  
- **fix:** Mirror the crawl fix: give fetchRenderSlides an AbortController with a budget (e.g. WB_RENDER_TIMEOUT_MS) that EXCEEDS the realistic render wall-clock, and on a cut/timeout poll a server-side render status rather than blindly re-POSTing. Cheaper interim: cap the deck-gate render to a small slice and bound the per-call slide count so one synchronous render is always well under the bash/done-check ceiling. Add an fm steering the agent off blind render re-runs.  
- **verified:** The cited code largely exists and the low-level facts check out, but the finding's central claim — that render-slides is "exactly the SAME class" as the crawl-cut/retry spin and therefore high severity — does NOT hold. Path note: the finding cites `api/src/...`; the real tree is `apps/api/src/...` (

### substrate publish fetch (gitwork push) has no timeout; a large base64 tar to a slow engine blocks the bash slot and a cut re-run re-archives + re-pushes the whole workdir
- **surface:** projects/brandnana/apps/cli/src/commands/substrate-publish.ts:131,106-109  
- **class:** bash-timeout-cut | **dimension:** strategist-stage2  
- **fix:** Add an AbortController with a generous timeout to the gitwork push fetch, and stream/chunk large archives rather than buffering one base64 body. On a timeout, check whether the ref already updated (HEAD/GET the ref) before re-archiving and re-pushing.  
- **verified:** Verified against actual code. The mechanism is real but the finding overstates parts of its evidence; net it is a genuine low-severity robustness gap.

CONFIRMED:
- /Users/shinyobjectz/Apps/workbooks/projects/brandnana/apps/cli/src/commands/substrate-publish.ts:131 — the `await fetch(${engineUrl}/ap

### fm-pre-read-barrier false-positives on the sanctioned wb agent wait path — a legitimate >120s server-side block on slow children is read as a busy-poll and told to 'use wb agent wait' (which it already is)
- **surface:** substrates/brandnana/profile/agents/brandnana-strategist.org:364-373 + substrates/brandnana/profile/skills/pre-read.org:168-174  
- **class:** retry-spin | **dimension:** agent-skills  
- **fix:** Exempt the `wb agent wait` command from the duration check (e.g. add an ARG_NOT_PATTERN / scope the jq select to exclude tool_calls whose command contains 'wb agent wait'), so the detector targets only ad-hoc sleep-loops, not the blocking barrier verb the skill mandates.  
- **verified:** VERIFIED REAL. Every load-bearing claim checks out against the actual code.

1. `wb agent wait` blocks server-side for up to its timeout. Confirmed at /Users/shinyobjectz/Apps/workbooks/cli/wb/src/cli.rs:2122-2249 (the CLI process loops polling children + files until both resolve OR `deadline` = now

### waitForCrawl progress() is silent in --json mode (the mode the agent uses); the agent sees zero output during a multi-minute wait
- **surface:** projects/brandnana/apps/cli/src/commands/catalog.ts:242,249 (progress calls) + output.ts:80-82 (progress only emits in human mode) + harvest-sweep.org:237 (agent invokes with --json)  
- **class:** silent-error | **dimension:** substrate-chain  
- **fix:** Have waitForCrawl emit machine-readable heartbeat lines even in --json (a distinct stream of {waiting:true, status, products} NDJSON, or route the poll heartbeats through a writer that is not suppressed in json mode), so the agent and the trace see steady progress and do not classify an in-flight wait as a stuck verb.  
- **verified:** VERIFIED against the actual code; the finding is real and grounded, with two minor mechanism imprecisions that justify a severity downgrade rather than rejection.

Confirmed evidence (all cited lines match):
- waitForCrawl emits its only liveness signals via progress(): catalog.ts:241 ("crawl alread

### substrate publish backend drift: code pushes backend:'r2' but the agent-facing skill says backend=local — agent records the wrong durability claim
- **surface:** projects/brandnana/apps/cli/src/commands/substrate-publish.ts:134 (backend:'r2') vs substrates/brandnana/profile/skills/harvest-sweep.org:387,393,466  
- **class:** other | **dimension:** substrate-chain  
- **fix:** Pick one backend as the post-fix contract and make doc match code: update harvest-sweep.org and checkpoint-substrate.org to say backend=r2 (matching publish.ts), and confirm the engine's r2 gitwork backend is wired in the deploy the scout runs on; otherwise revert publish to backend:'local'. Have the skill's provenance-recording step echo the backend the command actually used rather than a hardcoded label.  
- **verified:** Verified against the actual code; every cited line holds.

CONFIRMED CITATIONS:
- projects/brandnana/apps/cli/src/commands/substrate-publish.ts:134 — the CLI POSTs `JSON.stringify({ ref, content, backend: "r2" })`. The header comment (lines 21-27) deliberately chose `r2` over the "unsafe shared `loc

