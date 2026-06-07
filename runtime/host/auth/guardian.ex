defmodule Workbooks.Auth.Guardian do
  @moduledoc """
  Validates BetterAuth-issued JWTs (AUTH.org). BetterAuth's jwt plugin signs
  RS256 tokens whose public keys live at its JWKS endpoint (GET /api/auth/jwks);
  this runtime verifies them and extracts the tenant.

  Claims: `sub` (user), `organizationId` (tenant), `sessionId`, `exp`, `iss`.
  The tenant is `organizationId`, falling back to `sub` for solo users.

  Two verification modes, resolved from env at boot (`config/0`):
    * RS256 via `WB_JWKS_URL` — production (BetterAuth gateway).
    * HS256 via `WB_AUTH_SECRET` — local testing, mint+verify with no live gateway.
  """
  use Guardian, otp_app: :workbooks

  @impl true
  def subject_for_token(%{user_id: id}, _claims), do: {:ok, id}
  def subject_for_token(sub, _claims) when is_binary(sub), do: {:ok, sub}
  def subject_for_token(_, _), do: {:error, :no_subject}

  @impl true
  def resource_from_claims(claims) do
    {:ok,
     %{
       user_id: claims["sub"],
       tenant_id: claims["organizationId"] || claims["sub"],
       session_id: claims["sessionId"]
     }}
  end

  @doc """
  Resolve Guardian config from env. RS256/JWKS for prod (verified against the
  BetterAuth JWKS via `Workbooks.Auth.SecretFetcher`), HS256 secret for local.
  The SecretFetcher reads `WB_JWKS_URL` at verify time, so both modes share one
  config; `secret_key` is the HS256/signing secret.
  """
  def auth_config do
    base = [
      issuer: System.get_env("WB_AUTH_ISSUER", "betterauth"),
      ttl: {1, :hour},
      secret_fetcher: Workbooks.Auth.SecretFetcher
    ]

    case {System.get_env("WB_JWKS_URL"), System.get_env("WB_AUTH_SECRET")} do
      {url, _} when is_binary(url) -> [allowed_algos: ["RS256"]] ++ base
      {_, secret} when is_binary(secret) -> [secret_key: secret, allowed_algos: ["HS256"]] ++ base
      _ -> [secret_key: "dev-insecure-hs256-secret", allowed_algos: ["HS256"]] ++ base
    end
  end

  @doc "Install the resolved config into application env. Called at boot."
  def install_config, do: Application.put_env(:workbooks, __MODULE__, auth_config())
end
