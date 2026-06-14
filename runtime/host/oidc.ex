defmodule Workbooks.OIDC do
  @moduledoc """
  Generic OIDC / JWKS token verification — the pluggable identity-provider seam
  (wb-wejt). Any RS256-JWT IdP works the same way: WorkOS, Clerk, Auth0, etc. all
  publish a JWKS and sign RS256 tokens. A deployment points this at ITS provider's
  JWKS (it is NOT WorkOS-specific):

    WB_OIDC_JWKS_URL    — the provider's JWKS endpoint (required to enable)
    WB_OIDC_ISSUER      — optional; if set, the token's `iss` must match
    WB_OIDC_TENANT_CLAIM — optional; which claim → tenant (default: org_id /
                           organization_id / sub, in that order)

  Inert until WB_OIDC_JWKS_URL is set, so local/desktop deployments need none of
  this. Platform-admin access (our own IdP, for support into customer nexuses) is a
  SEPARATE, deliberate concern — see wb-<admin>. `verify_token/2` takes an explicit
  jwks so the crypto path is provable without a live IdP.
  """
  require Logger

  @doc """
  Verify an RS256 OIDC JWT against `jwks` (parsed `%{"keys" => [...]}`; fetched from
  WB_OIDC_JWKS_URL when nil). Returns `{:ok, tenant}` or `:error`.
  """
  def verify_token(token, jwks \\ nil) when is_binary(token) do
    with %{"keys" => _} = ks <- jwks || fetch_jwks(),
         {:ok, kid} <- header_kid(token),
         {:ok, jwk} <- jwk_for_kid(ks, kid),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token),
         true <- not_expired?(claims),
         true <- issuer_ok?(claims) do
      case tenant_from(claims) do
        t when is_binary(t) and t != "" -> {:ok, t}
        _ -> :error
      end
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
