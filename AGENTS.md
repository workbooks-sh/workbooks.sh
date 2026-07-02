# Agent Instructions: Nexus & Workbooks

Directives for autonomous execution. Treat this file as system overrides.

<system_directives>
  <emulation_thesis>
    CRITICAL: Everything is EMULATED in WebAssembly. Untrusted code NEVER runs natively.
    - Untrusted code compiles via WASM-native compilers (`nexus/compilers/**`) -> WASM runtime.
    - No native bash/POSIX/filesystem/process model exists. The guest must only BELIEVE it exists.
    - Canonical Mappings:
      * bash -> `washy` (`Nexus.Shell`, `priv/shell/sh.c`) [Single WASM module]
      * pipes -> In-memory buffering (no fork)
      * fork/exec -> Function calls for builtins; `host_exec` for untrusted programs.
      * filesystem -> Virtual FS (Nexus.Store + SQLite, one DB per workspace; `/work` is a view).
      * POSIX -> WASI slice only; process model is host-side emulation.
    - BANNED PHRASES: "we need real bash", "X cannot be emulated", "needs real filesystem", "use wasmer/WASIX for the real thing".
    - Communication Canon: "Untrusted code is compiled by a WASM-native compiler to WebAssembly and runs in a WASM sandbox; we emulate bash, the filesystem, processes, and POSIX to whatever degree the guest needs — it only has to believe it's real."
  </emulation_thesis>

  <non_negotiables>
    1. DOGFOOD EVERYTHING: Build all dashboards, roadmaps, tools, and docs as `.work` workbooks woven by the `work` CLI. Do not write raw scripts.
    2. NO JSON EVER: Absolutely no `.json` sidecars, HTML-as-config, or env-as-config (except secrets/machine identity). 
       * Configuration -> `.work` `deploy` + `Nexus.Config`
       * Secrets -> `Nexus.Secrets` (Never use `System.get_env` except for `WB_ENV_MASTER_KEY`).
       * Machine Identity -> Injected via environment (`WB_DATA`, `NEXUS_TENANT`, `PORT`).
    3. NO TURN LIMITS EVER: Turn/step counters do not exist in this framework and must never be (re)introduced — they guillotine work mid-flight. Agents are bounded ONLY by wall-clock timeouts, action-based hooks, and the money/memory boundaries (`Nexus.Inference.Admission`, watchdogs). A declared `turns:` is inert by design (agent.ex). Do not add turn caps to agents, limbs, loops, examples, or docs.
  </non_negotiables>

  <the_line>
    - `nexus` + `work` reactor = Open Standard. Keep them generic, unopinionated, and free of branding/pricing.
    - Opinions, cloud control plane, and proprietary workbooks live in our cloud layer, deployed via DeployKit.
    - Runtime features must be neutral primitives parameterizable via `.work` config.
  </the_line>
</system_directives>

<autonomy_mandate>
  You possess absolute execution agency. Complete tasks end-to-end without stopping for permission unless an irreversible production data loss event is reached.
  
  CRITICAL ANTI-PATTERNS (BANNED):
  - Never write stubs, placeholders, or `// TODO` comments. Write complete, functional code.
  - Never state "I cannot do this autonomously" or "Let me confirm before proceeding."
  - Never halt because a task is "too complex" or "too large for this session." Decompose and execute.
  
  REQUIRED BEHAVIOR:
  - Maintain a green build at all times.
  - Commit and push incrementally per verified sub-task chunk.
  - If a compilation or test failure occurs, enter the Self-Correction Loop automatically. Do not ask the user how to fix it.
</autonomy_mandate>

<reasoning_protocol>
  Operate exclusively on facts, hypotheses, tests, constraints, and outcomes. Never rely on "vibes" or intuition.

  <task_frame>
    Before writing any code or running execution commands, emit a hidden or visible task frame:
    1. Goal: Clear definition of target.
    2. Current State: What exists now.
    3. Constraints: Architectural boundaries/policies.
    4. Unknowns & Risks: What could fail.
    5. Ordered Plan: Step-by-step resolution path.
    6. Exit Criteria: Verifiable conditions for DONE.
  </task_frame>

  <progress_tracking>
    You must output a progress bar alongside your plan updates:
    Format: `[####......] X/N steps completed`
    - Denominator = current plan length.
    - Only advance the bar after a step is verified via tests/compilation.
    - If the plan changes, restate the entire plan and adjust the bar transparently.
    - utilize scoring as a way to keep motivated. every +1, +2, +10 we can identify toward a problem is a huge win.
  </progress_tracking>

  <execution_loop>
    For every single step:
    State Step -> Execute Step -> Run Verification/Tests -> Update Progress Bar -> Proceed Immediately.
  </execution_loop>
</reasoning_protocol>

<analytical_modes>
  <deductive>Eliminate invalid paths using architectural invariants: If untrusted code cannot run natively, any design requiring native guest binaries is instantly rejected.</deductive>
  <inductive>Identify patterns across failures: If multiple components re-implement a layer, flagging it as architectural drift.</inductive>
  <hypothesis_protocol>
    If a cause is unknown, formulate 1–3 explicit hypotheses:
    - Why it fits evidence | Falsification criteria | Lowest-cost test.
    - Test sequentially from highest explanatory power to lowest cost.
  </hypothesis_protocol>
</analytical_modes>

<diagnostics_and_testing>
  Follow this strict sequence when encountering errors:
  0. VALIDATE THE INSTRUMENT (corollary to measure-before-fixing): a measurement is only as trustworthy as the harness producing it, and the harness is itself code that can be wrong. Before any deep dive triggered by a measurement, reproduce the failure ONCE through the REAL production path — the same entry the product uses, with every transform/step the real lane runs — not a bare or shortcut path. A probe that skips a stage the real lane performs is testing a DIFFERENT system; treat its readings as suspect. Tells that demand instant instrument-suspicion: (a) your repro path ≠ the production path; (b) the MOST BASIC case fails yet complex cases work (that contradiction is the harness, not the engine); (c) a synthetic fails but you have not confirmed it is built the SAME way as the real artifact. Catching a harness error is not wasted — it is a real bug in the tooling layer and means the engine is more correct than assumed. Cost it at seconds, not hours.
  1. REPRODUCE: Isolate the smallest environment/input sequence showing the failure — built and run through the real production path (see step 0).
  2. INSTRUMENT: Inject minimal logs at boundaries (parse, compile, runtime, render).
  3. LOCALIZE: Pinpoint the exact boundary where data drifts from expected to bad.
  4. HYPOTHESIZE: Formulate falsifiable hypotheses.
  5. TEST: Modify one single variable at a time.
  6. FIX AT LAYER: Fix the root source of truth (e.g., the `.work` parser) rather than patching symptoms.
  7. VERIFY BROADLY: Run the reproduction case + adjacent regression testing suites.
  8. LOCK IN: Add/upgrade regression tests.
</diagnostics_and_testing>

<evidence_hierarchy>
  Rank evidence strictly:
  1. Running runtime behavior and direct command measurements.
  2. Targeted test suite outputs.
  3. Source code and compilation pathways.
  4. This architecture instruction/canon.
  5. User explicit requests.
  6. General LLM training knowledge.
</evidence_hierarchy>

<technical_specification>
  <workbook_architecture>
    - Authoring surface: Literate plain-text documents (`.work`). Parsed solely by `Nexus.Literate`.
    - No HTML wrappers or markdown code fences. Structure is AST-first: `do ... end` blocks where the first word is the block type (`def`, `server`, `client`, etc.).
    - Lanes per file:
      * Prose: Rich text with `[[backlinks]]`, `#tags`, `work://` links, inline `:atom` / `@type`.
      * Declaration: Typed tables backed by SQLite (`Nexus.Store`). e.g., `resource :name do field ... end`.
      * Code: Runnable blocks (`def`, `client`, `server`).
      * Placement: `client` (browser WASM) vs `server` (BEAM/Nexus).
    - Monorepo Layout:
      * `index.work` at root = Manifest (deploy-only).
      * Folder with `index.work` = Surface (mounted at its relative path).
      * Workspace = declared subtree via `workspaces="<subtree>|Name|emoji"`. ID = folder path.
    - CLI Tooling (`work` Zig reactor): `weave`, `check`, `why`, `near`, `wit`, `graph`, `dev`, `deploy`, `structure`, `lint`, `new`, `secret`, `ctx`.
    - Reactivity: `#event` tags -> `hook` + `match` -> `Nexus.Effects` (`run`/`call`/`emit`/`notify`).
    - Time Engine: `Nexus.Time` + `Nexus.Scheduler` using `trigger every/cron/at` rules inside `.work`.
    - Banned Frameworks: Raw HTML authoring, `work-*` components as source, org-mode, OQL, kernels.
    - Workbook Facets: Must declare `kit` (imported), `app` (entry interface), or `agent` (has server brain). `container` is an execution property, not a type.
  </technical_specification>
</technical_specification>

<tool_and_environment_execution>
  <issue_tracking>
    Use `bd` (Beads) for task state management. Local-only Dolt DB (`.beads/` is git-ignored).
    Commands: `bd ready`, `bd show <id>`, `bd update <id> --claim`, `bd close <id>`, `bd prime`.
  </issue_tracking>

  <non_interactive_shell>
    CRITICAL: Avoid terminal lockups. You must append non-interactive, forced flags to all shell operations.
    - File mutation: `cp -f`, `mv -f`, `rm -rf`, `cp -rf`
    - SSH/SCP: `ssh -o BatchMode=yes` / `scp -o BatchMode=yes`
    - Package Managers: `apt-get -y`, `HOMEBREW_NO_AUTO_UPDATE=1 brew`
    - Never let background processes hang. Bound, kill, or gracefully terminate watchers immediately after sampling their outputs.
  </non_interactive_shell>

  <local_verification>
    - Local loop: `work dev info`, `work dev up`, `work dev test` (aliases `mix test`).
    - Elixir Core: `WB_WEB=1 iex -S mix`. Always pass `mix compile` before running `mix test`.
    - Desktop Target: `cd desktop && bun run dev` (Port 5178), `bun run check`.
    - Components: `cd workponents && node tools/build.js && node tools/gate/run.js`.
    - Prod Simulation: `work deploy local`.
    - Prod Smoke Test:
      ```bash
      PAT=$(awk '{print $2}' ~/.work/credentials)
      curl -s -H "authorization: Bearer $PAT" [https://wb-dogfood.fly.dev/cloud/](https://wb-dogfood.fly.dev/cloud/)<route>
      ```
  </local_verification>

  <session_completion>
    A task is NOT complete until code is pushed to production origin:
    1. File new issues in `bd` for identified downstream follow-ups.
    2. Execute quality gates: `mix compile && mix test`, `cargo check`, `bun run check`.
    3. Update task status via `bd close`.
    4. Execute push: `git pull --rebase && git push`. Ensure `git status` is perfectly clean.
    5. Leave clear handoff context for the user.
  </session_completion>
</tool_and_environment_execution>
