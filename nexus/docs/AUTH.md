# Auth + multi-tenancy

Authentication and tenant isolation are a **standard nexus offers**, not bespoke per-deployment.
Two layers:

1. **Data partition** (`Nexus.Store`) — every row is keyed by **tenant**; one tenant can never read,
   count, or clear another's rows. Enforced *in the store* (ETS keys `{id, tenant, row}`; SQLite a
   `tenant` column with `WHERE tenant = ?`), not hoped for upstream. Single-tenant = everyone on
   `"default"`.
2. **Authentication** (`Nexus.Auth`) — a Plug + behaviour that resolves each request to a tenant via
   a swappable adapter, assigns `:tenant`, and the partitioned store does the rest.

So single-tenant and multi-tenant are the *same machinery* — you pick an adapter.

## Pick an adapter

```elixir
config :nexus, auth: Nexus.Auth.None     # default
```

| Adapter | Use | How |
|---|---|---|
| `Nexus.Auth.None` | local / dev / single-tenant (default) | no auth; everyone is `"default"` |
| `Nexus.Auth.Bearer` | single-tenant lock | shared `NEXUS_DATA_TOKEN` → fixed `NEXUS_TENANT` |
| `Nexus.Auth.Jwt` | **multi-tenant** | verify a Bearer JWT, tenant from a claim |

## The JWT adapter — one path for every provider

WorkOS, Clerk, Auth0, BetterAuth, or your own — they **all issue JWTs**. You configure verification
and which claim is the tenant; the adapter does the rest (signature, `exp`, optional `iss`).

```elixir
config :nexus, auth: Nexus.Auth.Jwt
config :nexus, Nexus.Auth.Jwt,
  # ONE of:
  jwks_url: "https://your-tenant.workos.com/.well-known/jwks.json",  # RS256 (WorkOS/Clerk/Auth0)
  secret:   "shared-hs256-secret",                                   # HS256 (BetterAuth/own)
  # claim mapping:
  tenant_claim: "org_id",   # which claim carries the tenant (required)
  user_claim:   "sub",
  issuer:       "https://your-tenant.workos.com"   # optional iss check
```

- **RS256 / JWKS** — the public keys are fetched over verified TLS and cached, re-fetched once on a
  `kid` miss (key rotation). The token's `kid` picks the key.
- **HS256 / secret** — symmetric, for roll-your-own / BetterAuth.

Provider → `tenant_claim`: WorkOS `org_id`, Clerk `org_id`, Auth0 a namespaced `org`/`https://…/org`,
BetterAuth/own whatever you put in the token. **Bring your own provider** behind the same
`authenticate/1` contract — implement a module, set `config :nexus, auth: MyAdapter`.

## What it protects

- `GET /data/:resource` returns **only the request's tenant's rows** (Store-partitioned).
- The SSR shell at `GET /` is `bake: false` in multi-tenant mode — the shared/cached HTML inlines
  **no data**, so it can never carry one tenant's rows to another; each client fetches its own
  tenant-scoped `/data`. (Single-tenant bakes the default tenant, as a local file does.)
- No valid credential → `401`.

## Proven

`test/auth_test.exs` (adapters + JWT verify: valid / wrong-secret / expired / no-tenant-claim) and
`test/server_test.exs` (end-to-end: two JWTs through the live server each see only their own rows;
no JWT → 401; Bearer gate). The Store isolation itself is proven in `test/sqlite_store_test.exs`.

## Still deployment-specific (not nexus's to decide)

- **Mapping users → tenants/orgs** lives in your identity provider (WorkOS orgs, Clerk orgs, etc.).
  nexus reads the tenant from the verified token; *who* belongs to *which* tenant is the provider's job.
- **Roles / fine-grained authz within a tenant** (beyond tenant isolation) is an app concern — add it
  in a workbook or a custom adapter that puts roles in the identity and gates on them.
- **A write endpoint** (`POST /data`) isn't built yet; when added it must run `Store.create` (shape +
  enum validation) under the request's tenant.
