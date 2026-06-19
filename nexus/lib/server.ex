defmodule Nexus.Server do
  @moduledoc """
  The served-nexus HTTP tier (bandit + Plug). Serves a workbook folder:

    * `GET /`               → the workbook **SSR'd** (`Nexus.Weave.weave/1`) with live Store data
    * `GET /data/:resource` → that resource's rows as JSON — the **server backend** the client
                              `nexus.data` falls back to when there's no baked island

  Start with `Nexus.Server.start_link(root: "path/to/workbook", port: 4000)`. This is the
  request-time mirror of `weave` (build-time): same render, live data. The local-only file and
  the served nexus share one render + one client API; only the data backend differs.
  """
  use Plug.Router

  # CORS first — the desktop webview / browser fetch nexus cross-origin; preflight OPTIONS is answered
  # here (before auth), and Allow-Origin is attached to every response.
  plug(Nexus.Cors)
  plug(:match)
  # Resolve + assign the request's tenant (Nexus.Auth adapter — None/Bearer/JWT). Everything below
  # is scoped to conn.assigns.tenant; the Store is partitioned, so isolation is automatic.
  plug(Nexus.Auth)
  plug(:dispatch)

  @doc "Start the HTTP server for a workbook folder."
  def start_link(opts) do
    root = Keyword.fetch!(opts, :root)
    port = Keyword.get(opts, :port, 4000)
    Application.put_env(:nexus, :workbook_root, root)
    # Register the workbook's live capabilities (fleet units) up front, so /live works regardless of
    # whether a page has been rendered yet.
    Nexus.Weave.bringup(root)
    Bandit.start_link(plug: __MODULE__, port: port)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  # Liveness probe — unauthenticated (see Nexus.Auth). Deploy/orchestrator health checks (Fly,
  # Docker, the desktop daemon) probe this; 200 = the server is up and answering.
  get "/health" do
    vsn = to_string(Application.spec(:nexus, :vsn) || "dev")
    body = Jason.encode!(%{status: "ok", service: "nexus", version: vsn})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # The RCP capabilities handshake — the FIRST thing the desktop/web RCP client fetches to learn how
  # to talk to this runtime. Public (no credential; exposes only the auth rung, never tenant data).
  get "/.well-known/workbooks-runtime" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Nexus.Rcp.capabilities()))
  end

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, cached_html(root(), Nexus.Auth.tenant(conn)))
  end

  get "/data/:resource" do
    # tenant comes from Nexus.Auth (the plug). Rows are tenant-scoped IN the Store — a request can
    # only ever read its own tenant's data.
    rows = Map.get(Nexus.Weave.data(root(), Nexus.Auth.tenant(conn)), resource, [])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(rows, escape: :html_safe))
  end

  # ── Live channel (the Dock seam for workbook `view` units) ────────────────────────────────────
  # GET /live/:source?<params> — subscribe to a registered Nexus.Live source as SSE. A woven `view`
  # template opens an EventSource here; the source (e.g. a `fleet` unit) streams events. Generic:
  # any streaming capability registers in Nexus.Live and any workbook view can bind to it.
  get "/live/:source" do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    me = self()
    emit = fn event -> send(me, {:sse, event}) end
    runner = spawn_link(fn -> Nexus.Live.run(source, params, emit); send(me, :sse_done) end)

    final = stream_sse(conn)
    if Process.alive?(runner), do: Process.exit(runner, :kill)
    final
  end

  # The desktop's agent-run target (the RCP unary `request("/api/run")` — replaces the old Phoenix
  # POST /api/agent/run). Auth-gated by the plug above (tenant scopes the run). Body: {task, system?,
  # timeout_ms?}. Runs the agent to a final answer; live token/turn streaming is a follow-up (SSE, like
  # /swarm) for the desktop UX. Returns {ok, answer} | {ok:false, error}.
  post "/api/run" do
    {:ok, body, conn} = read_body(conn)

    # Accept the desktop's body shape forward-compatibly: `task` OR `prompt` (alias); extra keys the
    # old Phoenix path sent (agent_slug/workdir/skills) are ignored, not rejected, so the desktop can
    # cut over to this route before the agent contract grows to honor them.
    with {:ok, m} when is_map(m) <- Jason.decode(body),
         task when is_binary(task) and task != "" <- m["task"] || m["prompt"] do
      opts =
        [task: task, timeout_ms: run_timeout(m["timeout_ms"])]
        |> then(fn o -> if is_binary(m["system"]) and m["system"] != "", do: [{:system, m["system"]} | o], else: o end)

      # An agent run can raise (no LLM key, a tool crash) — never 500 the endpoint; surface it as
      # {ok:false} so the client degrades gracefully.
      payload =
        try do
          case Nexus.Agent.run(opts) do
            {:ok, answer} -> %{ok: true, answer: to_string(answer)}
            {:error, reason} -> %{ok: false, error: inspect(reason)}
          end
        rescue
          e -> %{ok: false, error: Exception.message(e)}
        catch
          kind, reason -> %{ok: false, error: inspect({kind, reason})}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    else
      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(422, Jason.encode!(%{error: "task or prompt required"}))
    end
  end

  # Streaming agent run — same auth + body shape as /api/run, but the loop's typed events are pushed
  # as SSE frames (like /live) so the desktop can render live token/turn output. Ends with a
  # {"type":"end"} frame. A crash emits {"type":"error"}, never a 500. /api/run stays as the unary
  # fallback.
  post "/api/run/stream" do
    {:ok, body, conn} = read_body(conn)

    with {:ok, m} when is_map(m) <- Jason.decode(body),
         task when is_binary(task) and task != "" <- m["task"] || m["prompt"] do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      me = self()
      emit = fn event -> send(me, {:sse, event}) end

      opts =
        [task: task, timeout_ms: run_timeout(m["timeout_ms"]), emit: emit]
        |> then(fn o -> if is_binary(m["system"]) and m["system"] != "", do: [{:system, m["system"]} | o], else: o end)

      runner =
        spawn_link(fn ->
          try do
            Nexus.Agent.run(opts)
          rescue
            e -> send(me, {:sse, %{type: "error", error: Exception.message(e)}})
          catch
            kind, reason -> send(me, {:sse, %{type: "error", error: inspect({kind, reason})}})
          end

          send(me, :sse_done)
        end)

      final = stream_sse(conn)
      if Process.alive?(runner), do: Process.exit(runner, :kill)
      final
    else
      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(422, Jason.encode!(%{error: "task or prompt required"}))
    end
  end

  # Session history (the workbook's SQLite store) — the app's "past runs" list + detail.
  get "/sessions" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Nexus.Sessions.list()))
  end

  get "/sessions/:id" do
    case Integer.parse(id) do
      {n, _} ->
        case Nexus.Sessions.get(n) do
          nil -> send_resp(conn, 404, "{}")
          s -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(s))
        end

      _ ->
        send_resp(conn, 404, "{}")
    end
  end

  # The hosted control-plane API (only answers when WB_CONTROL_PLANE — else Nexus.Platform 404s, so a
  # tenant runtime is indistinguishable). Auth (the plug above) has already resolved the org tenant.
  forward("/api/platform", to: Nexus.Platform)

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Pump swarm events to the client as SSE frames until the fleet drains or the socket drops.
  defp stream_sse(conn) do
    receive do
      {:sse, event} ->
        case chunk(conn, "data: " <> Jason.encode!(event) <> "\n\n") do
          {:ok, conn} -> stream_sse(conn)
          {:error, _} -> conn
        end

      :sse_done ->
        {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(%{type: "end"}) <> "\n\n")
        conn
    after
      120_000 -> conn
    end
  end

  # Clamp the agent-run budget to [1s, 300s] (default 120s) so an /api/run request can't block forever.
  defp run_timeout(nil), do: 120_000
  defp run_timeout(n) when is_integer(n), do: n |> max(1_000) |> min(300_000)

  defp run_timeout(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> run_timeout(n)
      _ -> 120_000
    end
  end

  defp run_timeout(_), do: 120_000

  defp root, do: Application.get_env(:nexus, :workbook_root) || File.cwd!()

  # Cache the woven SSR shell by the workbook's newest .work mtime, so units compile ONCE — not per
  # request (a `show <Unit>` recompiles a wasm component, ~seconds; never on a hot path).
  #
  # MULTI-TENANT: the shell is `bake: false` — it inlines NO data, so the shared/cached shell can
  # never carry one tenant's rows to another; the client fetches its own tenant-scoped /data. Cache
  # key is just the mtime (the shell is tenant-agnostic).
  # SINGLE-TENANT (None): bake the default tenant's data into the shell as before.
  defp cached_html(root, tenant) do
    mtime = workbook_mtime(root)
    table = cache_table()
    multi = Nexus.Auth.multi?()
    key = {root, multi}

    case :ets.lookup(table, key) do
      [{^key, ^mtime, html}] ->
        html

      _ ->
        html =
          if multi,
            do: Nexus.Weave.weave(root, live: true, bake: false),
            else: Nexus.Weave.weave(root, live: true, tenant: tenant)

        :ets.insert(table, {key, mtime, html})
        html
    end
  end

  defp workbook_mtime(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.map(&File.stat!(&1).mtime)
    |> Enum.max(fn -> nil end)
  end

  defp cache_table do
    case :ets.whereis(:nexus_server_cache) do
      :undefined ->
        try do
          :ets.new(:nexus_server_cache, [:named_table, :public, :set])
        rescue
          ArgumentError -> :nexus_server_cache
        end

      _ ->
        :nexus_server_cache
    end
  end
end
