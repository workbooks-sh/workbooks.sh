defmodule Workbooks.OIDC do
  @moduledoc """
  OIDC / JWKS token verification — the identity-provider seam. A deployment points
  it at its provider's JWKS endpoint (WorkOS, Clerk, Auth0, or any RS256-JWT IdP):

    WB_OIDC_JWKS_URL     — the provider's JWKS endpoint (required to enable)
    WB_OIDC_ISSUER       — optional; if set, the token's `iss` must match
    WB_OIDC_TENANT_CLAIM — optional; which claim maps to the tenant
                           (default: org_id, then organization_id, then sub)

  Inert until WB_OIDC_JWKS_URL is set. `verify_token/2` accepts an explicit `jwks`
  so the verification path is testable without a live provider.
  """
  require Logger

  @doc """
  Verify an RS256 OIDC JWT against `jwks` (parsed `%{"keys" => [...]}`; fetched from
  WB_OIDC_JWKS_URL when nil). Returns `{:ok, tenant}` or `:error`.
  """
  def verify_token(token, jwks \\ nil) when is_binary(token) do
    case verify_claims(token, jwks) do
      {:ok, claims} ->
        case tenant_from(claims) do
          t when is_binary(t) and t != "" -> {:ok, t}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  Like `verify_token/2` but returns the FULL verified claims map (`sub`, `org_id`,
  `name`, …) — for callers that need the user identity, not just the tenant.
  `{:ok, claims}` or `:error`.
  """
  def verify_claims(token, jwks \\ nil) when is_binary(token) do
    with %{"keys" => _} = ks <- jwks || fetch_jwks(),
         {:ok, kid} <- header_kid(token),
         {:ok, jwk} <- jwk_for_kid(ks, kid),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token),
         true <- not_expired?(claims),
         true <- issuer_ok?(claims) do
      {:ok, claims}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Is a customer IdP configured on this runtime?"
  def configured?, do: cfg("WB_OIDC_JWKS_URL") != nil

  # ── internals ───────────────────────────────────────────────────────────────

  defp header_kid(token) do
    case token |> JOSE.JWS.peek_protected() |> Jason.decode() do
      {:ok, %{"kid" => kid}} when is_binary(kid) -> {:ok, kid}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp jwk_for_kid(%{"keys" => keys}, kid) when is_list(keys) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> :error
      key_map -> {:ok, JOSE.JWK.from_map(key_map)}
    end
  end

  defp jwk_for_kid(_, _), do: :error

  defp not_expired?(%{"exp" => exp}) when is_integer(exp), do: exp > System.system_time(:second)
  defp not_expired?(_), do: true

  # Only enforced when WB_OIDC_ISSUER is set (don't reject when unconfigured).
  defp issuer_ok?(claims) do
    case cfg("WB_OIDC_ISSUER") do
      nil -> true
      iss -> claims["iss"] == iss
    end
  end

  defp tenant_from(claims) do
    case cfg("WB_OIDC_TENANT_CLAIM") do
      nil -> claims["org_id"] || claims["organization_id"] || claims["sub"]
      claim -> claims[claim]
    end
  end

  defp fetch_jwks do
    with url when is_binary(url) <- cfg("WB_OIDC_JWKS_URL"),
         {:ok, body} <- Workbooks.NetGuard.get(url, max_bytes: 256 * 1024),
         {:ok, jwks} <- Jason.decode(body) do
      jwks
    else
      _ -> nil
    end
  end

  defp cfg(key) do
    case System.get_env(key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end
end
