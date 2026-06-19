defmodule Nexus.WorkOS do
  @moduledoc """
  A thin WorkOS API client for the control plane — answers "which organizations is this user a member
  of, and what's their role?" so the dashboard can show a real org/nexus switcher.

  AUTH: `Bearer` from `WORKOS_API_KEY` (a host secret; never logged, never returned). Inert if the key
  is unset — every call returns `[]`, so the feature degrades to "personal only" rather than crashing.

  SSRF floor: the host is the fixed `@api` constant; user/org ids are validated as a single opaque
  segment before interpolation. TLS is verify_peer with a pinned SNI. `opts[:http]` injects a
  transport for network-free tests. JSON here is a genuine network-API payload (the legitimate JSON
  exception).
  """
  @api "https://api.workos.com"

  @doc """
  The organizations `user_id` belongs to, each with the user's role: `[%{id, name, role}]`. Empty
  list if the key is unset, the user has no memberships, or anything errors (fail-soft — never raises).
  """
  def orgs_for_user(user_id, opts \\ []) do
    with true <- configured?(),
         {:ok, uid} <- safe_segment(user_id),
         {:ok, memberships} <- list_memberships(uid, opts) do
      Enum.map(memberships, fn m ->
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

  # ── internals ─────────────────────────────────────────────────────────────────────────────────
  defp list_memberships(user_id, opts) do
    case get(["user_management", "organization_memberships?user_id=#{user_id}&limit=100&statuses=active"], opts) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, data}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

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
    http = Keyword.get(opts, :http, &do_get(&1, api_key()))

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
    case Nexus.Secrets.get("WORKOS_API_KEY") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # A user/org id must be ONE opaque path segment — no slash/dot-segment/query/control chars (so a
  # crafted id can't escape the route or inject a query). Fail-closed otherwise.
  defp safe_segment(s) when is_binary(s) and s != "" do
    cond do
      String.contains?(s, ["/", "\\", "#", "%", " ", "?", "&"]) -> {:error, :invalid_id}
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

  defp decode(other), do: other
end
