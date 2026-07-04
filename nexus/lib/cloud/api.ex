defmodule Nexus.Cloud.Api do
  @moduledoc """
  The thin **desktop-facing** HTTP API for Workbooks Cloud — `/api/cloud/*`, mounted by `Nexus.Server`
  (`forward "/api/cloud"`). The autopoet desktop calls these; the brokers hold the Fly/Composio tokens
  server-side, so the desktop never sees a credential.

  Borrows `Nexus.Platform`'s exact shape: only answers in the control-plane role (`WB_CONTROL_PLANE`,
  else 404 — indistinguishable from a tenant runtime); `tenant = conn.assigns[:tenant]` from the auth
  seam (`require_org` refuses `Nexus.Auth.None`); every handler scopes to that tenant via `Nexus.Cloud`,
  whose `{tenant, :cloud_tenant, tenant}` keying makes cross-tenant access structurally impossible.

  Result mapping: `{:ok,_}`→200/201, `{:skip, reason}`→503 (feature dark — token not configured),
  `{:error, :not_found}`→404, `{:error, reason}`→422.

  ## Desktop → control-plane surface
    Machine:
      POST   /api/cloud/provision                 → provision (or return) this tenant's machine
      GET    /api/cloud/machine                    → machine record + live Fly status
      POST   /api/cloud/machine/start|stop|suspend → lifecycle
      POST   /api/cloud/machine/image  {image}     → roll to a new image
      DELETE /api/cloud/machine                    → teardown
    Tools (whitelabeled Composio):
      GET    /api/cloud/tools                       → list toolkits
      POST   /api/cloud/tools/auth_config           → register OUR whitelabel OAuth client (admin)
                                                       {toolkit, client_id, client_secret, redirect_uri}
      POST   /api/cloud/tools/connect  {auth_config_id} → start a connection → {redirect_url}
      GET    /api/cloud/tools/connection/:id        → poll a connection status
      GET    /api/cloud/tools/mcp?toolkits=a,b       → this tenant's per-user MCP URL
  """
  use Plug.Router
  alias Nexus.ControlPlane, as: CP
  alias Nexus.Cloud

  plug(:require_control_plane)
  plug(:match)
  plug(:require_org)
  plug(:dispatch)

  # ── machine ──────────────────────────────────────────────────────────────────────────────────
  post "/provision" do
    respond(conn, Cloud.provision(org(conn)), 201)
  end

  get "/machine" do
    respond(conn, Cloud.status(org(conn)))
  end

  post "/machine/start", do: respond(conn, Cloud.start(org(conn)))
  post "/machine/stop", do: respond(conn, Cloud.stop(org(conn)))
  post "/machine/suspend", do: respond(conn, Cloud.suspend(org(conn)))

  post "/machine/image" do
    case decode(read(conn))["image"] do
      image when is_binary(image) and image != "" -> respond(conn, Cloud.update_image(org(conn), image))
      _ -> j(conn, 422, %{error: "image required"})
    end
  end

  delete "/machine" do
    respond(conn, Cloud.teardown(org(conn)))
  end

  # ── whitelabeled tools ─────────────────────────────────────────────────────────────────────────
  get "/tools" do
    respond(conn, Cloud.list_tools())
  end

  # Registering an org-wide whitelabel OAuth client is an operator action → admin only.
  post "/tools/auth_config" do
    admin_only(conn, fn ->
      m = decode(read(conn))

      case m["toolkit"] do
        tk when is_binary(tk) and tk != "" ->
          creds = %{client_id: m["client_id"], client_secret: m["client_secret"], redirect_uri: m["redirect_uri"]}
          respond(conn, Cloud.create_tool_auth_config(tk, creds), 201)

        _ ->
          j(conn, 422, %{error: "toolkit required"})
      end
    end)
  end

  post "/tools/connect" do
    case decode(read(conn))["auth_config_id"] do
      ac when is_binary(ac) and ac != "" -> respond(conn, Cloud.connect_tool(org(conn), ac), 201)
      _ -> j(conn, 422, %{error: "auth_config_id required"})
    end
  end

  get "/tools/connection/:id" do
    respond(conn, Cloud.tool_status(conn.params["id"]))
  end

  # Which toolkits are connectable (operator has registered a whitelabel OAuth config).
  get "/tools/auth_configs" do
    respond(conn, Cloud.list_tool_auth_configs())
  end

  # This tenant's connected accounts (Composio isolates by user_id = tenant).
  get "/tools/connections" do
    respond(conn, Cloud.list_tool_connections(org(conn)))
  end

  delete "/tools/connection/:id" do
    admin_only(conn, fn -> respond(conn, Cloud.disconnect_tool(conn.params["id"])) end)
  end

  get "/tools/mcp" do
    toolkits =
      fetch_query_params(conn).query_params["toolkits"]
      |> to_string()
      |> String.split(",", trim: true)

    respond(conn, Cloud.tool_mcp_url(org(conn), toolkits))
  end

  match _ do
    j(conn, 404, %{error: "not found"})
  end

  # ── guards (borrowed verbatim from Nexus.Platform) ─────────────────────────────────────────────
  defp require_control_plane(conn, _) do
    if CP.enabled?(), do: conn, else: conn |> send_resp(404, "not found") |> halt()
  end

  defp require_org(conn, _) do
    if is_binary(conn.assigns[:tenant]) and Nexus.Auth.multi?() do
      conn
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"})) |> halt()
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────────────
  defp org(conn), do: conn.assigns[:tenant]

  defp admin?(conn), do: Nexus.Auth.role_at_least?(Nexus.Auth.role(conn), "admin")
  defp admin_only(conn, fun), do: if(admin?(conn), do: fun.(), else: j(conn, 403, %{error: "admin required"}))

  # Uniform result → HTTP mapping for the broker/orchestrator return shapes.
  defp respond(conn, result, ok_status \\ 200)
  defp respond(conn, {:ok, body}, ok_status), do: j(conn, ok_status, view(body))
  defp respond(conn, {:skip, reason}, _), do: j(conn, 503, %{error: "not configured", detail: reason_str(reason)})
  defp respond(conn, {:error, :not_found}, _), do: j(conn, 404, %{error: "not found"})
  defp respond(conn, {:error, reason}, _), do: j(conn, 422, %{error: reason_str(reason)})

  # Broker returns are already plain maps / lists / strings (network payloads) or :torn_down. Wrap the
  # scalars so the body is always a JSON object.
  defp view(m) when is_map(m), do: m
  defp view(list) when is_list(list), do: %{items: list}
  defp view(:torn_down), do: %{ok: true}
  defp view(other), do: %{result: other}

  defp reason_str(r) when is_atom(r), do: Atom.to_string(r)
  defp reason_str(r), do: inspect(r)

  defp read(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp j(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
