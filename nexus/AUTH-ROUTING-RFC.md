# RFC: native auth + routing, compiled into publish

**Status:** draft (epic `wb-0uil`). **Scope:** the open standard — NEXUS (runtime) + REACTOR (compile).
NOT dogfood. Dogfood adoption is `wb-ajvy`, after this lands.

## Goal

Own the **Guardian** (JWT pipeline + per-route guards) and **BetterAuth** (batteries-included
sessions, OAuth/OIDC, email/password, tokens) concept *natively* — so that a workbook **declares** its
routes and auth policy in `.work`, and `work weave`/`work deploy` **compile** guarded, routed
endpoints plus the login/session/token machinery. The nexus enforces it at runtime. No bolted-on auth
library, no hand-wired route table: a published workbook is **authned + routed by construction.**

## THE LINE (non-negotiable)

The mechanism is generic. A deployer declares *which* providers and *which* routes; the standard ships
**no** provider, **no** keys, **no** our-business. WorkOS (ours) is just one configured provider; our
keys live in `Nexus.Secrets`, our provider choice in `Nexus.Config`. The test: *could any deployer get
auth+routing for their own app with their own providers and none of ours baked in?* Yes, by design.

## What exists today (the runtime half, partial)

`Nexus.Auth` (nexus/lib/auth.ex) is a Plug resolving each request → `{tenant, identity}` via a
pluggable adapter: `None` (default), `Bearer` (shared token→tenant), `Jwt` (verify HS256/RS256, take a
claim as tenant — "one adapter for WorkOS/Clerk/Auth0/BetterAuth"). Routing is **implicit**: `/<mount>/`,
`live/<source>`, `data/<resource>`. There are no declared routes and no per-route guards — auth is
all-or-nothing per request, and tenancy is the only thing derived.

This RFC extends that seam; it does not replace it. `authenticate/1 → {tenant, identity}` stays the
foundation; we add **sessions**, **login flows**, **token issuance**, **declared routes**, and
**per-route guards** on top, and we make the reactor emit the wiring.

## The `.work` declaration surface

Two new declarations, both compiled — the workbook author never writes plumbing.

### `auth do … end` — the policy

```
auth do
  session "cookie"                      # cookie sessions (default) | "bearer" (token only) | "both"
  provider :workos, kind: "oidc"        # a login provider; kind = oidc | oauth2 | password | token
  provider :google, kind: "oauth2"
  tenant_claim "org_id"                 # which verified claim becomes the Store tenant
  protect "/admin/**", role: "admin"    # route guards — path glob → required auth/role/scope
  protect "/api/**",   scope: "api"
  public  "/", "/pricing"               # explicitly public (else: authenticated by default once `auth` is declared)
end
```

- Providers name a flow; their **secrets/endpoints are config**, resolved at deploy via
  `Nexus.Config` (`auth-provider-workos-issuer=…`) + `Nexus.Secrets` (`WORKOS_CLIENT_SECRET`). The
  `.work` names the provider; it never holds a key.
- `protect`/`public`/default-deny is the **guard policy** — compiled into a match table the runtime
  checks before dispatch.

### `route` — explicit routes (beyond implicit live/data)

```
server :orders do
  route "GET  /api/orders"      , :list      # path+method → a function in this server unit
  route "POST /api/orders"      , :create
  def list(conn), do: …
  def create(conn), do: …
end
```

Implicit `live/<source>` + `data/<resource>` stay. `route` is for explicit HTTP handlers the author
wants — compiled into the same route table the guards attach to.

## Compile vs. runtime split

| Concern | REACTOR (compile, `weave`/`deploy`) | NEXUS (runtime) |
|---|---|---|
| Route table | parse `route`/implicit → emit an ordered match table (path,method,handler) | dispatch a request against it |
| Guards | parse `protect`/`public`/default → emit a guard table (glob→requirement) | enforce before dispatch (401/403) |
| Auth endpoints | emit `/auth/:provider/login`, `/callback`, `/logout`, `/token` for declared providers | serve them: redirect→provider, verify callback, mint session/token |
| Providers | record names + which config/secret keys they need (a manifest) | bind to `Nexus.Config`/`Nexus.Secrets` at boot; verify tokens (extends `Nexus.Auth.Jwt`) |
| Sessions | choose cookie/bearer/both | issue + verify (signed cookie / `wbk_`-style token), set `{tenant, identity}` |

The compiled output is **declarative data** (route + guard + provider manifests) the nexus reads — not
generated Elixir. Same spirit as the rest of weave: the `.work` is the source, the artifact is a table.

## Mapping onto `Nexus.Auth`

- `Nexus.Auth.call/2` gains a **guard step**: after `authenticate/1`, check the request path/method
  against the compiled guard table → allow / 401 (no identity) / 403 (identity lacks role/scope).
- A new `Nexus.Auth.Session` issues/verifies sessions (the BetterAuth half) and a
  `Nexus.Auth.Provider` drives OIDC/OAuth login (redirect + callback), minting a session whose claims
  flow through the existing `{tenant, identity}` contract. `Nexus.Auth.Jwt` stays the verifier.
- `@public_paths` becomes the *default* public set, unioned with the workbook's `public` decls.

## Security posture (must hold)

- Default-deny once `auth` is declared (opt-out via `public`, never opt-in-by-forgetting).
- Secrets never in `.work`/source/compiled output — only `Nexus.Secrets` at runtime.
- Signed, httpOnly, SameSite cookies; short-lived sessions + rotation; CSRF on cookie-session writes.
- Guard table is **fail-closed**: an unmatched protected glob denies; a malformed policy fails the
  weave (caught at compile, not runtime).
- Token issuance is audited; provider callbacks verify state + nonce.

## Phasing (the impl issues)

1. **`wb-4j90` Routing primitive** — `route` decl → compiled route table + nexus dispatch. (No auth yet.)
2. **`wb-2vh1` Auth provider runtime** — `Nexus.Auth.Session` + `Nexus.Auth.Provider` (OIDC/OAuth/
   password/token) + per-route guards, all config/secret-driven. Extends `Nexus.Auth`.
3. **`wb-dshz` Compile/publish wiring** — reactor emits route/guard/provider manifests + the auth
   endpoints; nexus binds them at boot.
4. **`wb-ajvy` (dogfood)** — rewire `dogfood/cloud`'s manual Bearer seam onto the native feature.

Each phase ships green + tested; security-sensitive bits get adversarial review before merge. Open
design questions (cookie vs token default, password-flow inclusion in v1, multi-provider precedence)
are flagged inline and decided per-phase.
