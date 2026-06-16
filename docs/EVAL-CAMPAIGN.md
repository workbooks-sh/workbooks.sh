# Workbooks Comprehensive Eval Campaign

**Mission:** prove *every* promise the system makes — objectively, end-to-end, adversarially — and keep it proven. Not piecemeal. Not gamed. The bar: a skeptical engineer reads the evidence and agrees it actually works.

This is the single worklist an autonomous loop (a 2-minute cron) works through. Each fire does ONE unit of real work and records honest evidence.

---

## The Non-Gaming Constitution — read EVERY fire, no exceptions

1. **GREEN means an objective test passed for real.** Objective = a command that exits 0, a deterministic assertion, or a measured number ≥ a fixed bar — with the command + its output recorded as evidence. "Looks right" is never GREEN.
2. **When a test fails, fix the REAL system.** Change the product code so the behavior is actually correct. NEVER:
   - weaken or delete the test, loosen an assertion, or lower a pass bar to get green;
   - add eval-case-specific examples, hints, or "don't do X" rules to the agent/prompt to pass a specific case;
   - mark GREEN without recorded evidence, or hand-wave ("should work");
   - mock/stub the thing under test so the test no longer exercises it.
   If you are tempted to do any of these, STOP — record the real blocker, leave it RED, move on.
3. **Tests must be able to fail.** A test that can't go red proves nothing. Before trusting a green, confirm it fails when the behavior is broken (mutate, observe red, revert).
4. **Adversarial by default.** For each promise, also write the test that tries to BREAK it (wrong input, hostile input, the failure mode). A promise isn't proven until its failure modes are tested.
5. **Honest status always.** RED with the real reason beats a fake GREEN. The campaign's value is the truth it tells.
6. **Improve, don't accrete.** Prefer fixing/simplifying real code over adding scaffolding. Fewer lines that actually work > more lines that look like work.
7. **No silent scope cuts.** If you skip/sample/cap, say so in the evidence.

---

## What each cron fire does (the loop)

1. `git pull --rebase` (stay current; another session moves `main`).
2. Read this file + the **Status Log** at the bottom.
3. Pick the **single highest-priority item that is not GREEN** (phase order below, then top-down). Don't re-do GREEN items unless re-verifying rot.
4. Do the work for that ONE item:
   - **Verify** (item has a test): run the objective command. PASS → mark GREEN with the command + result. FAIL → go to Fix.
   - **Build** (gap item, no test): write a REAL, adversarial-where-relevant objective test against the actual behavior. Confirm it can fail. Then run it.
   - **Fix** (test red): diagnose, fix the REAL product code, re-run. Green → record. Still red after a bounded effort (≈1 fire) → record the real blocker, leave RED, move on. Never thrash one item across many fires; if stuck twice, file a bd issue and skip.
5. Run the guardrail + a quick compile to ensure no regression: `cd runtime && mix compile` and `mix test test/cli_name_test.exs`.
6. Update the item's status + append a one-line entry to the **Status Log** with evidence (command + result + commit sha).
7. Commit with **targeted** `git add <only the files you changed for this item>` — NEVER `git add -A` (the runtime generates uncommitted artifacts: `runtime/build/`, `runtime/deps`, `runtime/keeper-last-run`, `examples/groundwork/BOARD.org`, and the local dev-config `desktop/{bun.lock,package.json,vite.config.ts}` + `desktop/src-tauri/Cargo.lock` — do NOT commit any of these). Clear message. `git push origin <branch>:main` (no `| tail`).
8. Stop. One item per fire.

Operating constraints: model for agent evals = `minimax/minimax-m3` (the product model); judges stay gemini. Never commit `.beads`. Don't `| tail` a git push (it masks the exit code).

---

## Objective gate commands (per surface — the cron's toolbox)

| Gate | Command | Bar | Needs |
|---|---|---|---|
| Runtime suite | `cd runtime && mix test` | 0 failures (≈831 tests, 365 heavy-tagged excluded) | — |
| CLI-name guardrail | `cd runtime && mix test test/cli_name_test.exs` | 0 | — |
| Agent quality | `OPENROUTER_API_KEY=… mix run bench/agent_evals.exs` | ≥ floor (baseline 9/9) | LLM key |
| Agent capability (tool use) | `mix run bench/agent_capabilities.exs` | 4/4 | LLM key |
| Component-emit (composition + vision) | `mix run -e 'Workbooks.Evals.Components.run()'` | per-spec; deterministic checks pass | LLM key + Chrome |
| Workponents design-lint | `cd workponents && node tools/design-lint.mjs` | PASS (0 violations) | node |
| Workponents 5-gate | `cd workponents && node tools/gate/run.js --strict` | 45/45 | node + playwright |
| Scaffold eval | `cd workponents && node --test tools/scaffold.test.mjs` | 4/4 | node |
| Desktop e2e (mock) | `cd desktop && WB_E2E_PORT=5178 bunx playwright test app.spec.ts features.spec.ts adversarial.spec.ts` | all pass | bun + chromium |
| Desktop LIVE e2e (real agent in UI) | boot runtime (`WB_WEB=1 WB_LLM_MODEL=minimax/minimax-m3` …) + vite (`VITE_WB_RUNTIME_URL=…`) + `WB_LIVE_E2E=1 bunx playwright test agent-live.spec.ts` | all pass | runtime+vite+chromium+key |

When a gate needs a key/Chrome/playwright that isn't available in the fire's environment, record `BLOCKED: <dep>` (not RED) and move to the next item — a missing dep is not a failed promise.

---

## Phases (work in order)

### Phase 0 — Baseline truth (do first)
- [x] **0.1** `cd runtime && mix test` → **1128 tests, 49 failures, 11 invalid (396 excluded)** on an UNPROVISIONED dev box. ALL 49 trace to `{:clang_not_built, …llvm.core.wasm}` — the in-sandbox compiler toolchain (gitignored, CI/provisioned-only) is absent. **No real regressions; the repo-wide `work` rename broke 0 tests.** Treat `clang_not_built` (+ network/key/playwright/krunvm) as **BLOCKED:dep**, never RED. capabilities.json's "831, 0 failures" was measured on a provisioned machine.
- [x] **0.1a** DONE — default `mix test --seed 0` = 1071 tests, **2 failures, 0 `clang_not_built`** (was 49, all toolchain). Of the 2: `TenantIsolationHttpTest` is `/api/oql/query` → **DEFERRED (org-mode/OQL is being deprecated — skip OQL/org surfaces in this campaign)**; `ToolkitInjectionTest` direct-verb is now FIXED (it was a rename miss — see Status Log). Beyond those, a timing-flaky tail (same seed → different failures run-to-run): **wb-94qn**. Detail below:

> **DEFERRED — org-mode / OQL** (deprecating, per user 2026-06-16): do NOT chase or fix org/OQL failures — the OQL kernel (render/parse/validate/tangle, `oql.wasm`), `/api/oql/query` (incl. the TenantIsolation `/tmp/.org` confinement), org→native tangle, and `.org`-as-authoring. The direction is web-component supremacy. Mark them DEFERRED, not RED.
  - DONE: added `:wavelet` to the default exclude in `test_helper.exs` (wavelet compiles/encodes via ffmpeg.wasm → `clang_not_built` without the toolchain) → 49→**25** failures. Run with `--include wavelet` on a provisioned box.
  - DONE: fixed a guardrail FALSE-POSITIVE — `cli_name_test.exs` now skips `#+GENERATED:` artifacts (examples/groundwork/BOARD.org is regenerated by Groundskeeper.Board from bd issue TITLES; it echoed the old CLI-name strings from historical issue titles — a record, not a source ref). Guardrail back to 1/0. (NOTE: this campaign doc must PARAPHRASE the old names, never quote them literally, or the guardrail flags its own meta-text.)
  - DONE: tagged `command_registry_test`'s 11 `upper` tests `:build` (40/0, 15 excluded). Suite 25→13.
  - DONE: `@moduletag :build` on `build_recipes_test`, `run_command_telemetry_test`, `wasm_shell_test`, `fabric_test`, `brokered_app_test` (all entirely `clang_not_built`/setup-needs-toolchain; wasm_shell's setup_all even tried a `{:skip,…}` ExUnit rejects → RuntimeError, fixed by the tag). Suite 13→**4 failures, 0 invalid** (seed 0).
  - FINDING (escalated to **wb-94qn**, not part of 0.1a): the remaining failures are NOT toolchain — they're **seed/order-dependent contamination** (seed 0 = 4 incl. 3× File.Error; a random seed = 20+: JJUndo/Channels/WebKeyRelease/HarnessSecurity/NexusUsage). All in files the tagging didn't touch → pre-existing, unmasked by clearing the clang noise. The "deterministic 831/0" claim is false on two counts. Phase 1 must make the suite seed-INVARIANT (per-test state isolation) before "green" is trustworthy.
  - DONE: tagged the last `clang_not_built` straggler — `dock_component_e2e_test.exs` (1 test, runs the `upper` compiled command through the Dock → `DOCK_ERR clang_not_built`) → `@moduletag :build`. Default suite now **0 `clang_not_built`**. 0.1a complete.
- [ ] **0.2** Run guardrail, scaffold eval, design-lint, agent_evals, agent_capabilities → record real state. (Capability/component evals need a key + Chrome; mark BLOCKED if absent.)

### Phase 1 — Verify the claimed-green (catch rot)
The 31 `capabilities.json` entries + the inventory's "tested" promises each map to a test suite. Confirm each still passes; any rot → fix real code. Source of truth: `runtime/capabilities.json`. BAR for each: its named test(s) pass.

### Phase 2 — Close the gap claims (no objective test → build a real one)
Highest-ROI gaps from the inventory (build a real, adversarial-where-relevant test, then make it pass by fixing real code — never by faking):
- [ ] **2.1** Workbook *edit* persistence end-to-end (read→modify→write preserved) — covered headless (agent_capabilities) ✓; add the desktop-UI angle once chat-edit lands.
- [ ] **2.2** Custom/unknown component render resilience (unknown `:type` → graceful labeled card, painted, no crash) — **wb-pvjw**. Build at the workponents level (deterministic, no runtime).
- [ ] **2.3** `work component new` → scaffolded element passes the gate (scaffold eval ✓; wire into CI gate enforcement).
- [ ] **2.4** Deploy round-trip (`work deploy` apply/verify/down) objective test (env-gated: krunvm/docker) — BLOCKED-aware.
- [ ] **2.5** Login/IdP frontend e2e (medium) — needs a configured provider; mark BLOCKED until creds.
- [ ] **2.6** Voice end-to-end + voice/text component parity (medium) — needs keys; parity rehearsal is keyless, build that first.

### Phase 3 — Adversarial hardening
For each surface with a passing happy-path, add the break-it test: cross-tenant, hostile input, injection, quota/scope bypass, malformed component props, agent prompt-injection/secret-leak/overclaim/destructive-action, SSRF/rebind. Many exist (`bundle_security_poc`, `net_guard`, the agent safety subset); fill the holes the inventory flags.

### Phase 4 — End-to-end in the UI (the user's core: prove Waldo works in the desktop)
- [ ] **4.1** Desktop LIVE e2e: real agent → renders a component VISUALLY (painted + data-bound + themed) ✓ (`agent-live.spec.ts`). Keep green; expand cases (edit, multi-turn, tool-call render).
- [ ] **4.2** Desktop boots offline, nexus/workspace/onboarding/chat-as-tab ✓ (`app/features/adversarial.spec.ts`). Keep green.
- [ ] **4.3** A "showcase" run: one scripted session that exercises the headline promises in the real UI and screenshots each — the honest demo that doubles as the regression.

---

## Claim catalog (the full worklist — grouped by surface)

> Seeded from `runtime/capabilities.json` (31 entries) + the 87-promise inventory. Each row: claim · objective test · status. Status ∈ {GREEN, RED, BUILD (no test yet), BLOCKED:<dep>, GAMED?(needs audit)}. Keep this honest.

### Security / auth / isolation
- Multi-tenant visibility `Tenant.visible?/2` · `mix test test/tenant_visible_test.exs test/tenant_isolation_http_test.exs` · GREEN(claimed)
- Exec-capability boundary · `mix test test/capability_gate_test.exs test/wb_tool_test.exs` · GREEN(claimed)
- Direct-verb path confinement · `mix test test/cli_dispatch_test.exs` · GREEN(claimed)
- SSRF floor (agent fetch + native crawl + NetGuard, body cap, rebind) · `mix test test/fetch_ssrf_test.exs test/net_guard_test.exs test/net_guard_cap_test.exs` · GREEN(claimed) — adversarial: DNS-rebind TOCTOU (wb-ntx6), peak-RAM stream (wb-4had)
- CORS-* safe via auth lockdown · `mix test test/auth_plug_test.exs` · GREEN(claimed)
- OIDC/JWKS verifier (rejects alg:none, HS256 confusion) · `mix test test/oidc_test.exs` · GREEN(claimed); frontend login e2e · BUILD (2.5)
- WS socket auth via `?token=` (the #4 fix) · `mix test test/auth_plug_test.exs test/agent_socket_bridge_test.exs` · GREEN
- Seal / route encryption + access check · `mix test test/web_key_release_test.exs test/access_posture_test.exs` · GREEN(claimed)
- DID Ed25519 signing / verify · `mix test test/did_x25519_test.exs` · GREEN(claimed)

### Agent intelligence / tools
- Loop robustness (dead-stop/runaway/unknown-tool/parallel; the empty-turn nudge fix) · `mix test test/agent_loop_test.exs` · GREEN(claimed)
- Streaming carries tool_calls (multi-step chains; wb-0lw8 root fix) · `mix test test/agent_socket_bridge_test.exs` + capability eval · GREEN
- System-prompt composition · `mix test test/agent_prompt_test.exs` · GREEN(claimed)
- vfs_write/read workdir confinement · `mix test test/vfs_write_confinement_test.exs` · GREEN(claimed)
- Agent quality (reasoning/honesty/format, 9 adversarial) · `mix run bench/agent_evals.exs` · GREEN (9/9 minimax-m3) — needs key
- Agent capability (component-emit, workbook create/edit, tool-use honesty) · `mix run bench/agent_capabilities.exs` · GREEN (4/4) — needs key
- Recall + embeddings-down fallback · `mix test test/library_search_fallback_test.exs` · GREEN(claimed)
- AI-over-files (no fabrication) · `mix test test/library_ask_test.exs` · GREEN(claimed)
- web_search provider rotation + cite-able · `mix test test/web_search_format_test.exs test/search_provider_test.exs` · GREEN(claimed); Perplexity provider · BUILD
- Headless browse (JS-rendered, SSRF-floored) · `mix test test/browse_headless_test.exs` · GREEN(claimed); SPA async-XHR (wb-70mi) · BUILD
- OQL kernel render/parse/validate/tangle · `mix test test/oql_render_test.exs` · GREEN(claimed)
- Self-edit seam (file_issue → autopoet) · `mix test test/autopoet_test.exs` · GREEN(claimed)

### Workbook lifecycle / bundle / composition
- Bundle embed/extract byte-exact + security floors · `mix test test/bundle_embed_test.exs test/bundle_cli_test.exs test/bundle_security_poc_test.exs` · GREEN(claimed)
- Tangle (org→native, idempotent) + compile wiring + --no-build · `mix test test/bundle_tangle_test.exs` · GREEN(claimed)
- Composition islands (typed `<work-*>` ⟷ tree, P0–P3) · `mix test test/bundle_islands_test.exs test/bundle_islands_cli_test.exs` · GREEN(claimed)
- Library install/store/unpack (read_any both forms) · `mix test test/library_install_test.exs test/bundle_egress_migration_test.exs` · GREEN(claimed)

### Component / toolkit authoring (web-component supremacy)
- `work component new` scaffolds a gate-passing element · `cd workponents && node --test tools/scaffold.test.mjs` + `node tools/design-lint.mjs` · GREEN
- 45 work-* elements render + theme (token-only) · `cd workponents && node tools/design-lint.mjs` (static) + `node tools/gate/run.js --strict` (visual) · GREEN(static) / BLOCKED:playwright(visual)
- 5-gate harness (token-leak/scope/loadability/parity/visual) · CI `workponents-gate.yml` · GREEN(claimed CI) — verify CI actually runs it
- Custom/unknown component render resilience · BUILD (wb-pvjw)
- Toolkit injection + manifest-drift + direct-verb · `mix test test/toolkit_injection_test.exs test/toolkit_descriptor_test.exs` · GREEN(claimed)
- Toolkit build (existing manifest → wasm → register) · `mix test test/toolkit_build_test.exs test/toolkit_promote_test.exs` · GREEN(claimed)
- Component-emit eval (right tag, data-bound, theme-honest, voice-parity) · `Workbooks.Evals.Components.run()` · BLOCKED:Chrome+key / spec corpus growing

### Compile lanes (in-sandbox, zero native exec)
- C/Zig full compile → wasm · `mix test test/c_multifile_test.exs` (`:build` tag) · GREEN(claimed, toolchain-gated)
- Sandbox crash isolation + caps · `mix test test/sandbox_security_test.exs` · GREEN(claimed)
- WASI pallet (pandoc.wasm) · `mix test test/pallet_test.exs` · GREEN(claimed)
- Rust-in-wasm · BLOCKED:upstream-rustc · Go/Python · BUILD(planned)

### Runtime platform
- 831-test suite deterministic, 0 failures · `cd runtime && mix test` · GREEN(claimed 2026-06-14) — Phase 0.1 re-verifies
- Events log queryable · `mix test test/session_ledger_test.exs` · GREEN(claimed)
- One image local+cloud (work deploy) · BUILD (2.4, env-gated)

### Desktop app (UI)
- Boots offline, no sign-in gate; titlebar/sidebar · `desktop e2e app.spec.ts` · GREEN
- Nexus popover / workspace switcher / actions; nexus no-resignin · `app/adversarial.spec.ts` · GREEN
- New folder, chat-as-tab · `features.spec.ts` · GREEN
- Onboarding gate · `app.spec.ts` · GREEN
- LIVE: real agent renders component VISUALLY (painted+data-bound+themed) · `agent-live.spec.ts` (WB_LIVE_E2E) · GREEN — needs stack+key
- LIVE: agent creates workbook (acts+confirms) · `agent-live.spec.ts` · GREEN — open-tab→native-tab needs Tauri build · BUILD
- Install wizard e2e · BUILD (no automated test)

### Deploy / nexus
- Local deploy (krunvm) round-trip · BUILD (2.4) BLOCKED:krunvm
- Cloud deploy (work deploy apply) · BUILD BLOCKED:cloud
- Nexus protocol / dev-server discovery · `mix test test/nexus_test.exs test/nexus_usage_test.exs` · GREEN(claimed); real multi-user sync · BUILD
- Cut `work-v*` release so renamed installer has assets · EXTERNAL (publishes a release) — not for the autonomous loop

### Voice
- Voice audio socket + parity + command-exec · BUILD/BLOCKED:keys — keyless parity rehearsal first

### Collaboration (mostly gated — product decision)
- Git backing (history/diff/rollback) · `mix test test/collab_http_e2e_test.exs` · GREEN(claimed, partial)
- Workspace sharing RBAC · BUILD (gated) · Radicle p2p · BUILD (no test) · Admin role / session sharing / image-gen · DESIGN-ONLY (skip until product decision)

---

## Status Log (append-only — newest first; the loop's memory)

- **Bundle FORMAT surface VERIFIED 55/0** (Phase 1): `bundle_embed`+`bundle_cli`+`bundle_security_poc`+`bundle_egress_migration`+`bundle_loader` = 36/0; `bundle_adversarial`+`bundle_key_wrap`+`bundle_rcp` = 19/0. The packaging promise holds — byte-exact embed/extract round-trip, zip-bomb + zip-slip + control-dir-denylist defense, key-wrap crypto, .wbundle→.html read_any migration, browser loader, RCP bundle surface. (org-coupled `bundle_tangle`/`bundle_islands` DEFERRED — org/OQL.) Guardrail 1/0. Commit: <pending>.
- **Security/confine cluster VERIFIED 35/0** (Phase 1): `capability_gate` + `tenant_visible` + `did_x25519` + `web_key_release` + `access_posture` = 22/0; `agent_confine` + `no_native_exec` + `vfs_write_confinement` + `sandbox_security` = 13/0 (build-tagged compile cases excluded). The isolation floor holds — exec-capability boundary, multi-tenant visibility, DID signing, sealed-route key release, access posture, agent can't native-exec, vfs workdir confinement, sandbox crash isolation. (Ran in isolation — reliable, no suite-load flakiness.) Guardrail 1/0. Commit: <pending>.
- **Agent QUALITY VERIFIED 9/9** (Phase 1): `mix run bench/agent_evals.exs` (minimax-m3, gemini judge) = 9/9 all judge ≥9 — exact-output, trap-reasoning, json-only, distractor, no-hallucination (honest), prompt-injection (resisted), extraction, false-premise (corrected), multi-constraint. Combined with capability 4/4 (prior fire), Waldo is proven GREEN on BOTH reasoning/honesty/format AND tool-use, with the real key. (Cleared the stale secrets file defensively first.) Guardrail 1/0. Commit: <pending>.
- **Agent capability VERIFIED 4/4 + secrets-file contamination FIXED (wb-94qn source)**: the agent eval was 401ing ("Missing Authentication header") despite a VALID env key (curl → 200). Root: several tests `Secrets.put` FAKE keys ("sk-PLATFORM", tenantA/B) into the node-global `Workbooks.Secrets.path()` file ($TMPDIR, fixed path) with no cleanup; it PERSISTS across runs, and `Secrets.get` reads the file before the env → a later `mix run` (the agent eval) used the fake key. Fix: `ExUnit.after_suite` deletes the secrets file (test fixtures must not leak into real LLM runs; prod refreshes it from the control plane) + removed the stale file. Re-ran `mix run bench/agent_capabilities.exs` → **4/4, all judge 10** (component-render, workbook-create, workbook-edit read→write, tool-use-honesty) — Waldo's tool use proven with the real key. Also: `net_guard`+`net_guard_cap`+`fetch_ssrf` isolated = **22/0** (SSRF surface verified GREEN; its full-suite flakiness is wb-94qn timing, not real). Guardrail 1/0, compile clean. Commit: <pending>.
- **ToolkitInjection FIXED (real bug, Phase 1)**: the direct-verb toolkit guidance suggested a DEAD command using the OLD CLI name instead of `work` (toolkits.ex:1230 hardcoded the legacy prefix). The old name no longer exists → the agent would fail. Fixed the suggestion to `work`, made the gate accept both the old + new sentinel, and renamed the legacy CLI_BIN sentinel → `work` in 5 manifests (workbooks-cli/browser/system, byod, publish). The guardrail missed it (a bare legacy token it can't safely scan) → added a CLI_BIN-sentinel pattern so it can't recur. toolkit_injection 11/0, guardrail 1/0, compile clean. (Doc paraphrases old names — quoting them trips the guardrail's own scan.)
- **0.1a DONE**: `@moduletag :build` on `dock_component_e2e_test.exs` (last clang straggler). `mix test --seed 0` = 1071 tests, **2 failures, 0 clang_not_built** (49→2 over the campaign). Guardrail 1/0, compile clean. The 2 stable remainders: TenantIsolation OQL `/tmp/.org` confinement (DEFERRED — org/OQL deprecating) + ToolkitInjection RuntimeError (real, Phase 1). ALSO confirmed wb-94qn is TIMING flakiness not pure order: same seed-0 gives different failures run-to-run (DesktopControl/FfmpegBroker pass alone, flake under suite load via assert_receive timeouts). Commit: <pending>.
- **wb-94qn (partial)**: keeper `File.Error` contamination FIXED — `Keeper.Worker.wake` did `File.read!` in a Task, so a keeper outliving its watched def (deleted mid-flight / leaked test keeper after temp cleanup) crash-logged a misleading stacktrace each tick. Now reads gracefully (`File.read` → warning + `:failed`, backoff/survival unchanged). keeper/keeper_backoff/crew 12/0, guardrail 1/0, compile clean. REMAINING (real seed-variance, NOT fixed): harness/channels/webkey/jjundo failures vary 4↔20 by seed — hypothesis: `System.put_env` without `on_exit` reset (esp. the experimental Harness tests). Next: audit + self-contain env in tests → seed-invariance. Commit: <pending>.
- **0.1a (slice 3)**: `@moduletag :build` on build_recipes/run_command_telemetry/wasm_shell/fabric/brokered_app (all toolchain; wasm_shell's setup_all `{:skip}` RuntimeError fixed by the tag). `mix test --seed 0` = 1072 tests, **4 failures, 0 invalid** (was 13). Guardrail 1/0, compile clean. FINDING: remaining failures are seed/order-dependent contamination (3–20 across seeds), pre-existing, unmasked → filed **wb-94qn** (P1). 1 clang straggler left to tag. Commit: <pending>.
- **0.1a (slice 2)**: tagged the 11 `upper` (source-built/clang) tests in `command_registry_test.exs` `:build` (was 4 tagged, +11=15; file now 40 tests / 0 fail). Full suite **25→13 failures** (`mix test`). Also paraphrased the old CLI names in this doc (line was quoting them → guardrail flagged its own meta-text; fixed). Guardrail 1/0. Remaining 13 = build_recipes/run_command_telemetry/brokered_app `clang_not_built` + invalid setup_all (WasmShell/Fabric) — BLOCKED:compiler-toolchain. Commit: <pending>.
- **0.1a (slice 1)**: `test_helper.exs` +`:wavelet` exclude → `mix test` 49→25 fail (the 24 wavelet `clang_not_built` now excluded; run with `--include wavelet`). + guardrail false-positive fix (`cli_name_test.exs` skips `#+GENERATED:` artifacts like BOARD.org). Guardrail 1/0, compile clean. Remaining 25 = command_registry/build_recipes/run_command_telemetry/brokered_app `clang_not_built` (BLOCKED:compiler-toolchain) → tag `:build` next fire. Commit: <pending>.
- **0.1 DONE** (manual, campaign bootstrap): `mix test` = 1128 tests, 49 fail, 11 invalid — ALL `clang_not_built` (compiler toolchain absent; BLOCKED:dep, not regressions). Rename broke 0 tests. Next: 0.1a (tag compiler tests so default suite is clean), then 0.2.
- (campaign created) — plan + 2-min cron established. The loop starts at Phase 0.1a.
