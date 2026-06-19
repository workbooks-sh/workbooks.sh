defmodule Nexus.Server do
  @moduledoc """
  The served-nexus HTTP tier (bandit + Plug). Serves a workbook folder:

    * `GET /`               → the workbook **SSR'd** (`Nexus.SSR.render/1`) with live Store data
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

  @doc "Start the HTTP server for a workbook folder (one workbook) or a folder of workbooks (many)."
  def start_link(opts) do
    root = Keyword.fetch!(opts, :root)
    port = Keyword.get(opts, :port, 4000)
    mounts = discover_mounts(root)
    Application.put_env(:nexus, :workbook_root, root)
    Application.put_env(:nexus, :mounts, mounts)
    # One managed data backend for this nexus (resources from every mounted workbook live in it,
    # each as its own table). In prod the injected cloud secrets win and this is a no-op.
    Nexus.Workbooks.install_dev_backend(root)
    # Bring up every mounted workbook's server tier: compile its `server`/`resource` units to live
    # BEAM modules, then call `register/0` on any that exports it (self-registering live sources).
    Enum.each(mounts, fn {_name, wb} -> bringup(wb) end)
    Bandit.start_link(plug: __MODULE__, port: port)
  end

  # ONE nexus, MANY workbooks. A root with `.work` files directly = a single workbook, served at `/`.
  # A root whose subdirectories each hold `.work` files = many workbooks, each mounted at `/<name>/`
  # on this one nexus. (Whether you want them on one nexus or several — or local vs cloud — is a
  # deploy-target choice; the runtime hosts as many workbooks as you mount here.)
  defp discover_mounts(root) do
    if Path.wildcard(Path.join(root, "*.work")) != [] do
      [{"", root}]
    else
      Path.wildcard(Path.join(root, "*"))
      |> Enum.filter(&File.dir?/1)
      |> Enum.filter(&(Path.wildcard(Path.join(&1, "*.work")) != []))
      |> Enum.map(&{Path.basename(&1), &1})
      |> Enum.sort()
    end
  end

  defp mounts, do: Application.get_env(:nexus, :mounts, [{"", root()}])
  defp multi?, do: not match?([{"", _}], mounts())
  defp wb_root(name), do: Enum.find_value(mounts(), fn {n, r} -> if n == name, do: r end)

  # Compile the workbook's units and let each server unit register its live sources.
  defp bringup(root) do
    mods =
      case Nexus.Compile.workbook(root) do
        %{beam: %{compiled: compiled}} -> compiled
        _ -> []
      end

    Enum.each(mods, fn m ->
      if function_exported?(m, :register, 0), do: m.register()
    end)
  rescue
    _ -> :ok
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

  # Desktop-app interest capture — the lander's "notify me" modal POSTs here. Public
  # (allow-listed in Nexus.Auth); stores {email, interest} in the durable waitlist.
  post "/api/waitlist" do
    {:ok, body, conn} = read_body(conn)

    payload =
      with {:ok, m} when is_map(m) <- Jason.decode(body),
           email when is_binary(email) <- m["email"],
           :ok <- Nexus.Waitlist.add(email, m["interest"] || "") do
        %{ok: true}
      else
        {:error, :invalid_email} -> %{ok: false, error: "invalid email"}
        _ -> %{ok: false, error: "email required"}
      end

    status = if payload.ok, do: 200, else: 422
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  # The RCP capabilities handshake — the FIRST thing the desktop/web RCP client fetches to learn how
  # to talk to this runtime. Public (no credential; exposes only the auth rung, never tenant data).
  get "/.well-known/workbooks-runtime" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Nexus.Rcp.capabilities()))
  end

  get "/" do
    # Single workbook → the app. Many workbooks → an index of what's mounted on this nexus.
    if multi?() do
      conn |> put_resp_content_type("text/html") |> send_resp(200, index_html())
    else
      serve_workbook(conn, root(), nil)
    end
  end

  # Serve a workbook's woven app. `base` (the mount name) injects a `<base href="/<name>/">` so the
  # island's RELATIVE urls (`live/<source>`, `data/<Resource>`) route to this mount.
  defp serve_workbook(conn, wb_root, base) do
    demo = Path.join(wb_root, "demo.html")
    html = if File.exists?(demo), do: File.read!(demo), else: cached_html(wb_root, Nexus.Auth.tenant(conn))
    html = if base, do: String.replace(html, "<head>", ~s(<head><base href="/#{base}/">), global: false), else: html
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # The nexus index — the workbooks mounted here, each a link. A seed for the template explorer.
  defp index_html do
    cards =
      Enum.map_join(mounts(), "\n", fn {name, r} ->
        ~s(<a class="c" href="/#{name}/"><b>#{he(name)}</b><span>#{he(blurb(r))}</span></a>)
      end)

    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Workbooks · this nexus</title>
    <style>body{font:16px/1.6 'Inter',system-ui,sans-serif;background:#f7f6f3;color:#37352f;max-width:860px;margin:0 auto;padding:60px 22px}
    h1{font-size:26px;letter-spacing:-.02em} p{color:#787066} .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px;margin-top:26px}
    .c{display:flex;flex-direction:column;gap:6px;padding:18px 20px;background:#fff;border:1px solid #ece9e3;border-radius:14px;text-decoration:none;color:inherit;transition:.15s}
    .c:hover{border-color:#d8d3ca;box-shadow:0 6px 20px rgba(55,53,47,.06)} .c b{font-size:16px} .c span{font-size:13px;color:#787066}</style></head>
    <body><h1>Workbooks on this nexus</h1><p>#{length(mounts())} workbook(s) mounted on this runtime.</p><div class="g">#{cards}</div></body></html>
    """
  end

  defp blurb(root) do
    case File.read(Path.join(root, "TEMPLATE.work")) do
      {:ok, c} ->
        c
        |> String.split("\n")
        |> Enum.find("", &(String.trim(&1) != "" and not String.starts_with?(&1, "#")))
        |> String.slice(0, 130)

      _ ->
        ""
    end
  end

  defp he(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")

  get "/data/:resource" do
    # tenant comes from Nexus.Auth (the plug). Rows are tenant-scoped IN the Store — a request can
    # only ever read its own tenant's data.
    rows = Map.get(Nexus.SSR.data(root(), Nexus.Auth.tenant(conn)), resource, [])

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

  # Deploy a workbook into THIS running nexus (mount it at /<name> without a restart). Body:
  # {name, path} where `path` holds the workbook's `.work` files (same machine — local dev deploy;
  # a cloud deploy uploads the files instead). The CLI `work deploy` posts here.
  post "/api/mount" do
    {:ok, body, conn} = read_body(conn)

    payload =
      with {:ok, m} when is_map(m) <- Jason.decode(body),
           name when is_binary(name) and name != "" <- m["name"],
           path when is_binary(path) <- m["path"],
           true <- File.dir?(path) and Path.wildcard(Path.join(path, "*.work")) != [] do
        mount_runtime(name, Path.expand(path))
        %{ok: true, name: name, url: "/" <> name <> "/"}
      else
        _ -> %{ok: false, error: "need {name, path}, where path holds .work files on this machine"}
      end

    status = if payload.ok, do: 200, else: 422
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  # Mount a workbook live: compile + register its units, then add it to the routing table (replacing a
  # same-named mount). Converts a single-workbook nexus to multi (the deployed apps each get /<name>).
  defp mount_runtime(name, path) do
    bringup(path)
    others = mounts() |> Enum.reject(fn {n, _} -> n == name or n == "" end)
    Application.put_env(:nexus, :mounts, Enum.sort([{name, path} | others]))
  end

  # ── one nexus, many workbooks: a mounted workbook's app + its live source + its data ──────────
  get "/:wb/data/:resource" do
    rows =
      case wb_root(wb) do
        nil -> []
        r -> Map.get(Nexus.SSR.data(r, Nexus.Auth.tenant(conn)), resource, [])
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(rows, escape: :html_safe))
  end

  get "/:wb/live/:source" do
    _ = wb
    # Source names are globally unique across mounted workbooks, so the name resolves the source.
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

  get "/:wb" do
    case wb_root(wb) do
      nil -> send_resp(conn, 404, "not found")
      r -> serve_workbook(conn, r, wb)
    end
  end

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
      # Keepalive on idle (a long synthesis/digest LLM call emits no events) — hold the connection
      # open through the whole run instead of timing out before the final report is sent.
      15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_sse(conn)
          {:error, _} -> conn
        end
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
            do: Nexus.SSR.render(root, live: true, bake: false),
            else: Nexus.SSR.render(root, live: true, tenant: tenant)

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
