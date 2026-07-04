# Workbooks Cloud — production push status + earmarks

Living doc for the "make it real in production" push. **Done** = shipped + verified. **Earmark** = stubbed,
pending, or needs an external credential/decision. Update as things land.

## Goals (from the mandate)
1. Replace the prod cloud app at **app.workbooks.sh** with the new UI; login locked to our dev account.
2. Remove the demo button; dev-user only.
3. Finish the **Nexus/autopoet cloud image** + verify whether the **desktop burrito bundle** is needed.
4. Fully production-ready, **clean CI**, proven with the dev user.
5. **TinyLasers dominant**; every core component instantiable locally + in the cloud, autonomously.
6. Sunset/archive unused; lander → Cloudflare for now (off Nexus).

## Done
- **JS runtime seam** — `Nexus.Config.js_runtime` (default `:tiny_lasers`), `Nexus.JsEngine` dispatches
  TinyLasers-first with wasmex fallback (cached viability probe; cloud JS → wasmex since Porffor needs node).
  wasmex is now a *secondary config option*, never hardcoded.
- **Dev-only login** — `WB_LOGIN_ALLOWLIST` gate on signup/login/`/auth/token`; login island is sign-in-only
  (removed signup toggle + demo button entirely).
- **Autopoet cloud image build** — Dockerfile fixed (tiny-lasers copy, Rust for wasmex); `AUTOPOET_TARGET=cloud`
  drops the desktop ML stack (bumblebee/exla/ortex/tokenizers) + `:wx` + the 5 ML modules + Window, using
  `cloud_stubs/`; `scripts/build-cloud-image.sh` stages a 219M pruned context. Fixed release blockers
  (duplicate mix tasks). **Build in flight** — reached `mix release` cleanly.
- **Real Fly provisioning** — `invalid_tenant` (org-id → Fly-safe slug) + machine port (→8080) fixed;
  a REAL machine was provisioned end-to-end (placeholder image) in the `autopoet-cloud` org.
- **New dashboard is now `dogfood/cloud`** (the deployed control-plane surface); old Studio archived to
  `experiments/old-studio-cloud`.
- **Billing** — Polar sandbox live: real checkout for plans + AI credits (token + products in Secrets).

## Earmarks — pending / needs external / stubbed
- **app.workbooks.sh domain** — workbooks.sh is on Cloudflare (`cf-saas-zone` in dogfood/index.work). Needs
  a Cloudflare SaaS custom-hostname + Fly cert → **needs a Cloudflare API token** (not found in env). Once
  supplied, add via `fly certs` + CF SaaS.
- **Prod Secrets on wb-dogfood** — set `WB_LOGIN_ALLOWLIST=<dev email>`, `WB_ENV_MASTER_KEY` (real, not the
  dev all-zeros), and copy `POLAR_*` / `COMPOSIO_API_KEY` / `FLY_ORG_TOKEN` / `FLY_ORG_SLUG` into the prod
  secret store. **Needs the real dev-account email/password** to seed + allowlist.
- **wb-dogfood redeploy** — rebuild the thin `dogfood/deploy` layer (base `ghcr.io/workbooks-sh/dogfood-base`)
  with the new tree + `fly deploy -a wb-dogfood`. Verify `dogfood-base` is current for the code changes
  (auth/js_engine) — if the base predates them, the base image needs a rebuild first.
- **Autopoet real machine** — once the image build pushes `registry.fly.io/autopoet:v1`, flip `AUTOPOET_IMAGE`
  in Secrets back off the placeholder + re-provision to run the REAL brain.
- **Desktop burrito bundle** — TBD whether needed for this push. Desktop packaging (burrito → Autopoet.app)
  is independent of the cloud/control-plane work; the cloud image is what runs on Fly. **Decision:** likely
  NOT needed for the production cloud goal — earmark unless the desktop distributable is in scope.
- **Voice/STT on cloud** — stubbed (`cloud_stubs/`: Dictate/Kokoro/Window return not_available). The headless
  cloud brain has no local ML; wire cloud voice later if wanted.
- **sandbox.ex** — still on wasmex (wasmtime component model); TinyLasers migration is the wb-5te7 epic.
- **Data explorer** — real tables need the resource registry + per-tenant read path + JSON codec (DATA.md).
- **Channels (Telnyx)** — no backend endpoints yet.
- **Clean-CI polish** — a pre-existing tiny-lasers warning (`@max_block_results` in transpile.ex); audit the
  full `mix compile --warnings-as-errors` across nexus/autopoet/tiny-lasers before calling CI green.
