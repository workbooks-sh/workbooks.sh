defmodule Workbooks.BrokeredApp do
  @moduledoc """
  The APP-HOST PLATFORM (Stone 5, productized) — the "calculator → platform" jump. Turns the proven
  serve+broker capstone into a real deploy target: `define/3` registers a sandboxed web app — a wasm guest
  handler + per-app GRANTS (network allow-list, durable-storage namespace, exec) + a ROUTE — and many such apps
  run over ONE `BrokeredApp.Router` (a Bandit plug), request-scoped. Each app is:

    * PERSISTED — its durable KV is scoped to its `:tenant`, so state survives the app instance restarting (the
      wasm instance is ephemeral; the data is not).
    * ISOLATED — its own storage namespace + its own egress allow-list; one app can't read another's KV or
      reach another's hosts.
    * SCOPED + SSRF-SAFE — any outbound it makes goes through the brokers (NetGuard/ExecBroker), default-deny.
    * RATE-LIMITED + REVOCABLE + AUDITED — per-app inbound flood floor; `stop/1` revokes it without taking the
      server down; every dispatch is observable via BrokerAudit.

  A guest is a reactor exporting `handle` (reads the request via `host_request_get`, writes the response via
  `host_response_set`; may call the granted brokers `host_http_get` / `host_kv_*` / `host_exec`). This is the
  same guest shape proven in test/broker_app_host_test.exs and the serve+KV/serve+exec compositions.
  """
  alias Workbooks.{ServeBroker, RustDock, BrokerTables}
  require Logger
  @table :wb_brokered_apps

  @doc """
  Define + start a sandboxed app. Returns `{:ok, app}` | `{:error, reason}`. opts:
    * `:route` — path PREFIX this app serves (default `"/<name>"`)
    * `:profile` — Policy profile granting capabilities (default `:network` = net+kv+exec+…)
    * `:net_allow` — per-app egress allow-list, `["host", "*.suffix", "host:port"]` (default: SSRF floor only)
    * `:tenant` — durable-storage namespace (default: the app name → per-app isolation)
    * `:rate` — `{max, window_ms}` inbound per-app flood floor
  Re-defining an existing name replaces its instance (its durable data under `:tenant` persists).
  """
  def define(name, wasm_bytes, opts \\ []) when is_binary(name) and is_binary(wasm_bytes) do
    route = Keyword.get(opts, :route, "/" <> name)
    profile = Keyword.get(opts, :profile, :network)
    tenant = Keyword.get(opts, :tenant, name)
    net_allow = Keyword.get(opts, :net_allow)
    rate = Keyword.get(opts, :rate)

    # the guest's import surface = its granted brokers (egress/kv/exec, scoped to this app's tenant + net_allow)
    # MERGED with the serve request/response channel keyed by the app name.
    dock = RustDock.imports(profile: profile, tenant: tenant, net_allow: net_allow)["env"]
    env = Map.merge(dock, ServeBroker.imports(name))

    case Wasmex.start_link(%{bytes: wasm_bytes, imports: %{"env" => env}}) do
      {:ok, pid} ->
        # replacing an existing app: retire the old instance first; clear any prior revocation of this name.
        case lookup(name) do
          %{pid: old} -> safe_stop(old)
          _ -> :ok
        end

        Workbooks.Revocation.unrevoke(name)
        app = %{name: name, pid: pid, route: route, tenant: tenant, rate: rate, profile: profile}
        :ets.insert(table(), {name, app})
        Logger.info("brokered-app — defined #{name} @ #{route} (tenant=#{tenant}, profile=#{profile})")
        {:ok, app}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop + deregister an app. REVOKES its serve channel (in-flight + future requests refused), retires the wasm instance. Its DURABLE data under `:tenant` persists."
  def stop(name) when is_binary(name) do
    case lookup(name) do
      nil ->
        :ok

      app ->
        Workbooks.Revocation.revoke(name)
        safe_stop(app.pid)
        :ets.delete(table(), name)
        Logger.info("brokered-app — stopped #{name}")
        :ok
    end
  end

  @doc "All defined apps."
  def list, do: table() |> :ets.tab2list() |> Enum.map(fn {_, app} -> app end)

  @doc "Look up one app by name (`nil` if undefined)."
  def lookup(name) do
    case :ets.lookup(table(), name) do
      [{_, app}] -> app
      _ -> nil
    end
  end

  @doc "Find the app whose `:route` is the LONGEST prefix of `path` (so /a/b beats /a). `nil` if none match."
  def route_for(path) when is_binary(path) do
    list()
    |> Enum.filter(fn a -> prefix?(path, a.route) end)
    |> Enum.sort_by(fn a -> -byte_size(a.route) end)
    |> List.first()
  end

  # a route matches a path if it's the exact path or a path-segment prefix ("/x" matches "/x" and "/x/y", not "/xy")
  defp prefix?(path, route) do
    path == route or String.starts_with?(path, route <> "/") or route == "/"
  end

  defp safe_stop(pid) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  rescue
    _ -> :ok
  end

  defp table, do: BrokerTables.ensure(@table, [:named_table, :public, :set])
end

defmodule Workbooks.BrokeredApp.Router do
  @moduledoc """
  Bandit/Plug front door for the app-host platform: one listener, MANY apps. Each request is routed to the
  `BrokeredApp` whose `:route` longest-prefix-matches the path, marshaled to bytes, and dispatched to that app's
  sandboxed guest (`ServeBroker.dispatch`, serialized + rate-limited + revocation-checked per app). The guest
  never touches the socket; the host owns it.
  """
  @behaviour Plug
  import Plug.Conn
  alias Workbooks.{BrokeredApp, ServeBroker}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    max_req = Keyword.get(opts, :max_request_bytes, 4 * 1024 * 1024)

    case read_body(conn, length: max_req) do
      {:ok, body, conn} ->
        case BrokeredApp.route_for(conn.request_path) do
          nil ->
            send_resp(conn, 404, "no app for #{conn.request_path}")

          app ->
            req = ServeBroker.encode_http_request(conn.method, conn.request_path, conn.req_headers, body)

            case ServeBroker.dispatch(app.name, app.pid, req, rate: app.rate) do
              {:ok, resp} ->
                {status, headers, out} = ServeBroker.decode_http_response(resp)
                conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
                send_resp(conn, status, out)

              {:error, :rate_limited} ->
                send_resp(conn, 429, "rate limited")

              {:error, :revoked} ->
                send_resp(conn, 503, "app stopped")

              {:error, _} ->
                send_resp(conn, 502, "guest handler error")
            end
        end

      {:more, _partial, conn} ->
        send_resp(conn, 413, "request too large")
    end
  end
end
