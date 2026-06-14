defmodule Workbooks.AuthIntegrations do
  @moduledoc """
  Phase 6 — **app-auth integrations**. The declarative surface that lets a tenant wire
  THEIR app's end-user auth to a provider — built-in (BetterAuth), a hosted IdP
  (Clerk / WorkOS / Auth0), or any OIDC issuer. This is the APP plane; it is a
  separate trust domain from the PLATFORM plane (WorkOS dashboard auth) — distinct
  issuers / JWKS / audiences, never a shared verifier (AUTH-LAYERING §4).

  The one genuinely new bit over the existing rungs is the **claim-map**: which JWT
  claim names the tenant (org) and the user, so a non-BetterAuth IdP that names the
  org differently still scopes correctly. Defaults match BetterAuth
  (`organizationId` / `sub`); a deployment overrides via `WB_TENANT_CLAIM` /
  `WB_USER_CLAIM`. `Workbooks.Auth.Guardian` reads these, so changing the provider is
  config, not code.
  """

  # The supported app-auth providers + how a deployment configures each. `oidc` is the
  # catch-all. All hosted IdPs are OIDC under the hood — the difference is just which
  # issuer/JWKS/claim names they use, captured by the claim-map.
  @providers [
    %{id: "builtin", name: "Built-in", kind: :builtin,
      blurb: "Workbooks' own end-user auth — nothing to configure."},
    %{id: "clerk", name: "Clerk", kind: :oidc,
      blurb: "Use Clerk for your app's users.", config: ~w(issuer jwks_url)},
    %{id: "workos", name: "WorkOS", kind: :oidc,
      blurb: "Use WorkOS AuthKit for your app's users.", config: ~w(issuer jwks_url)},
    %{id: "auth0", name: "Auth0", kind: :oidc,
      blurb: "Use Auth0 for your app's users.", config: ~w(issuer jwks_url)},
    %{id: "oidc", name: "Any OIDC provider", kind: :oidc,
      blurb: "Bring any OIDC issuer.", config: ~w(issuer jwks_url tenant_claim user_claim)}
  ]

  @doc "The supported app-auth providers (declarative; for the dashboard + docs)."
  def providers, do: @providers

  @doc "The active app-auth provider id (`WB_AUTH`, default `builtin`)."
  def active, do: System.get_env("WB_AUTH", "builtin")

  @doc "The JWT claim that names the TENANT/org (`WB_TENANT_CLAIM`, default `organizationId`)."
  def tenant_claim, do: System.get_env("WB_TENANT_CLAIM", "organizationId")

  @doc "The JWT claim that names the USER (`WB_USER_CLAIM`, default `sub`)."
  def user_claim, do: System.get_env("WB_USER_CLAIM", "sub")

  @doc "Resolve {tenant_id, user_id} from a verified claim set using the configured claim-map."
  def identity_from_claims(claims) when is_map(claims) do
    user = claims[user_claim()] || claims["sub"]
    tenant = claims[tenant_claim()] || user
    {tenant, user}
  end

  @doc "Public config snapshot for the dashboard / `/.well-known` (no secrets)."
  def config do
    %{active: active(), providers: @providers, claim_map: %{tenant: tenant_claim(), user: user_claim()}}
  end
end
