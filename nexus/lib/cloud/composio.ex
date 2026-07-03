defmodule Nexus.Cloud.Composio do
  @moduledoc """
  Workbooks-Cloud's **whitelabeled Composio** broker — the multi-tenant tools layer. One org-scoped
  Composio key (`COMPOSIO_API_KEY`, held server-side, `x-api-key` header) serves every customer; each
  customer is a Composio `user_id` (we use the tenant id), so their connected accounts are isolated.

  Whitelabel = **custom auth configs**: we register OUR OAuth client per toolkit (`use_custom_auth`),
  so the consent screen shows OUR brand, not Composio's. The resulting `ac_…` id is what `connect/3`
  binds a user's account to.

  ## Mirrors `Nexus.Google` exactly (the no-op-safe seam)
    * `configured?/0` — false until `COMPOSIO_API_KEY` lands; the dashboard shows the tools section dark.
    * `opts[:http]` injects the transport so tests run with no network; `opts[:api_key]` overrides the
      secret. Every verb returns `{:skip, :composio_not_configured}` when neither key nor transport is
      present — the app compiles and tests green with zero secrets.
    * The key is added ONLY inside the pinned-TLS `:httpc` call, never in a pure body, never logged.

  JSON here is a genuine network-API payload (the legitimate JSON exception, same as `Nexus.Fly`).
  """
  @api "https://backend.composio.dev/api/v3.1"
  @v3 "https://backend.composio.dev/api/v3"
  @mcp "https://backend.composio.dev/v3/mcp"
  @host "backend.composio.dev"
  @max_body_bytes 4 * 1024 * 1024

  @doc "Is the org Composio key configured? Gates the real (non-injected) path."
  def configured?, do: Nexus.Secrets.has?("COMPOSIO_API_KEY")

  @doc "Toolkits available to whitelabel/connect. `{:ok, list} | {:error,_} | {:skip,_}`."
  def list_toolkits(opts \\ []), do: req(:get, @api <> "/toolkits", nil, opts)

  @doc """
  Register OUR OAuth client for `toolkit` as a whitelabel (custom) auth config — the consent screen then
  shows our brand. `creds` = `%{client_id, client_secret, redirect_uri}`. Returns `{:ok, %{"id"=>"ac_…"}}`.
  """
  def create_auth_config(toolkit, creds, opts \\ []) do
    body = %{
      "toolkit" => toolkit,
      "options" => %{
        "type" => "use_custom_auth",
        "auth_scheme" => "OAUTH2",
        "credentials" => %{
          "client_id" => creds[:client_id] || creds["client_id"],
          "client_secret" => creds[:client_secret] || creds["client_secret"],
          "oauth_redirect_uri" => creds[:redirect_uri] || creds["redirect_uri"]
        }
      }
    }

    req(:post, @api <> "/auth_configs", body, opts)
  end

  @doc """
  Start a connection for `user_id` against a whitelabel `auth_config_id` (`ac_…`). Returns a
  `redirect_url` the user opens to consent; poll `connection_status/2` until `ACTIVE`.
  `opts[:callback_url]` sets where Composio returns the user after consent.
  """
  def connect(user_id, auth_config_id, opts \\ []) do
    body = %{
      "auth_config" => %{"id" => auth_config_id},
      "connection" => %{
        "user_id" => user_id,
        "state" => %{"authScheme" => "OAUTH2"},
        "callback_url" => opts[:callback_url]
      }
    }

    req(:post, @api <> "/connected_accounts", body, opts)
  end

  @doc "Poll a connection. `{:ok, %{\"status\"=>\"ACTIVE\"|...}} | {:error,_} | {:skip,_}`."
  def connection_status(connection_id, opts \\ []),
    do: req(:get, @api <> "/connected_accounts/" <> connection_id, nil, opts)

  @doc """
  A per-user MCP endpoint for the given `toolkits`: create the server, then hand back the URL the
  autopoet agent points its MCP client at (scoped by `?user_id=`). `{:ok, url} | {:error,_} | {:skip,_}`.
  """
  def mcp_url(user_id, toolkits, opts \\ []) when is_list(toolkits) do
    body = %{"name" => "wb-" <> user_id, "toolkits" => toolkits}

    case req(:post, @v3 <> "/mcp/servers", body, opts) do
      {:ok, %{} = server} ->
        case server["id"] || server["server_id"] do
          id when is_binary(id) -> {:ok, @mcp <> "/" <> id <> "?user_id=" <> URI.encode_www_form(user_id)}
          _ -> {:error, :no_server_id}
        end

      other ->
        other
    end
  end

  # ── HTTP (borrows the Nexus.Google/Nexus.Fly transport shape) ────────────────────────────────────
  defp req(method, url, body, opts) do
    if ready?(opts) do
      headers = [{"accept", "application/json"}] ++ if(is_map(body), do: [{"content-type", "application/json"}], else: [])
      encoded = if is_map(body), do: Jason.encode!(body), else: ""
      key = opts[:api_key] || Nexus.Secrets.get("COMPOSIO_API_KEY") || ""
      http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, key))

      case http.(method, url, headers, encoded) do
        {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
        {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:skip, :composio_not_configured}
    end
  end

  defp ready?(opts), do: Keyword.has_key?(opts, :http) or present?(opts[:api_key]) or configured?()

  # Key added HERE only (never in a pure body, never logged). TLS verified + SNI pinned to the fixed
  # Composio host so the key can't be MITM-redirected — same discipline as Nexus.Fly/Nexus.Google.
  defp do_request(method, url, headers, body, key) do
    :inets.start()
    :ssl.start()
    headers = [{"x-api-key", key} | headers]
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch, :delete] and body != "",
        do: {to_charlist(url), hh, ~c"application/json", body},
        else: {to_charlist(url), hh}

    opts = [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: to_charlist(@host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, cap(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp cap(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes, do: binary_part(bin, 0, @max_body_bytes)
  defp cap(bin), do: bin

  defp decode(""), do: %{}
  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      _ -> %{}
    end
  end

  defp decode(other), do: other

  defp present?(v), do: is_binary(v) and v != ""
end
