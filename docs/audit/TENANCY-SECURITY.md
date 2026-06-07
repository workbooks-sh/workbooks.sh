# Workbooks Engine — Multi-Tenant Security Model & Validation Gate

> Status: AUDIT (read-only). Security-critical. All claims cite `file:line` verified
> against the repo at `/Users/shinyobjectz/Apps/workbooks` on 2026-06-04.
> Live cell `bn-engine` runs `WB_TENANCY_MODE=multi`, `ISOLATION=pool`,
> `MODEL=organization`, authed by the **static** `WB_PUBLIC_BEARER`.

---

## 0. Executive summary (15 lines)

1. The engine has a **correct** secure mechanism: `TenantToken` — HMAC-SHA256, tenant
   baked into a tamper-proof payload, key `WB_TENANT_TOKEN_KEY` (`tenant_token.ex:33-69`).
2. It is **not used** today: the live cell authenticates with the static
   `WB_PUBLIC_BEARER`, which binds **no** tenant (`auth_plug.ex:60-67`).
3. **GAP #1** — a static-bearer request leaves `conn.assigns[:tenant] = nil`; tenant then
   falls back to a client-asserted body/header field → spoofable (`auth_plug.ex:65`).
4. **GAP #2** — `gitwork_controller` push/pull/share read tenant **only** from
   `params["tenant_id"]`, never `conn.assigns[:tenant]` (`gitwork_controller.ex:214-218`).
   Even a valid TenantToken is ignored on these routes.
5. `agent_controller` is the correct pattern: `conn.assigns[:tenant] || params["tenant_id"]`
   (`agent_controller.ex:49`) — but it still accepts a body fallback when no token binds.
6. `ISOLATION=pool` is **not enforced** anywhere at the storage layer (`tenancy.ex:26-28`);
   it is a stored atom only. Separation depends 100% on correct tenant derivation.
7. `gitwork :local` is **structurally unsafe**: path is keyed by repo name only, never
   tenant (`local.ex:20-24`, `gitwork.ex:41`, `application.ex:198`).
8. `gitwork :r2` defaults `tenant_id` to the **shared** string `"local"` when none supplied
   (`r2.ex:166-171`) — so GAP #2 collapses every tenant into one prefix.
9. The live caller (brandnana CLI) uses static bearer + spoofable `X-Tenant-Id` **and**
   `backend:"local"` (`substrate-publish.ts:111-126`) — the worst combination.
10. The deploy-kit gate **exists** in Rust (`deploy.rs:740` `coherence_errors`), runs
    **before** any secret is pushed (`apply_deployment` → coherence → recipe).
11. It already blocks `STORAGE=local-fs` + `AUTH=trusted/empty` under multi
    (`deploy.rs:786-791`) — but **misses** the isolation-critical rules.
12. `WB_AUTH`/`WB_ISSUER` are declarative-only: never forwarded to the engine
    (`common.sh:41-107` omits them) — so `AUTH=workos` is metadata, not enforcement.
13. The worker minter (`mintTenantToken`/`engine-client.ts`) **does not exist**
    (repo-wide grep: 0 hits); worker `env.ts` has no engine binding.
14. `WB_TENANT_TOKEN_KEY` IS minted by the deploy-kit (`common.sh:60`) and IS live on
    bn-engine — so the engine **can** verify HMAC tokens today; only a minter is missing.
15. **Net:** no storage backend is multi-tenant-safe on the live cell until GAP #1 (auth
    binds tenant), GAP #2 (gitwork prefers bound tenant), and the minter are all closed —
    AND `:local` is removed as a multi-mode write backend regardless.

---

## 1. THE SECURE MODEL (apply this without being an expert)

**The one rule:** *The tenant must be derived from something the client cannot forge.*
The only forgery-proof source in this engine is a **TenantToken** — the tenant is signed
into the bearer with a server-held key. A request body field, a query param, or an
`X-Tenant-Id` header is **client-asserted** and must never decide which tenant's data is
touched in multi mode.

### Roles of each auth artifact

| Artifact | What it proves | Binds a tenant? | Role |
|---|---|---|---|
| `WB_PUBLIC_BEARER` (static) | "You may talk to this cell" | **No** (`auth_plug.ex:65`) | Coarse gate **only**. Acceptable as the *sole* auth in **single** mode; **forbidden as the tenant source** in **multi** mode. |
| `TenantToken` (HMAC) | "You are tenant X, until `exp`" | **Yes** (`auth_plug.ex:62-63` → `tenant_token.ex:53-64`) | The tenant source in multi mode. Minted per-request by a trusted party (worker/CLI) from a tenant already authenticated upstream (WorkOS). |
| `params["tenant_id"]` / `X-Tenant-Id` | Nothing — client-asserted | n/a | **single** mode: ignored (`tenancy.ex:76-77`). **multi** mode: must be ignored when a token is present; never the sole source. |

### SINGLE mode (desktop / personal / cloud-test)

- Engine pins every request to `default_tenant` (`"local"`); any supplied `tenant_id` is
  **ignored** (`tenancy.ex:74-85`). There is only one tenant, so there is nothing to spoof.
- The static `WB_PUBLIC_BEARER` is sufficient and correct. `:local` gitwork + bare sqlite
  are safe **because there is only one tenant on the machine**.

### MULTI mode (saas / brandnana)

Required, all of them:
1. **A tenant-token-capable auth path.** `WB_TENANT_TOKEN_KEY` present on the engine (it is)
   **and** an actual minter wired into every client (it is **not** — §3.4).
2. **The engine derives tenant from `conn.assigns[:tenant]`** (the verified token), never
   from the body, on **every** tenant-touching route. Body fallback is allowed only when
   `conn.assigns[:tenant]` is nil **and** the route is non-isolation-critical — and even
   that should be removed for multi (§3.1).
3. **Every selected storage backend is tenant-keyed.** Because `ISOLATION=pool` shares the
   FS/VM with no silo backstop (`tenancy.ex:26-28`), a single unscoped path is a full
   cross-tenant breach. `:local` gitwork and bare sqlite are **not** tenant-keyed → banned
   as the multi write/default path.
4. **The static bearer must not be a tenant oracle.** In multi mode a bare static-bearer
   request (no token → no bound tenant) must be **rejected**, not allowed to fall back to a
   body field.

> **Posture warning.** `topology.org:62-68` documents a *silo-per-app* model (one Fly app +
> one volume per tenant) where storage sharing is a non-issue. The **live** cell is the
> opposite — one app, `multi`+`pool`, `WB_DATA_ROOT=/tmp/wb`, `min_machines_running=1`
> (`fly.bn-engine.toml:9,26,35`). The matrix below is for the **live** posture. Do not lean
> on the silo backstop the topology doc assumes; it is not what is deployed.

---

## 2. THE VALIDATION MATRIX (what the deploy-kit must enforce)

Rows = storage backend. Columns = posture. Cell = verdict + one-line reason.
**SAFE-IF-AUTH** = path is tenant-keyed but only safe once GAP #1 + GAP #2 are closed
(auth binds the tenant AND the controller uses the bound tenant).

| Storage backend | single | multi + pool (live) | multi + silo (per-app) | Evidence |
|---|---|---|---|---|
| **gitwork `:local`** | SAFE — one tenant | **UNSAFE** — path keyed by repo name only, no tenant segment, ever | SAFE — one tenant per app | `local.ex:20-24`; `gitwork.ex:41,69`; `application.ex:198` |
| **gitwork `:r2`** | SAFE | **SAFE-IF-AUTH** — key `…/tenant/<t>/…` is tenant-keyed + sanitized, BUT defaults tenant to shared `"local"` when none supplied → UNSAFE under GAP #2 | SAFE | `r2.ex:126-138` (key+sanitize), `:166-171` (default `"local"`) |
| **gitwork `:radicle`** | SAFE | **SAFE-IF-AUTH** — per-tenant `RAD_HOME`; safe only if tenant value is authentic | SAFE | `radicle.ex:8-12,36-38` |
| **git_host `Disk`** | SAFE | **WARN** — tenant-keyed path, but EPHEMERAL on `/tmp/wb` (data loss on restart); isolation SAFE-IF-AUTH | SAFE (on volume) | `disk.ex:118-129,169`; `fly.bn-engine.toml:26` |
| **git_host `S3`** | SAFE | **WARN** — tenant-keyed + durable, but needs per-tenant single-writer pinning; silent lost-write at >1 machine | SAFE | `s3.ex:32,360-366` |
| **`WB_DATA_ROOT` (shared FS)** | SAFE | **CONDITIONAL** — safe iff every consumer path is tenant-scoped; UNSAFE today (`:local` + sqlite are not) + ephemeral on `/tmp` | SAFE (per-tenant volume) | `data_root.ex`; `application.ex:198`; `database/config.ex:110-113` |
| **`WB_DATABASE` sqlite** | SAFE | **WARN/UNSAFE** — single-writer file, no tenant segment; isolation only if every query is app-tenant-filtered (unverified) | SAFE | `database/config.ex:70-92,110-113` |
| **`WB_DATABASE` postgres/split** | SAFE | **WARN** — shared `:global` store; tenant separation must be in-schema, not storage-enforced | SAFE | `database/config.ex:89-90` |

**The gate must, under `TENANCY_MODE=multi`, hard-ERROR when:**
- default/write gitwork backend is `:local` (unscoped shared dir). *Today only a federation
  WARN at `deploy.rs:1318-1322`.*
- `AUTH` is the static-bearer posture (`shared-key`/empty) with no tenant-token path — i.e.
  there is no per-tenant issuer. *Today `multi_requires_real_auth` (`deploy.rs:789`) only
  blocks `trusted`/empty, so `shared-key` passes.*
- `WB_TENANT_TOKEN_KEY` will not be present (positive assertion, not a silent default).

**The gate must WARN when, under multi:**
- `WB_DATA_ROOT` is ephemeral (`/tmp`, no volume) → silent data loss + shared mutable FS.
- `GITWORK_HOST_BACKEND=s3` and topology can run >1 machine without per-tenant sticky
  routing → lost-write risk (`s3.ex:32`).
- `DATABASE=sqlite` → reframe the existing scale WARN (`deploy.rs:1335-1338`) to name the
  **isolation** gap, not just `SQLITE_BUSY`.

---

## 3. THE FIX PLAN (ordered, discrete, file:line)

> P0 = closes a live cross-tenant breach. Order is dependency-correct: engine controller
> fixes (3.1, 3.2) are independent of the minter and must land first.

### 3.1 — P0 · Engine: gitwork_controller must prefer the bound tenant (closes GAP #2)
`runtime/engine/lib/workbooks_runtime/api/gitwork_controller.ex:214-218`. `build_opts/2`
derives tenant solely from `params["tenant_id"]`. Mirror `agent_controller.ex:49`: thread
`conn` into `build_opts`, derive `conn.assigns[:tenant] || params["tenant_id"]`, then route
through `WorkbooksRuntime.Tenancy.resolve_tenant/1` (so multi-mode rejects a missing
tenant). Apply to all three callers: push (`:86`), pull (`:108`), share (`:132`). Without
this, even a valid TenantToken is ignored and any token-holder can read/write any tenant's
ref via the body field.

### 3.2 — P0 · Engine: require the TenantToken path in multi mode (closes GAP #1)
`runtime/engine/lib/workbooks_runtime/api/auth_plug.ex:45-67`. Today `assign_tenant/1`
silently passes a static-bearer request through with `conn.assigns[:tenant]` unset
(`:65`). Add: when `WorkbooksRuntime.Tenancy.multi_tenant?()` is true AND the verified
bearer is the static `:api_token` (not a TenantToken), **reject** (401/403) — a bare static
bearer must not reach a tenant-touching route in multi mode. Keep the static bearer valid
in single mode and for non-tenant routes (`/api/about`, health). This removes the body-
fallback oracle at its root.

### 3.3 — P1 · Engine: tighten agent_controller body fallback under multi
`runtime/engine/lib/workbooks_runtime/api/agent_controller.ex:49`. The precedence is
correct (`conn.assigns[:tenant] || params["tenant_id"]`), but with 3.2 in place the
`||` fallback becomes dead in multi (no static bearer reaches here). Make it explicit:
in multi mode, ignore `params["tenant_id"]` entirely (use only the bound tenant) so a
future regression in 3.2 cannot re-open a body channel. Audit sibling endpoints —
`sessions`/`board` lookups by global id and `user_socket.ex:20` channel auth — to confirm
they scope by the socket/bound tenant, not a global id. *(Flagged: I did not read the full
channel-join path; verify before asserting WS is unscoped.)*

### 3.4 — P1 · Worker: build the minter (`mintTenantToken` / `engine-client.ts`)
`projects/brandnana/apps/api/` — currently **absent** (grep: 0 hits; `env.ts` has no engine
binding). Implement `tenant_token.ex`'s exact wire format
(`tenant_token.ex:38-43`): `base64url(payload) "." base64url(HMAC_SHA256(key, p64))`,
payload `{"t":<tenant>,"exp":<unix>}`, **canonical fixed-order JSON, no whitespace**, key
`WB_TENANT_TOKEN_KEY`. Provision into worker CF secrets the **same** key value live on
bn-engine. The worker mints a fresh short-lived token (default 900s, `tenant_token.ex:26`)
per authenticated request, from the tenant established by WorkOS, and uses it as the engine
bearer for `/api/run` and `/api/gitwork/*`.

### 3.5 — P1 · CLI: migrate the live caller off the static bearer + `:local`
`projects/brandnana/apps/cli/src/commands/substrate-publish.ts:111-126`. It sends
`Authorization: Bearer ${WB_PUBLIC_BEARER}` + optional `X-Tenant-Id` (`:120-121`) and
`backend:"local"` (`:126`) — the structurally-unsafe combination. Switch to a minted
TenantToken bearer and a tenant-keyed backend (`:r2`); drop `X-Tenant-Id`.

### 3.6 — P0 · Deploy-kit gate: add the isolation-critical rules
`cli/wb/src/cmd/deploy.rs`, in `coherence_errors` at the existing multi block (`:779-792`)
— compile-time, **before** `provider_set_secrets` (`apply_deployment:470-480` rejects on
non-empty coherence errors *before* `exec_recipe:506`). This is the correct insertion
point; the bash recipe is downstream and cannot be the primary gate. Add as **hard errors**:
- **(a)** `AUTH ∈ {shared-key, ""}` under multi → ERROR. Require a per-tenant issuer
  (`workos|clerk|oidc-custom`) OR an explicit tenant-token posture. *(Extends
  `multi_requires_real_auth:789`, which only blocks `trusted`.)*
- **(b)** default/write gitwork backend `:local` under multi → ERROR. *(Promotes the
  federation WARN at `:1318-1322`.)*
- **(c)** Positive assertion that `WB_TENANT_TOKEN_KEY` will be present for multi (don't
  rely on the silent `common.sh:60` default).
Add as **warnings** (`coherence_warnings`): ephemeral `WB_DATA_ROOT` under multi (data
loss); `GITWORK_HOST_BACKEND=s3` + >1 machine without sticky pinning; reframe the sqlite
warning (`:1335-1338`) as isolation, not scale.

### 3.7 — P1 · Deploy-kit: make `WB_AUTH` honest (wire it or stop trusting it)
`deploy-kit/recipe/common.sh:41-107` never forwards `WB_AUTH`/`WB_ISSUER` to the engine,
and `runtime/engine` reads neither (grep: 0 hits) — so `AUTH=workos` is metadata while the
runtime still accepts the static bearer. Either (a) forward `WB_AUTH`/`WB_ISSUER` and have
the engine enforce them, or (b) until then, ensure the §3.6(a) rule does **not** treat
`AUTH=workos` as satisfying multi-tenant safety while the engine still accepts a bare static
bearer. The honest gate requires the tenant-token posture (key present + minter wired),
because that is the mechanism that actually binds a tenant.

### 3.8 — P2 · Engine `:local` tenant-keying (defense in depth)
`substrates/gitwork/elixir/gitwork/lib/gitwork/backend/local.ex:20-24` +
`application.ex:198`. Thread `tenant_id` into the Local path
(`local_root/<tenant>/<repo>`) like R2/Radicle. Even with the gate banning `:local` under
multi (3.6b), structurally tenant-keying it removes the footgun if the gate is ever bypassed.

---

## 4. ADVERSARIAL TEST PLAN (must be rejected/contained after the fix)

All against a **multi** cell. "Token-A" = a valid TenantToken minted for tenant `alice`.

| # | Request | Before fix (today) | After fix — MUST |
|---|---|---|---|
| T1 | `Bearer <static>` + body `{"tenant_id":"victim"}` → `POST /api/run` | accepted, runs as `victim` | **401/403** (§3.2 rejects bare static bearer in multi) |
| T2 | `Bearer <static>` + body `{"tenant_id":"victim"}` → `POST /api/gitwork/push backend:r2` | writes `victim`'s prefix | **401/403** (§3.2 + §3.1) |
| T3 | `Bearer <static>` + `X-Tenant-Id: victim` → `POST /api/gitwork/push` (live CLI shape) | writes `victim` (or shared `local`) | **401/403** |
| T4 | Token-A + body `{"tenant_id":"bob"}` → `POST /api/run` | uses `alice` (agent_controller correct) | uses **`alice`**, body ignored — **never `bob`** (§3.3) |
| T5 | Token-A + body `{"tenant_id":"bob"}` → `POST /api/gitwork/push` | uses **`bob`** (GAP #2 live) | uses **`alice`**, body ignored (§3.1) |
| T6 | Token-A + body `{"tenant_id":"bob"}` → `POST /api/gitwork/pull` of bob's ref | reads **`bob`** | reads only **`alice`**'s refs (§3.1) |
| T7 | Token-A, `backend:"local"`, `POST /api/gitwork/push` | writes shared unscoped dir | request **rejected** (`:local` banned in multi) OR confined to alice's path (§3.8) |
| T8 | Expired Token-A (`exp` in past) → any route | rejected (token path) | **401** (`tenant_token.ex:62`) |
| T9 | Token signed with wrong key → any route | rejected | **401** (`tenant_token.ex:58`) |
| T10 | Token-A with `t` = `../other` or odd chars | rejected at verify | **401** (slug regex, `tenant_token.ex:25,84`) |
| T11 | `wb deploy` of `multi` + `AUTH=shared-key` (or empty) | passes gate today | gate **exits non-zero** before secrets (§3.6a) |
| T12 | `wb deploy` of `multi` + gitwork default `:local` | only a WARN today | gate **exits non-zero** (§3.6b) |
| T13 | `wb deploy` of `multi` with `WB_TENANT_TOKEN_KEY` absent | silent default mint | gate **asserts present** or errors (§3.6c) |

Also assert single-mode is unchanged: a `single` cell with static bearer + body
`tenant_id:"anything"` must still pin to `default_tenant` and ignore the body
(`tenancy.ex:76-77`).

---

## 5. Uncertainties / flags (verify before asserting)

- **WS channel scoping (3.3):** `user_socket.ex:20` authenticates via token but I did not
  read the full channel-join/topic-authorization path. Whether channels scope by the bound
  tenant is **unverified** — confirm before claiming a WS cross-tenant gap.
- **App-layer DB tenant filtering:** sqlite/postgres provide no storage-layer tenant key.
  Whether every query is already tenant-filtered in app logic is **unverified** here; the
  matrix marks sqlite WARN/UNSAFE conservatively.
- **Live S3 wiring:** `fly.bn-engine.toml` comments claim durable S3-backed gitwork, but the
  TOML itself sets no `WB_STORAGE=s3` / S3 creds (those would arrive via the recipe env at
  apply time). Whether the live cell actually has an S3 store configured — and thus whether
  the default backend is `:r2` (`gitwork_controller.ex:211`) or `:local` — is **unverified**
  from static files alone; confirm with `fly secrets list`.
- **`broker_token_shape?` (`wbk_…`):** a separate, stubbed broker path
  (`auth_plug.ex:120-135`) that always 401s today — orthogonal to the HMAC TenantToken path
  and not part of this fix.
