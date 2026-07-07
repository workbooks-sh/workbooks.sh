# Full Security & Integrity Audit Plan

Successor to the review-hardening pass (PRs workbooks.sh#6, autopoet#1). That pass closed the
findings it *looked for*; this plan audits the five areas it explicitly did **not** cover. Grounded in
real recon (route counts, module inventory, the Admission API, dep manifests, test topology).

**Method discipline (non-negotiable, from CLAUDE.md diagnostics canon):**
- **Validate the instrument first** — reproduce every measurement through the *real production path*
  (the same entry the product uses) before any deep dive. A probe that skips a stage the real lane runs
  is testing a different system.
- **Adversarially verify every security finding** — spawn independent skeptics prompted to *refute*;
  keep only findings that survive. Prevents plausible-but-wrong reports.
- **No silent caps** — if a sweep bounds coverage (top-N routes, sampled deps), log what was dropped.
- Evidence hierarchy: running behavior > targeted tests > source > canon > docs.

Severity legend: **S0** exploitable breach · **S1** integrity/data-loss · **S2** cost/abuse ·
**S3** drift/debt · **S4** hygiene.

---

## Workstream A — Full penetration audit  *(the bulk; ~196 routes, all crypto/session paths)*

### A1 · Crypto internals  (S0)
**Targets:** `nexus/lib/{session,attest,authorship,git_sign,s3,ledger,broker}.ex`,
`nexus/lib/auth/{session,token_store}.ex`, `nexus/lib/control_plane/{token,env}.ex`.
**Check:** key derivation + rotation; IV/nonce uniqueness per encryption (env store already random-IV —
verify the rest); AES-GCM tag verification; `Plug.Crypto.secure_compare` on *every* token/secret/hash
comparison (grep `==` near hashes); no plaintext secrets at rest; `WB_ENV_MASTER_KEY` fail-closed when
absent; SigV4 correctness in `s3.ex`; signature verification in `attest`/`authorship`/`git_sign`
(is it *checked*, not just produced).
**Tools:** targeted read + a crypto-invariants test module (`test/crypto_invariants_test.exs`).
**Exit:** every crypto call site has a one-line justification in an audit table; zero non-constant-time
secret compares; zero plaintext-at-rest; adversarial verify passes.

### A2 · Session & cookie handling line-by-line  (S0)
**Targets:** `nexus/lib/auth/session.ex` (issue/verify/renew half-life), `nexus/lib/auth/native.ex`,
`nexus/lib/auth/github.ex` (CSRF state cookie), the logout path, `Nexus.Auth.Cloud`.
**Check:** `Secure` + `HttpOnly` + `SameSite` flags on every set-cookie; signed vs encrypted payload;
session TTL + sliding renew; **fixation** (rotate session id on login/privilege change); CSRF token on
all state-changing routes (not just GitHub OAuth); logout truly invalidates; cookie domain/path scope;
no session data leakage in error bodies.
**Exit:** a `session_security_test.exs` asserting flags + rotation + logout invalidation; documented
cookie posture.

### A3 · Route authorization matrix  (S0)  *(highest-yield)*
**Targets:** all **~196** routes — 43 in `nexus/lib/server.ex`, 142 in `autopoet/app/**` server blocks,
11 in `dogfood/**`.
**Method:** build a matrix `route × method × declared-auth × actual-guard × expected`. Hunt: public
routes touching tenant data; admin actions missing `admin_only`; **IDOR** (every resource id
tenant-scoped — the env store test is the model, extend to proposals/chat/requests/data/workspaces);
missing rate limits on auth + costly endpoints; the `auth: :public` set (e.g. `/body/file`, just
hardened — audit its siblings `Notes`/static serve for the same traversal class).
**Automate:** a test that enumerates the router and *fails* on any route with no explicit auth posture
(prevents future fail-open additions — the class that produced the `/api/cloud` gap).
**Exit:** committed route-authz matrix + the enumeration guard test; every S0/S1 row remediated.

### A4 · Dependency CVE scan  (S1)  *(no tooling today — install it)*
**Targets:** `nexus/mix.lock`, `autopoet/mix.lock`, `package.json`; `cli/` (Cargo) if present.
**Do:** add `{:mix_audit, "~> 2.1", only: [:dev,:test], runtime: false}` to both mix projects; run
`mix deps.audit` + `mix hex.audit` (retired pkgs); `npm audit --omit=dev`; `cargo audit` if Rust.
Triage → pin/upgrade; wire into CI (see E4).
**Exit:** zero unpatched high/critical; audit step green in CI.

### A5 · Input / injection surface  (S0)
**Check:** param handling across the ~196 routes; SSTI in `nexus/lib/ssr.ex` (template render of
user data); path traversal siblings of the `Body.read` fix (`Notes`, static file serve, `git_http`);
SQL built in `Nexus.Store` — confirm *parameterized*, no string interpolation; the washy `host_exec`
trust boundary; **SSRF** in `Browse`/web caps + outbound `provisioner`/`cloud/fly`/`telnyx`/`polar`
(user-influenced URLs?).
**Exit:** injection test cases for each class; SSRF allowlist confirmed on outbound host caps.

### A6 · Secrets at rest & in transit  (S1)
**Check:** no secrets in logs (`grep` logging of key/token/secret vars); TLS `verify_peer` on *every*
outbound `:httpc`/`Mint` call (voice_brain claims it — verify all sites); litestream/Tigris credential
handling (`LITESTREAM_*` env only, never in config file — confirm); the fly-secret set has no orphans
vs code expectations.
**Exit:** log-scrub confirmed; TLS-verify matrix complete.

---

## Workstream B — Voice/live unmetered spend  *(wb-9llj3, S2)*
`Nexus.Inference.Admission` already has `cost(model, usage)` → `charge(tenant, amount)` + `status/1` —
metering is a *wiring* job, not new infra.
- **B1** Map exact off-boundary sites: `voice_brain.work` `reply/107` + `stream_req/163`,
  `gemini_live.work` — and where usage/token counts land in each response.
- **B2** After each completion, `Admission.charge(tenant, Admission.cost(model, usage))` — **async /
  post-hoc**, off the hot path (no gateway hop; latency is the reason these lanes exist).
- **B3** Decide admit-vs-meter: realtime = post-charge for latency, plus a periodic balance guard so a
  drained tenant can't stream unbounded.
- **B4** Test: a voice turn moves the tenant ledger; `status/1` reflects it.
- **Exit:** no LLM lane spends unmetered; wb-9llj3 closed; the keys.work/voice_brain "unmetered
  exception" docstrings deleted (no longer true).

---

## Workstream C — Architectural drift  *(S3)*
- **C1 · `Nexus.Wasmer.Cc`** (`toolkit.ex:72-73`, C/C++→wasm compile) — foreign runtime, owned by epic
  **wb-4z3fv**. Audit: is C/C++ toolkit compile actually exercised (any live caller / test)? If dead →
  gate/remove now; if live → confirm it's in wb-4z3fv's scope + timeline. Contradicts the emulation
  canon until migrated.
- **C2 · `nexus/lib/cloud/fly.ex` autopoet leak** (`:28` `autopoet:v1`, `:62` `AUTOPOET_IMAGE`, `:191/194`
  `Autopoet.Control`/`AUTOPOET_PORT`) — genericize per THE LINE: image + port from config, drop the
  retired `Autopoet.Control` reference. The open runtime must carry no product bindings.
- **C3 · Parallel file-state layer** — inventory every durable `File.write`/`term_to_binary` site
  (`connections`/`requests`/`proposals`/`chat`/`venture`/`intake`/`requisition`.work). Produce a
  keep-vs-migrate table: migrate generic state to `Nexus.Store` (SQLite, config already wires it); keep
  documented exceptions (`connections` = user tokens that must never reach cloud/git — already justified).
- **Exit:** C1 resolved or linked to wb-4z3fv; fly.ex product-neutral; file-state table with decisions.

---

## Workstream D — Merge & deploy verification  *(S1 — nothing is real until live)*
- **D1** Review PRs workbooks.sh#6 + autopoet#1 (self-review; optionally `/code-review ultra`).
- **D2** CI green: `dogfood-deploy.yml` (build + boot + /health smoke — proves the `.dockerignore`
  consolidation builds a correct, slim image), `nexus-image.yml`, `dag-check.yml`.
- **D3** Merge order: monorepo (nexus+dogfood auth changes) first, then autopoet; bump the submodule
  pointer in a follow-up commit.
- **D4** Deploy wb-dogfood; re-run live smoke — confirm in **prod**: `/api/cloud/*` unauth → 401 (P0.7),
  `POST /auth/signup` on the control plane → 403 (P0.1 fail-closed), all `/api/platform` still gated.
- **Exit:** both PRs merged, CI green, prod smoke re-confirms every P0 gate.

---

## Workstream E — Full test suite end-to-end  *(S1)*
- **E1** Single-pass full run: nexus (**271** files) + autopoet (**46** files), `--exclude live`. Capture
  every failure/flake (not targeted slices).
- **E2** Fix/quarantine flakes (`:eaddrinuse` already fixed — watch for other shared-port/shared-file
  cross-test coupling).
- **E3** Land the new regression coverage from A3 (route-authz guard) + B4 (metering) + A1/A2 (crypto,
  session) so these areas never silently regress.
- **E4** Wire `mix_audit` (A4) into CI so CVEs are caught continuously.
- **Exit:** full suite green in one pass; new guards in CI.

---

## Sequencing
1. **D** first (merge + deploy the hardening already done — stop it rotting on a branch).
2. **A3 → A2 → A1 → A4 → A5 → A6** (authz + session = biggest breach surface; then crypto; then CVE; then injection/secrets).
3. **B** and **C** in parallel with A (independent).
4. **E** continuous, gates each merge.

Track as bd epic + one child per workstream (A–E). Each child's Definition of Done = its Exit criteria above.
