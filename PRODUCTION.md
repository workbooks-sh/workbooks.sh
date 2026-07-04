# Workbooks Cloud — production push: status + backlog

**Done** = shipped + verified. **Earmark** = stubbed/pending/needs-external. The source of truth for this push.

## ✅ Done + verified
- **Real autopoet cloud machine** — `registry.fly.io/autopoet:v1` (92 MB, ML-free) builds, provisions, boots
  clean, and the health check **passes**. Fixed: Dockerfile (tiny-lasers + Rust), `AUTOPOET_TARGET=cloud`
  drops the desktop ML stack + `:wx` + GUI (→ `desktop_ml/`, cloud uses `cloud_stubs/`), dedup'd release mix
  tasks, `WB_SESSION_SECRET` injection, nexus↔autopoet port split (4000/8080), health check → `/status`.
- **`invalid_tenant` + provisioning** — org-id → Fly-safe slug; end-to-end via AutoPoet panel → `/cloud/deploy`.
- **Public repo** — `github.com/workbooks-sh/autopoet`, Apache-2.0, `main` (no secrets; `.env`/`data` never tracked).
- **Dev-only login** — `WB_LOGIN_ALLOWLIST` gate on signup/login/token; login UI is sign-in-only (no signup/demo).
- **TinyLasers-primary JS** — `Nexus.Config.js_runtime` + `Nexus.JsEngine` fallback to wasmex (config option).
- **New dashboard is `dogfood/cloud`** (deployed surface); old Studio → `experiments/old-studio-cloud`.
- **Billing** — Polar sandbox: real plan + AI-credit checkout.

## 🎯 app.workbooks.sh deploy — remaining (have creds now)
Dev account: **sha@shinyobjectz.com / bendolive427** · Cloudflare via **wrangler** · zone `workbooks.sh`.
1. **Rebuild `dogfood-base`** (new nexus: auth allowlist, js_engine, fly.ex) — heavy (nexus + `compilers` base).
   The thin `dogfood/deploy/Dockerfile` (COPY dogfood) then carries the new dashboard + login UI.
2. **`fly deploy -a wb-dogfood`**.
3. **Prod Secrets on wb-dogfood**: `WB_LOGIN_ALLOWLIST=sha@shinyobjectz.com`, `WB_SESSION_SECRET`,
   `WB_ENV_MASTER_KEY` (real), `POLAR_*`, `COMPOSIO_API_KEY`, `FLY_ORG_TOKEN`, `FLY_ORG_SLUG`.
4. **Seed** the dev account (sha@… / bendolive427).
5. **app.workbooks.sh** — wrangler: CF SaaS custom hostname + `fly certs add app.workbooks.sh`.

## 📋 New feature asks (earmarked — beyond the deploy critical path)
- **Cloudflare AI Gateway for ALL LLM** — route every autopoet LLM call (local + cloud) through OUR CF AI
  Gateway, not OpenRouter/Groq directly. Config in Nexus (`Nexus.Llm`/`Nexus.Inference`): a gateway base-URL
  + key, provider-agnostic. **Blocks a functional cloud brain** (the machine has no provider keys today) — high
  priority among the features.
- **Voice architecture** — CONFIRMS the split I built: **local = Kokoro (TTS) + Moonshine (STT)** (kept in
  `desktop_ml/`, work locally); **cloud = none** (stubbed). Groq for voice (cloud, maybe Cerebras later) is a
  later add. Telephony = messaging-only for now, so cloud voice isn't blocking.
- **AutoPoet CLI** — a simple CLI to manage an autopoet nexus by its deploy config (so Claude Code / a human can
  drive a local or cloud nexus). Could extend the `work` CLI or a thin `autopoetctl` wrapper over `/api/cloud`.
- **Nexus switching** — pick/switch which nexus you're in (local ↔ cloud) via the dashboard + CLI.
- **Local micro-VMs (libkrun failsafe)** — LOCAL-ONLY: let the agent run a **micro-VM** (libkrun/hypervisor,
  framework-agnostic) as a failsafe for builds outside Wasmtime's scope. NOT shipped to cloud. Needs a name +
  context docs on how/why; "micro-VMs / compute terminals" is fine. New capability, real scope.

## 🧹 CI / hardening earmarks
- **tiny-lasers warnings** — pre-existing (`wasm/actor.ex`, `transpile.ex`: ungrouped clauses, unused vars);
  fix or scope `--warnings-as-errors` before calling CI fully green.
- **Dedicated `/health`** route on Autopoet.Control (currently health-checks `/status`) — next image build.
- **autopoet local `main`** is stale vs the pushed `main` (force-pushed the real work) — reconcile local.
- **Data explorer** real backend (registry + per-tenant path + JSON codec), **Channels/Telnyx**, **sandbox.ex →
  TinyLasers (wb-5te7)** — all still open.
