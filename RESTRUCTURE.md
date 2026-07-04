# Monorepo restructure — target, rules, execution plan

**Goal:** one folder per product surface, dependencies only ever pointing *down* a DAG, so two
things can never fuse again. Recoverable at any time from the `pre-restructure` git tag.

## Target structure (6 product roots + experiments)

```
tiny-lasers/   L0   shipped WASM→BEAM runtime package. zero-dep.
cli/           L1   the `work` Zig reactor — OWNS the .work grammar (→ work-toolchain.wasm)
nexus/         L1   generic BEAM runtime — .work toolchain, server, sandbox, store, auth.
                    NO cloud/pricing/vendor code. consumes cli's compiled grammar. depends on tiny-lasers.
compilers/     L1   the WASM-native compiler moat (7.2G). a build input to nexus.
autopoet/      L2 ★ THE V1 PRODUCT — the embodied agent app. depends on nexus.
cloud/         L2   the cloud platform — provision + control-plane + Fly/Polar/Telnyx + a NEW
                    simple "deploy-a-nexus + manage integrations/keys/voice/SMS" dashboard. depends on nexus.
experiments/        pet projects + spikes + deprecated. NOT production. has its own AGENTS.md.
.github/ scripts/    the LIVE pipeline — REWRITTEN per product root, never archived.
```

## The one rule that makes it stick (CI-enforced)

Dependencies point **down only**: `tiny-lasers ← {cli, nexus, compilers} ← {autopoet, cloud}`, and
**nothing** may depend on `experiments/`. A CI job greps for upward imports/path-deps and **fails the
build** — so `nexus` can never `import`/path-dep `cloud` or `autopoet` again. This is the anti-fusion
lock; without it the mess returns.

## Status

- ✅ **Phase 1 — experiments/ carved** (commit `7760136f`): autopoet-chamber, templates, sites, scratch,
  the stray `nexus/*.exs` spikes → `experiments/` + AGENTS.md. nexus green.
- ✅ **Phase 2 — reactor/ → cli/** (commit `7cc872a6`): all path refs updated, `stage-reactor.sh` →
  `stage-cli.sh` + callers, `.zig-cache` dropped. nexus + toolchain_test green.
- ⏳ **Phases 3–6 below** — deploy-critical; execute WITH build/deploy verification (not blind).

---

## Phase 3 — lift `compilers/` out of `nexus/` (needs Docker verification)

`nexus/compilers/` (7.2G) → `compilers/`. **Gotchas found:**
- `Nexus.Compilers.Shared.default_root/0` resolves `"compilers"` **relative to CWD** (nexus/compilers in
  dev, /app/compilers in prod). Moving it up breaks dev resolution → add `"../compilers"` to its search.
- The runtime image does NOT COPY `nexus/compilers` directly — it pulls a **separate compilers image
  layer** (`dogfood/deploy/Dockerfile.base`: `FROM ${COMPILERS_REF} AS compilers`, built by
  `.github/workflows/compilers-image.yml`). Repoint that workflow's build context `nexus/compilers` →
  `compilers/`; the Dockerfile `COPY --from=compilers /compilers/kits` is unaffected.
- Hardcoded `/app/compilers` refs in `lib/wasmer.ex` (dev branch `Path.join(cwd, "compilers/…")`) — fine
  if default_root is fixed. `lib/workspaces.ex:178` skip-list has `compilers`/`compilers-dist` (keep).
  `lib/migrate.ex` + `lib/compilers/rust.ex` mentions are comments.
- **Verify:** `mix compile`, a compile-lane test with the toolchain present, AND a Docker image build.

## Phase 4 — absorb `autopoet` into the repo (needs autopoet build verification)

`../autopoet` (a SEPARATE git repo, path-deps `{:nexus, path: "../workbooks/nexus"}`) → `autopoet/`.
- **History decision:** `git subtree add` to preserve autopoet history, OR copy files (history stays in
  the standalone `../autopoet/.git`). User said history-in-git-somewhere is fine → copy is acceptable.
- Flip the path-dep → `{:nexus, path: "../nexus"}`. Check autopoet's own deps/submodules.
- **Verify:** `cd autopoet && mix deps.get && mix compile` against the local nexus.

## Phase 5 — extract `cloud/` out of `nexus/lib` (THE BIG ONE — needs full-suite + deploy verification)

Move the cloud-specific modules out of the generic runtime (enforce "the line"):
- **Modules:** `nexus/lib/{cloud,control_plane,platform,fly,polar,telnyx,cloudflare}.ex` +
  `nexus/lib/cloud/` + `nexus/lib/control_plane/` + `nexus/deploy/control-plane/` + the cloud surfaces in
  `dogfood/cloud/` → a new `cloud/` mix app that path-deps `nexus`.
- **Rewire:** `nexus/lib/server.ex` `forward("/api/platform", …)` + `forward("/api/cloud", …)` — the
  router must call into the `cloud` app (or cloud registers routes into nexus via a documented seam).
- **Tests:** ~10 files move with it (`control_plane_*`, `platform_http_*`, `cloud_*`, `broker_*`, …).
- **Deploy:** `WB_CONTROL_PLANE` currently makes `wb-dogfood` an all-in-one; decide whether `cloud/` is a
  separate release (`wb-nexus-cp`) or stays bundled. (See the earlier all-in-one vs split analysis.)
- **Verify:** full test suite + a deploy smoke (`/health`, `/api/platform`, `/api/cloud`).

## Phase 6 — rewrite CI per product root + add the DAG-check

One workflow per root (a change to `cloud/` never rebuilds `autopoet/`), + a `check-deps` job that fails
on any upward dep. Recover the **old cloud-infra dashboard** from git history (`git log --all --oneline`
for the earlier vanilla cloud UI) as the seed for the new `cloud/` mgmt UI.

## Recovery

`git checkout pre-restructure` restores the exact pre-restructure tree. Every phase is its own commit.
