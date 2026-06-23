defmodule Nexus.Auth.Jwt do
  @moduledoc """
  Multi-tenant auth by **verified JWT** — the one adapter for WorkOS / Clerk / Auth0 / BetterAuth /
  roll-your-own. They all issue JWTs; you configure how to verify + which claim is the tenant:

      config :nexus, Nexus.Auth.Jwt,
        # ONE of:
        secret: "shared-hs256-secret",            # symmetric (roll-your-own / BetterAuth HS256)
        jwks_url: "https://…/.well-known/jwks.json", # asymmetric RS256 (WorkOS/Clerk/Auth0)
        # claim mapping:
        tenant_claim: "org_id",                    # which claim carries the tenant (required)
        user_claim:   "sub",
        issuer:       "https://…"                  # optional iss check

  Verifies the signature (HS256 secret or RS256 via the JWKS, key picked by the token's `kid`),
  checks `exp` (and `iss` if set), and returns `%{tenant, user}`. JWKS is fetched over verified TLS
  and cached, re-fetched once on a `kid` miss (key rotation).
  """
  @behaviour Nexus.Auth
  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def authenticate(conn) do
    with [hdr] <- get_req_header(conn, "authorization"),
         "Bearer " <> jwt <- hdr,
         {:ok, claims} <- verify(jwt) do
      tenant = claims[cfg(:tenant_claim, "tenant")]

      if is_binary(tenant) and tenant != "",
        do: {:ok, %{tenant: tenant, user: claims[cfg(:user_claim, "sub")]}},
        else: {:error, :no_tenant_claim}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Verify a JWT's signature + exp/iss. `{:ok, claims} | {:error, reason}`. Exposed for testing and for
  `Nexus.Auth.Provider` (id_token verification). `overrides` (keyword) supplies per-call config —
  `:secret`, `:jwks_url`, `:issuer` — so a login PROVIDER can verify against ITS jwks/issuer instead of
  the global adapter config. Same vetted JOSE path; JWKS is still https-only and exp/iss are checked.
  """
  def verify(jwt, overrides \\ []) do
    with {:ok, jwk, alg} <- key_for(jwt, overrides),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, [alg], jwt),
         :ok <- check_exp(claims),
         :ok <- check_iss(claims, overrides) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp key_for(jwt, o) do
    case cfg(:secret, nil, o) do
      s when is_binary(s) and s != "" -> {:ok, JOSE.JWK.from_oct(s), "HS256"}
      _ -> jwks_key(jwt, o)
    end
  end

  defp jwks_key(jwt, o) do
    with url when is_binary(url) <- cfg(:jwks_url, nil, o),
         true <- https?(url),
         %JOSE.JWS{fields: %{"kid" => kid}} <- JOSE.JWT.peek_protected(jwt),
         {:ok, key_map} <- find_key(url, kid) do
      {:ok, JOSE.JWK.from_map(key_map), "RS256"}
    else
      _ -> {:error, :no_key}
    end
  end

  # A JWKS URL MUST be https — fetching signing keys over cleartext is a trivial MITM key-swap that
  # forges any tenant. Refuse anything that isn't https:// outright.
  defp https?(url), do: String.starts_with?(url, "https://")

  defp find_key(url, kid) do
    case Enum.find(jwks(url, false), &(&1["kid"] == kid)) do
      nil ->
        case Enum.find(jwks(url, true), &(&1["kid"] == kid)) do
          nil -> {:error, :no_kid}
          k -> {:ok, k}
        end

      k ->
        {:ok, k}
    end
  end

  defp jwks(url, refresh) do
    cache = {:nexus_jwks, url}

    case (not refresh && :persistent_term.get(cache, nil)) || nil do
      keys when is_list(keys) ->
        keys

      _ ->
        keys = fetch_keys(url)
        # only cache a non-empty, well-formed key set — never poison the cache with [] from a
        # transient fetch/parse failure (would wedge auth until restart).
        if keys != [], do: :persistent_term.put(cache, keys)
        keys
    end
  end

  # Bounded, crash-safe JWKS fetch. A malicious/oversized/non-JSON JWKS body must yield `[]`
  # (→ 401), never an unhandled raise (500) or unbounded memory. 1 MiB is far above any real JWKS.
  @jwks_max_bytes 1_048_576
  defp fetch_keys(url) do
    with {:ok, body} <- Nexus.Compilers.Shared.http_get(url),
         true <- byte_size(body) <= @jwks_max_bytes,
         {:ok, %{"keys" => keys}} when is_list(keys) <- Jason.decode(body) do
      Enum.filter(keys, &is_map/1)
    else
      _ -> []
    end
  end

  defp check_exp(%{"exp" => exp}) when is_integer(exp),
    do: if(System.os_time(:second) < exp, do: :ok, else: {:error, :expired})

  # A token with no (or non-integer) `exp` is REJECTED, not accepted forever — an immortal token is the
  # JWT-BCP (RFC 8725) anti-pattern: a leaked HS256 secret or a misconfigured issuer could otherwise mint
  # a token valid for any tenant indefinitely. Absence ⇒ deny. (red-team wb-bri2)
  defp check_exp(_), do: {:error, :missing_exp}

  defp check_iss(claims, o) do
    case cfg(:issuer, nil, o) do
      iss when is_binary(iss) and iss != "" -> if(claims["iss"] == iss, do: :ok, else: {:error, :bad_issuer})
      _ -> :ok
    end
  end

  # Per-call overrides win over the global adapter config (so a login provider verifies against its own
  # jwks/issuer). `cfg/2` keeps the no-override form for the adapter's own reads.
  defp cfg(key, default \\ nil, o \\ []) do
    case o[key] do
      v when not is_nil(v) and v != "" -> v
      _ -> Keyword.get(Application.get_env(:nexus, __MODULE__, []), key, default)
    end
  end
end
