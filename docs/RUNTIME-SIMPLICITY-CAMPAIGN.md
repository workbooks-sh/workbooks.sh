# Runtime Radical-Simplicity Campaign

**Goal:** shrink the runtime *core* toward the dream — ~10–15k LOC, far fewer files — by
**drawing the right boundaries (structure over flags), not deleting essential code.**
Today: ~210 host files / ~44.5k LOC. The literate core is already ~2.5k; the bulk is
cloud, features, compiler lanes, and a long tail that belong in their own homes.

**Two north stars from the decision sessions:**
1. **Structure over flags.** Env-var flags (`WB_WEB`, `WB_PUBLIC`, `WB_CLOUD`, `WB_FEATURES`,
   `WB_CLIP`, `WB_CONTROL_PLANE`) are a symptom of bundling everything into one app. Replace
   them with *structure* (separate apps, loaded toolkits). Deployment = "which app," not a flag.
2. **One config surface.** Genuine deploy config (`WB_DATABASE_URL`, `WB_STORAGE`, ports,
   quotas, `WB_IMAGE`) is config *of a nexus deployment* — read in ONE place, not scattered
   `System.get_env` calls.

## Verification discipline (every step)

- `mix compile` clean **and** the test suite green before committing. Commit each win.
- If a step can't be done while keeping the build green, **skip it and file a note** — never
  leave the build broken. Risky structural steps go in small, independently-green sub-steps.
- Push per logical chunk.

## Order (safe → risky, value-weighted)

### 1. Quick kills (safe, immediate)
- `demos/seed.ex` (294 LOC of demo data compiled into host) → move to test fixtures or delete.
- The 2 org/oql stragglers → delete.

### 2. Deploy-config → one `Workbooks.Config` surface (mechanical, safe)
- Inventory every `System.get_env("WB_*")`. Split into **deploy-config** vs **role-flags**.
- Deploy-config (`WB_DATABASE_URL`, `WB_STORAGE`, ports, quotas, `WB_IMAGE`, `WB_RUNTIME_URL`…)
  → one `Workbooks.Config` module read at boot; replace scattered `System.get_env`.
- Leaves only role-flags, which fronts 5 & 6 eliminate structurally.

### 3. Data-layer deletions (enabled by the resource model)
- Migrate `Wit` callers to `Workbooks.Resource`; **delete `Wit.Types` default-inference** and
  the silent-`string` degradations in `wit.ex`.
- Delete the hand-rolled `exec_broker` binary protocol for component units (use wasmex.Components).
- Validate/replace the unvalidated `Jason.decode!` sites (move with cloud where applicable).

### 4. Long-tail consolidation (the file-count half of the dream)
- 72 files under 100 LOC = ~4.6k. Merge cohesive small modules into their natural homes.
- Target: far fewer, larger, coherent files. Do incrementally, green per merge.

### 5. Features → toolkits (kills `WB_FEATURES`; structure not flags)
- Re-shape **wavelet** from the `WB_FEATURES` flag → out of the core compile with **no flag**
  (parked under `toolkits-src/` for WIT-component conversion; not compiled into core).
- Same for **evals**, **voice**, **pallet** — cut their caller edges (cli/web/application),
  move out of core. Agent/browse stay (woven core capabilities).

### 6. Cloud → separate app (the big one; kills `WB_WEB`/`WB_PUBLIC`/`WB_CLOUD`/`WB_CONTROL_PLANE`)
- Stand up a **2-app structure**: `core` (the runtime) + `cloud` (the publishing/nexus server),
  with **cloud depending on core** (one-way). Deploy core to *run* workbooks, cloud to *host* them.
- Move the cohesive cloud cluster (web, public_web, control_plane, nexus*, billing, deploy*,
  publish*, serve/tcp_serve_broker, phoenix_socket, auth, rbac, desktop_control, usage_meter)
  → the cloud app.
- Cut the 5 core→cloud edges: `application.ex` boot, `cli.ex` deploy/publish/kit verbs,
  `workbooks.ex`→ControlPlane, `desktop.ex`→Deploy, `library.ex`→Storage.
- Keep shared infra in core: `db`, `embed`, `vfs`, `storage`, `vector`, `vars`.
- Result: **no role-flags** — the cloud app *is* the web/control-plane; the core boots lean.

## Done when

The core runtime — parse → resource/data → dock → sandbox-execute → compile-orchestrate —
is a lean, flag-free app; cloud is a separate app; features are toolkits; deploy config is one
surface. Then we measure the real core LOC/file count against the dream.
