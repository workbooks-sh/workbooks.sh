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
  alias Nexus.ControlPlane.Env

  plug(:require_control_plane)
  plug(:match)
  plug(:require_org)
  plug(:dispatch)

  # ── nexuses ─────────────────────────────────────────────────────────────────────────────────
  get "/nexuses" do
    j(conn, 200, %{nexuses: Enum.map(CP.list(org(conn), :nexus), &nexus_view/1)})
  end

  # One nexus PER ORG — the nexus IS the org (a Fly machine / scale-group). You
  # scale the one nexus (pricing tier), you don't create a second; more separation
  # means a new org. Refuse a second provision rather than fan out machines.
  post "/nexuses" do
    case CP.list(org(conn), :nexus) do
      [nx | _] ->
        j(conn, 409, %{error: "one nexus per organization — scale this one instead, or create a new org", nexus: nexus_view(nx)})

      [] ->
        case Nexus.Provisioner.provision(org(conn), provision_opts(read(conn))) do
          {:ok, nx} -> j(conn, 201, nexus_view(nx))
          {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
        end
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
  # Usage + capacity for the org's single nexus: RAM + storage vs the tier ceiling
  # (Nexus.Pricing), plus the top consumers to shed when a dial runs hot. Auto-scale
  # lives within the ceiling; crossing it is a paid scale-up. (Showcase backend —
  # the per-nexus reading is derived; the limits/thresholds/billing are real.)
  get "/usage" do
    j(conn, 200, Nexus.Capacity.report(List.first(CP.list(org(conn), :nexus))))
  end

  # The tier ladder (for the dashboard's scale-up UI) — limits + price + domains gate.
  get "/tiers" do
    j(conn, 200, %{tiers: Nexus.Pricing.tiers()})
  end

  # (Marketing/upsell logic is NOT a runtime concern — THE LINE. It lives in our own workbook
  # `dogfood/marketing` as a `server :upsell` block, served like any workbook via its live source.)

  get "/me" do
    id = conn.assigns[:identity] || %{}
    user_id = id[:user]
    orgs = if is_binary(user_id), do: Nexus.WorkOS.orgs_for_user(user_id), else: []
    j(conn, 200, %{user: %{id: user_id, name: ""}, active_org: org(conn), orgs: orgs})
  end

  get "/storage" do
    org = org(conn)
    buckets = Enum.map(CP.list(org, :nexus), fn nx -> %{name: "#{nx.id}-storage", nexus: nx.id, objects: nil, size: "—", egress: "$0.00"} end)
    j(conn, 200, %{totalBytes: 0, totalSize: "0 GB", buckets: buckets})
  end

  # ── CLI access tokens (minted for the org; the `work` CLI sends them as Bearer) ────────────────
  # The dashboard (WorkOS JWT) mints these; the headless CLI then authenticates
  # with one via Nexus.Auth.Cloud — no browser session needed.
  post "/tokens/mint" do
    name = read(conn)["name"] || "cli"
    j(conn, 201, Nexus.ControlPlane.Token.mint(org(conn), name))
  end

  get "/tokens" do
    j(conn, 200, %{tokens: Nexus.ControlPlane.Token.list(org(conn))})
  end

  delete "/tokens/:id" do
    Nexus.ControlPlane.Token.revoke(org(conn), conn.params["id"])
    j(conn, 200, %{ok: true})
  end

  # ── custom domains (paid-tier, owner-verified — share from your domain, not ours) ──────────────
  # Add → TXT challenge; verify → resolve the TXT + request the Fly cert; the record
  # is org-scoped and the host is globally unique. See Nexus.ControlPlane.Domain.
  get "/domains" do
    j(conn, 200, %{domains: Nexus.ControlPlane.Domain.list(org(conn))})
  end

  post "/domains" do
    case Nexus.ControlPlane.Domain.add(org(conn), decode(read(conn))["host"]) do
      {:ok, view} -> j(conn, 201, view)
      {:error, reason} -> j(conn, domain_status(reason), %{error: domain_error(reason)})
    end
  end

  get "/domains/:id" do
    case Nexus.ControlPlane.Domain.get(org(conn), conn.params["id"]) do
      {:ok, view} -> j(conn, 200, view)
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  post "/domains/:id/verify" do
    case Nexus.ControlPlane.Domain.verify(org(conn), conn.params["id"]) do
      {:ok, view} -> j(conn, 200, view)
      {:error, :txt_not_found} -> j(conn, 422, %{error: "TXT challenge not found — add the record and allow DNS to propagate, then retry"})
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: domain_error(reason)})
    end
  end

  delete "/domains/:id" do
    case Nexus.ControlPlane.Domain.remove(org(conn), conn.params["id"]) do
      :ok -> j(conn, 200, %{ok: true})
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
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

  # ── env vars (encrypted-at-rest, org+workspace-scoped team secrets) ─────────────────────────────
  # All org-scoped via Nexus.ControlPlane.Env (cross-org physically impossible). The list/views are
  # REDACTED — the plaintext only ever leaves via the explicit /reveal action. A missing master key
  # fails closed → 503 (values are never stored unencrypted), surfaced by `env_fail`.
  get "/env" do
    ws = fetch_query_params(conn).query_params["workspace"]
    j(conn, 200, %{env: Env.list(org(conn), blank_to_nil(ws))})
  end

  post "/env" do
    m = decode(read(conn))
    attrs = %{
      name: m["name"], value: m["value"], scope: m["scope"],
      workspace_id: m["workspace_id"], package_name: m["package_name"]
    }

    case Env.create(org(conn), attrs) do
      {:ok, view} -> j(conn, 201, view)
      {:error, reason} -> env_fail(conn, reason)
    end
  end

  get "/env/:id/reveal" do
    case Env.reveal(org(conn), conn.params["id"]) do
      {:ok, value} -> j(conn, 200, %{value: value})
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> env_fail(conn, reason)
    end
  end

  patch "/env/:id" do
    m = decode(read(conn))
    attrs = %{name: m["name"], value: m["value"]}

    case Env.update(org(conn), conn.params["id"], attrs) do
      {:ok, view} -> j(conn, 200, view)
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> env_fail(conn, reason)
    end
  end

  delete "/env/:id" do
    :ok = Env.delete(org(conn), conn.params["id"])
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

  # No master key → fail closed with 503 (a deploy-config error, not the caller's fault); other env
  # errors are caller validation → 422. Never leak crypto detail beyond the reason atom.
  defp env_fail(conn, :no_master_key),
    do: j(conn, 503, %{error: "env store unavailable: WB_ENV_MASTER_KEY not configured"})

  defp env_fail(conn, reason), do: j(conn, 422, %{error: reason_str(reason)})

  defp reason_str(r) when is_atom(r), do: Atom.to_string(r)
  defp reason_str(r), do: inspect(r)

  # Custom-domain errors → HTTP status + a buyer-facing message.
  defp domain_status(:tier_locked), do: 402
  defp domain_status(:host_taken), do: 409
  defp domain_status(:no_nexus), do: 409
  defp domain_status(_), do: 422

  defp domain_error(:tier_locked), do: "custom domains need a paid plan (Team or higher) — scale up to bind one"
  defp domain_error(:host_taken), do: "that host is already bound to another organization"
  defp domain_error(:reserved_host), do: "that host is reserved"
  defp domain_error(:invalid_host), do: "enter a valid domain like apps.yourcompany.com"
  defp domain_error(:no_nexus), do: "provision your nexus before binding a domain"
  defp domain_error(r), do: reason_str(r)

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
