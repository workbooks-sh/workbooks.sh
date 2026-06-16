defmodule Workbooks.WorkOS do
  @moduledoc """
  A thin WorkOS API client for the control plane — answers "which organizations is
  this user a member of, and what's their role?" so the desktop/dashboard can show a
  real org/nexus switcher with permissions.

  AUTH: `Bearer` from `WORKOS_API_KEY` (a host secret; never logged, never returned).
  Inert if the key is unset — every call returns an empty/`:error` result, so the
  feature degrades to "personal only" rather than crashing.

  SSRF floor: the host is the fixed `@api` constant; user ids are validated as a
  single opaque segment before interpolation. TLS is verify_peer with a pinned SNI
  (same pattern as `Workbooks.FlyMachines`).
  """
  require Logger

  @api "https://api.workos.com"

  @doc """
  The organizations `user_id` belongs to, each with the user's role:
  `[%{id, name, role}]` (newest membership first). Empty list if the key is unset,
  the user has no memberships, or anything errors (fail-soft — never raises).
  """
  def orgs_for_user(user_id, opts \\ []) do
    with true <- configured?(),
         {:ok, uid} <- safe_segment(user_id),
         {:ok, memberships} <- list_memberships(uid, opts) do
      memberships
      |> Enum.map(fn m ->
        org_id = m["organization_id"]
        %{
          id: org_id,
          name: organization_name(org_id, opts) || org_id,
          role: get_in(m, ["role", "slug"]) || "member"
        }
      end)
    else
      _ -> []
    end
  end

  @doc "Is a WorkOS API key configured on this runtime?"
  def configured?, do: api_key() != nil

  @doc """
  The WorkOS client id. From `WORKOS_CLIENT_ID`, else derived from the JWKS URL's
  last path segment (`…/sso/jwks/<client_id>`) so a single config powers both.
  """
  def client_id do
    case System.get_env("WORKOS_CLIENT_ID") do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        case System.get_env("WB_OIDC_JWKS_URL") do
          u when is_binary(u) -> u |> String.split("/") |> List.last()
          _ -> nil
        end
    end
  end

  @doc """
  The hosted AuthKit authorize URL to send a user's browser to. `redirect_uri` is
  the broker's own callback (must be a registered WorkOS redirect); `state` is the
  opaque flow id we look up on the way back.
  """
  def authorize_url(redirect_uri, state, organization_id \\ nil) do
    base = %{
      "client_id" => client_id(),
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "provider" => "authkit",
      "state" => state
    }

    # Scope the sign-in to a specific org (the desktop org switcher) — omitted for a
    # personal/no-org session.
    params =
      case organization_id do
        org when is_binary(org) and org != "" -> Map.put(base, "organization_id", org)
        _ -> base
      end

    @api <> "/user_management/authorize?" <> URI.encode_query(params)
  end

  @doc """
  Exchange a WorkOS authorization `code` for a session:
  `{:ok, %{access_token, user, organization_id, expires_at}}` or `{:error, _}`.
  `user` is the raw WorkOS user map; `expires_at` is the access token's `exp`.
  """
  def authenticate(code, opts \\ []) do
    body = %{
      "client_id" => client_id(),
      "client_secret" => api_key(),
      "grant_type" => "authorization_code",
      "code" => code
    }

    case post(["user_management", "authenticate"], body, opts) do
      {:ok, %{"access_token" => tok} = m} ->
        {:ok,
         %{
           access_token: tok,
           refresh_token: m["refresh_token"],
           user: m["user"] || %{},
           organization_id: m["organization_id"],
           expires_at: jwt_exp(tok)
         }}

      {:ok, other} ->
        {:error, {:no_access_token, other}}

      err ->
        err
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────────

  # The `exp` claim of an access token (unix seconds), peeked without verifying —
  # we trust it because WorkOS just minted it over TLS. 0 if unreadable.
  defp jwt_exp(tok) when is_binary(tok) do
    with [_, payload, _] <- String.split(tok, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(json) do
      exp
    else
      _ -> 0
    end
  end

  defp jwt_exp(_), do: 0

  defp post(segments, body, opts) do
    url = @api <> "/" <> Enum.join(segments, "/")
    key = api_key()
    http = Keyword.get(opts, :http, &do_post(&1, Jason.encode!(body), key))

    case http.(url) do
      {:ok, {status, b}} when status in 200..299 -> {:ok, decode(b)}
      {:ok, {status, b}} -> {:error, {status, decode(b)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_post(url, json, key) do
    :inets.start()
    :ssl.start()

    headers = [
      {~c"authorization", ~c"Bearer #{key}"},
      {~c"accept", ~c"application/json"}
    ]

    http_opts = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"api.workos.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    req = {to_charlist(url), headers, ~c"application/json", json}

    case :httpc.request(:post, req, http_opts, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, resp}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp list_memberships(user_id, opts) do
    case get(["user_management", "organization_memberships?user_id=#{user_id}&limit=100&statuses=active"], opts) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  # Org name lookup, best-effort (a missing name falls back to the id upstream).
  defp organization_name(org_id, opts) when is_binary(org_id) and org_id != "" do
    case safe_segment(org_id) do
      {:ok, id} ->
        case get(["organizations", id], opts) do
          {:ok, %{"name" => name}} when is_binary(name) -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp organization_name(_, _), do: nil

  defp get(segments, opts) do
    url = @api <> "/" <> Enum.join(segments, "/")
    key = api_key()
    http = Keyword.get(opts, :http, &do_get(&1, key))

    case http.(url) do
      {:ok, {status, body}} when status in 200..299 -> {:ok, decode(body)}
      {:ok, {status, body}} -> {:error, {status, decode(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_get(url, key) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", ~c"Bearer #{key}"}, {~c"accept", ~c"application/json"}]

    http_opts = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"api.workos.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, {to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_, code, _}, _h, body}} -> {:ok, {code, body}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp api_key do
    case System.get_env("WORKOS_API_KEY") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # A user/org id must be one opaque path segment — no slash/dot-segment/query/control
  # chars (so a crafted id can't escape the route). Fails closed otherwise.
  defp safe_segment(s) when is_binary(s) and s != "" do
    cond do
      String.contains?(s, ["/", "\\", "#", "%", " "]) -> {:error, :invalid_id}
      String.match?(s, ~r/[\x00-\x1f\x7f]/) -> {:error, :invalid_id}
      true -> {:ok, s}
    end
  end

  defp safe_segment(_), do: {:error, :invalid_id}

  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      _ -> %{}
    end
  end
end
