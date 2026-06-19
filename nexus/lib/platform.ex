defmodule Nexus.Platform do
  @moduledoc """
  The hosted control-plane HTTP API — `/api/platform/*`, the surface the cloud dashboard calls
  (nexus fleet CRUD + wake/sleep, usage, storage, workspaces, identity). Mounted by `Nexus.Server`
  via `forward "/api/platform"`, but ONLY answers when this nexus runs in the control-plane role
  (`WB_CONTROL_PLANE`) — otherwise 404, indistinguishable from a tenant runtime.

  **Security:** `org = conn.assigns[:tenant]`, set upstream by `Nexus.Auth` from the WorkOS JWT's
  `org_id`. `require_org` REFUSES to serve under `Nexus.Auth.None` (no real identity → no platform
  access), and every handler scopes to `org` through `Nexus.ControlPlane`, whose `{org, kind, id}`
  keying makes cross-org reads structurally impossible. Body input is whitelisted (name/region/plan,
  name/icon/nexus_id) — org, secrets, image, and the Fly org are pinned server-side, never caller
  input.

  Fleet provisioning here is registry-backed (state transitions); the real Fly machine provisioner
  layers onto the same contract next.
  """
  use Plug.Router
  alias Nexus.ControlPlane, as: CP

  plug(:require_control_plane)
  plug(:match)
  plug(:require_org)
  plug(:dispatch)

  # ── nexuses ─────────────────────────────────────────────────────────────────────────────────
  get "/nexuses" do
    j(conn, 200, %{nexuses: Enum.map(CP.list(org(conn), :nexus), &nexus_view/1)})
  end

  post "/nexuses" do
    case Nexus.Provisioner.provision(org(conn), provision_opts(read(conn))) do
      {:ok, nx} -> j(conn, 201, nexus_view(nx))
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  get "/nexuses/:id" do
    case CP.get(org(conn), :nexus, conn.params["id"]) do
      {:ok, nx} -> j(conn, 200, nexus_view(nx))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  delete "/nexuses/:id" do
    case Nexus.Provisioner.teardown(conn.params["id"], org(conn)) do
      {:ok, _} -> j(conn, 200, %{ok: true})
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  post "/nexuses/:id/wake", do: lifecycle(conn, &Nexus.Provisioner.wake/2)
  post "/nexuses/:id/sleep", do: lifecycle(conn, &Nexus.Provisioner.sleep/2)

  # ── usage / identity / storage ───────────────────────────────────────────────────────────────
  # Honest-zero until the Fly-grounded NexusUsage + Storage backends are ported (next loop steps).
  get "/usage" do
    j(conn, 200, %{monthToDate: "$0.00", compute: "$0.00", activeHrs: 0, load: 0})
  end

  get "/me" do
    id = conn.assigns[:identity] || %{}
    j(conn, 200, %{user: %{id: id[:user], name: ""}, active_org: org(conn), orgs: []})
  end

  get "/storage" do
    org = org(conn)
    buckets = Enum.map(CP.list(org, :nexus), fn nx -> %{name: "#{nx.id}-storage", nexus: nx.id, objects: nil, size: "—", egress: "$0.00"} end)
    j(conn, 200, %{totalBytes: 0, totalSize: "0 GB", buckets: buckets})
  end

  # ── workspaces (free, no compute — logical org divisions) ──────────────────────────────────────
  get "/workspaces" do
    j(conn, 200, %{workspaces: Enum.map(CP.list(org(conn), :workspace), &ws_view/1)})
  end

  post "/workspaces" do
    org = org(conn)
    %{name: name, icon: icon, nexus_id: nexus_id} = workspace_params(read(conn))

    cond do
      name in [nil, ""] -> j(conn, 422, %{error: "name required"})
      true ->
        id = "ws_" <> rand()
        {:ok, ws} = CP.put(org, :workspace, id, %{name: name, icon: icon, nexus_id: nexus_id})
        j(conn, 201, ws_view(ws))
    end
  end

  patch "/workspaces/:id" do
    org = org(conn)
    attrs = read(conn) |> decode() |> Map.take(["name", "icon"]) |> atomize()

    case CP.update(org, :workspace, conn.params["id"], attrs) do
      {:ok, ws} -> j(conn, 200, ws_view(ws))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  delete "/workspaces/:id" do
    :ok = CP.delete(org(conn), :workspace, conn.params["id"])
    j(conn, 200, %{ok: true})
  end

  match _ do
    j(conn, 404, %{error: "not found"})
  end

  # ── guards ─────────────────────────────────────────────────────────────────────────────────
  defp require_control_plane(conn, _) do
    if CP.enabled?(), do: conn, else: conn |> send_resp(404, "not found") |> halt()
  end

  # No real org identity → no platform. Refuses Nexus.Auth.None (everyone would be one tenant = no
  # isolation), so the control-plane can never accidentally run wide-open.
  defp require_org(conn, _) do
    if is_binary(conn.assigns[:tenant]) and Nexus.Auth.multi?() do
      conn
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"})) |> halt()
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────────────
  defp org(conn), do: conn.assigns[:tenant]

  defp lifecycle(conn, fun) do
    case fun.(conn.params["id"], org(conn)) do
      {:ok, nx} -> j(conn, 200, nexus_view(nx))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  defp reason_str(r) when is_atom(r), do: Atom.to_string(r)
  defp reason_str(r), do: inspect(r)

  defp nexus_view(nx) do
    %{
      id: nx.id,
      name: nx[:name] || nx.id,
      region: nx[:region] || "",
      plan: nx[:plan] || "starter",
      state: map_state(nx[:state]),
      url: nx[:url] || ""
    }
  end

  defp ws_view(ws), do: %{id: ws.id, name: ws[:name], icon: ws[:icon], nexus_id: ws[:nexus_id]}

  defp map_state("running"), do: "run"
  defp map_state("stopped"), do: "sleep"
  defp map_state(_), do: "build"

  defp provision_opts(body) do
    m = decode(body)
    [] |> put_opt(:name, m["name"]) |> put_opt(:region, m["region"]) |> put_opt(:plan, m["plan"])
  end

  defp put_opt(opts, _k, v) when v in [nil, ""], do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  defp workspace_params(body) do
    m = decode(body)
    %{name: m["name"], icon: m["icon"], nexus_id: blank_to_nil(m["nexus_id"])}
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp atomize(m), do: Map.new(m, fn {k, v} -> {String.to_existing_atom(k), v} end)

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

  defp rand, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp j(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
