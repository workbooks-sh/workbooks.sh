# Workbooks Cloud — control plane

A SUPER-SIMPLE control plane that vends each customer their own Fly.io machine running the **autopoet**
BEAM app, plus a whitelabeled **Composio** tools layer. It is the stripped-down **twin** of the dogfood
cloud manager (`Nexus.Provisioner` + `Nexus.Platform` + `Nexus.ControlPlane`): same seams, narrower
surface, autopoet-shaped machine config.

## What it borrows (nothing reinvented)

| Concern | Reused from | How |
| --- | --- | --- |
| Fly REST client | `Nexus.Fly` | Audited, TLS-pinned, token-never-logged, `opts[:http]`-injectable. Added 4 verbs: `create_volume`, `update_machine`, `suspend_machine`, `wait_machine`, plus optional `network` on `create_app` (all backward-compatible). |
| Secret seam | `Nexus.Secrets` | `FLY_ORG_TOKEN` / `COMPOSIO_API_KEY` / `AUTOPOET_IMAGE` / `FLY_ORG_SLUG` resolve store-first-then-env. Never `System.get_env`. |
| Durable registry | `Nexus.ControlPlane` (+ `.Store`, SQLite/Litestream) | Tenant record keyed `{tenant, :cloud_tenant, tenant}` — the tenant id **is** the isolation scope, so cross-tenant reads are structurally impossible (same contract as the fleet control plane). |
| No-op-safe seam | `Nexus.Google.configured?/0` | Composio broker mirrors it verbatim (`x-api-key` instead of a bearer JWT). Fly broker gates the same way. |
| HTTP API shape | `Nexus.Platform` | `Plug.Router`, `require_control_plane` (404 when not the CP role) + `require_org` (403 under `Nexus.Auth.None`) copied verbatim; `tenant = conn.assigns[:tenant]`. |
| Per-machine hardening | `Nexus.Provisioner` | Fresh random `WB_PUBLIC_BEARER` per provision (never stored in the registry). |

## Shape chosen: thin broker, desktop-first (and why)

The cloud UI isn't ready, so the **autopoet desktop** is the client. The brokers hold the high-value
tokens (`FLY_ORG_TOKEN`, `COMPOSIO_API_KEY`) server-side; the desktop only ever calls `/api/cloud/*` and
never sees a credential. This mirrors how the existing dashboard calls `/api/platform/*`. When a cloud UI
or a Workbooks-Cloud account/OAuth provider lands, it just sets `conn.assigns[:tenant]` (the same auth
seam `Nexus.Platform` uses) — nothing else changes. That is the single slot where account identity plugs
in; it is deliberately **not built yet**.

## Modules

- `Nexus.Cloud` — orchestrator + persistence. `provision/2` (idempotent, one machine per tenant),
  `get/1`, `status/2`, `start|stop|suspend/2`, `update_image/3`, `teardown/2`; tools: `list_tools/1`,
  `create_tool_auth_config/3`, `connect_tool/3`, `tool_status/2`, `tool_mcp_url/3`.
- `Nexus.Cloud.Fly` — Fly broker (pure Fly, no persistence). `provision/2` = create app (dedicated
  6PN) → volume → machine (autopoet image, `autostop:suspend`+`autostart:true` scale-to-near-zero,
  `/data` mount, `/health` check) → wait `started`. Lifecycle + `update_image` (GET → swap
  `config.image` → full re-POST) + `teardown` (destroy machine → delete app, cascades volume).
- `Nexus.Cloud.Composio` — whitelabel tools broker. `list_toolkits`, `create_auth_config`
  (`use_custom_auth` OAUTH2 → `ac_…`, our brand on consent), `connect` (→ `redirect_url`),
  `connection_status`, `mcp_url` (per-user `…/v3/mcp/{server}?user_id=`).
- `Nexus.Cloud.Api` — the desktop-facing `Plug` mounted at `/api/cloud` (`Nexus.Server` forward).

## Desktop → control-plane API surface (`/api/cloud/*`)

Machine (scoped to the caller's tenant):

```
POST   /api/cloud/provision                    → provision (or return) this tenant's machine
GET    /api/cloud/machine                       → { record, machine } (registry row + live Fly status)
POST   /api/cloud/machine/start|stop|suspend    → lifecycle
POST   /api/cloud/machine/image  {image}        → roll to a new immutable image tag
DELETE /api/cloud/machine                        → teardown
```

Whitelabeled tools (Composio):

```
GET    /api/cloud/tools                          → list toolkits
POST   /api/cloud/tools/auth_config              → register OUR whitelabel OAuth client  (ADMIN)
                                                    {toolkit, client_id, client_secret, redirect_uri} → { id: "ac_…" }
POST   /api/cloud/tools/connect  {auth_config_id} → start a connection → { redirect_url }
GET    /api/cloud/tools/connection/:id           → poll status (…"ACTIVE")
GET    /api/cloud/tools/mcp?toolkits=github,gmail → this tenant's per-user MCP URL
```

Result mapping: `{:ok}`→200/201, `{:skip}`→**503** (token not configured — feature dark),
`{:error, :not_found}`→404, `{:error, _}`→422.

## Done vs stubbed

**Done (real, tested no-network):** Fly provision/lifecycle/update/teardown; per-app volume + 6PN
network; autopoet machine config; Composio whitelabel/connect/status/mcp; tenant persistence + isolation;
no-op-safe gating; the `/api/cloud` API + guards. 30 tests, all injecting `opts[:http]` — zero network,
green with zero secrets.

**Stubbed / deferred (where it slots):**
- **Workbooks-Cloud accounts / OAuth provider** — not built. Identity comes from `conn.assigns[:tenant]`
  (the existing auth seam). Slot: set that assign from the new account system; no broker changes.
- **Routing** — machines are reachable at `cust-<tenant>.fly.dev` via the service definition. A router
  app + `fly-replay` (the "cleaner" option) is deferred.
- **Tigris/S3 durable mirror** — volumes aren't HA; a durable mirror of tenant state is noted in the arch
  but not wired here (autopoet's own persistence/backup is the desktop side's concern).
- **`update_image` rollout policy** (canary/batch), usage/billing metering, and quota admission — deferred
  (the fleet plane's `Nexus.Capacity`/`Nexus.Pricing` are the reuse targets when needed).

## Decisions to confirm

1. **Token name** — this twin uses `FLY_ORG_TOKEN` (per the plan); the existing fleet `Nexus.Fly` path
   uses `FLY_API_TOKEN` via `Nexus.Broker`. If they should be the SAME org token, point both at one name.
2. **Default image** — `registry.fly.io/autopoet:v1` (override via `AUTOPOET_IMAGE` secret or `opts[:image]`).
   The arch bans `:latest`; confirm the version pin / promotion flow.
3. **Tenant = Composio `user_id`** — one stable identity per tenant. Confirm that's the desired mapping
   (vs a separate per-account id).
4. **App naming** — `cust-<tenant>`; tenant validated to a DNS-safe label (`[a-z0-9-]`, ≤48 chars).
