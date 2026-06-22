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
    # Re-derive ephemeral working checkouts from the DURABLE bare repos (on the .nexus volume) before
    # discovering mounts — so a restart never serves an empty pushed-workspace whose checkout lived on
    # ephemeral storage. The bare repo (volume) is the source of truth; the checkout is reconstructible.
    rehydrate_checkouts(root)
    mounts = discover_mounts(root)
    # This nexus's memorable name: a stable adjective-animal codename + an optional friendly name the
    # user/team gave it (WB_NEXUS). You reference a nexus by either — it's a handle, not a credential.
    name = Nexus.Identity.codename(port)
    friendly = System.get_env("WB_NEXUS") || ""
    Application.put_env(:nexus, :nexus_name, name)
    Application.put_env(:nexus, :nexus_friendly, friendly)
    Application.put_env(:nexus, :workbook_root, root)
    Application.put_env(:nexus, :mounts, mounts)
    # One managed data backend for this nexus (resources from every mounted workbook live in it,
    # each as its own table). In prod the injected cloud secrets win and this is a no-op.
    Nexus.Workbooks.install_dev_backend(root)
    # Bring up every mounted workbook's server tier: compile its `server`/`resource` units to live
    # BEAM modules, then call `register/0` on any that exports it (self-registering live sources).
    Enum.each(mounts, fn {_name, wb} -> bringup(wb) end)
    # Every mounted workbook is now compiled + its `worker` specs registered — start them all under
    # supervision (Nexus.Worker.Supervisor). Serving-only: a pure compile/`mix test` never reaches here,
    # so background loops only run on a live nexus. Re-runs replace same-named workers (remount-safe).
    Nexus.Worker.start_all()
    # Register this nexus in the machine's nexus registry so the CLI can reach it by name.
    Nexus.Identity.register(name, friendly, "http://localhost:#{port}")
    IO.puts("⬡ nexus #{name}#{if(friendly != "", do: " (#{friendly})", else: "")} · :#{port} · #{length(mounts)} workbook(s)")
    Bandit.start_link(plug: __MODULE__, port: port)
  end

  # ONE nexus, MANY workbooks. A root with `.work` files directly = a single workbook, served at `/`.
  # A root whose subdirectories each hold `.work` files = many workbooks, each mounted at `/<name>/`
  # on this one nexus. (Whether you want them on one nexus or several — or local vs cloud — is a
  # deploy-target choice; the runtime hosts as many workbooks as you mount here.)
  defp discover_mounts(root) do
    root_works = Path.wildcard(Path.join(root, "*.work"))

    # A folder containing `index.work` is a WORKBOOK ROOT (a served surface). For the deploy-as-index-tree
    # layout the root's own index.work is the deploy MANIFEST, not a surface — every OTHER folder with an
    # index.work (at any depth) is a surface, mounted at its path RELATIVE to root. This is what lets a
    # workspace be a subtree (`site/lander` → mounted "site/lander", served at /site/lander) instead of
    # forcing every surface to be a single top-level folder. See nexus/docs/deploy-as-index-tree.md.
    surfaces =
      (Path.wildcard(Path.join(root, "**/index.work")) ++ root_works)
      |> Enum.filter(&(Path.basename(&1) == "index.work"))
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == root))
      |> Enum.map(&{Path.relative_to(&1, root), &1})
      |> Enum.sort()

    # Legacy fallback: workbooks that don't carry an index.work — immediate subdirs with any *.work.
    subs =
      Path.wildcard(Path.join(root, "*"))
      |> Enum.filter(&File.dir?/1)
      |> Enum.filter(&(Path.wildcard(Path.join(&1, "*.work")) != []))
      |> Enum.map(&{Path.basename(&1), &1})
      |> Enum.sort()

    only_manifest? = root_works != [] and Enum.all?(root_works, &(Path.basename(&1) == "index.work"))

    cond do
      # Manifest root + nested surfaces → the monorepo/subtree layout (mounts are relative paths).
      only_manifest? and surfaces != [] -> surfaces
      # A real root workbook (root .work that isn't only the manifest) → single workbook at "/".
      root_works != [] and not (only_manifest? and subs != []) -> [{"", root}]
      surfaces != [] -> surfaces
      subs != [] -> subs
      true -> [{"", root}]
    end
  end

  defp mounts, do: Application.get_env(:nexus, :mounts, [{"", root()}])
  defp multi?, do: not match?([{"", _}], mounts())

  # Re-check-out each durable bare repo (`.nexus/repos/<name>.git`, on the persistent volume) into its
  # working dir (`<data_dir>/<name>`, ephemeral) when that checkout is missing/empty. Idempotent: a
  # populated checkout is left alone. Best-effort — a failure for one repo never blocks boot.
  defp rehydrate_checkouts(root) do
    repos = Nexus.GitHttp.repos_root()

    case File.ls(repos) do
      {:ok, names} ->
        for n <- names, String.ends_with?(n, ".git") do
          ws = String.replace_suffix(n, ".git", "")
          bare = Path.join(repos, n)
          work = Path.join(root, ws)

          empty? =
            case File.ls(work) do
              {:ok, []} -> true
              {:error, _} -> true
              _ -> false
            end

          cond do
            Nexus.Git.bare?(bare) and empty? ->
              File.mkdir_p!(work)
              Nexus.Git.checkout_into(bare, work)

            Nexus.Git.bare?(bare) ->
              # Already-populated checkout: still attach jj (best-effort, no-op unless substrate is on)
              # so existing workspaces gain an op-log on boot without a re-checkout.
              Nexus.Git.maybe_colocate(bare, work)

            true ->
              :ok
          end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Re-discover the data volume's mounts and re-bring-up their units — called after a `git push` lands a
  new/updated workspace so its server/client/resource units compile + serve without a restart. The
  workspace's FILES are already live (read off disk); this refreshes the compiled tier. Idempotent.
  """
  def remount do
    root = root()
    # A pushed workbook may declare a new deploy MODE (auth/database) in its index.work — re-apply it
    # so the just-landed workbook runs in the same mode locally as it would in cloud (no reboot needed).
    Nexus.Application.apply_deploy_mode()
    found = discover_mounts(root)
    Application.put_env(:nexus, :mounts, found)
    :persistent_term.put({__MODULE__, :assetver}, %{})   # new files → recompute asset versions
    Enum.each(found, fn {_name, wb} -> bringup(wb) end)
    length(found)
  end

  # Compile the workbook's units and let each server unit register its live sources.
  defp bringup(root) do
    mods =
      case Nexus.Compile.workbook(root) do
        %{beam: %{compiled: compiled}} -> compiled
        _ -> []
      end

    Enum.each(mods, fn m ->
      if function_exported?(m, :register, 0), do: m.register()
      # Register any routes the unit declared with `route "GET /path", :fun` (baked at compile).
      Nexus.Router.install(m)
    end)

    # Load this workbook's `auth do protect/public end` policy into the guard table (no-op if absent).
    for {_f, nodes} <- parse_workbook(root),
        n <- nodes,
        n.type == :code and n.kind == "auth",
        do: Nexus.Auth.Guard.load(n.ast)
  rescue
    _ -> :ok
  end

  defp parse_workbook(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.map(fn p -> {p, Nexus.Literate.parse(File.read!(p))} end)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  # Liveness probe — unauthenticated (see Nexus.Auth). Deploy/orchestrator health checks (Fly,
  # Docker, the desktop daemon) probe this; 200 = the server is up and answering.
  # Git smart-HTTP — the nexus as a git remote. `git push https://x:<wbk_PAT>@host/git/<ws>.git main`.
  # Self-authed (Basic PAT) inside Nexus.GitHttp; the Nexus.Auth plug skips /git/*. Covers info/refs +
  # git-upload-pack + git-receive-pack for every workspace repo.
  match "/git/*glob" do
    Nexus.GitHttp.handle(conn, Enum.join(glob, "/"))
  end

  get "/health" do
    vsn = to_string(Application.spec(:nexus, :vsn) || "dev")
    name = Application.get_env(:nexus, :nexus_name, "")
    friendly = Application.get_env(:nexus, :nexus_friendly, "")
    body = Jason.encode!(%{status: "ok", service: "nexus", version: vsn, nexus: name, friendly: friendly})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # (A waitlist / interest capture is NOT a runtime concern — THE LINE. It's our own workbook:
  # `dogfood/waitlist` declares a `resource Signup` + a `server :waitlist` live source that
  # validates + persists via the generic `Nexus.Store`. Any workbook captures data the same way.)

  # The RCP capabilities handshake — the FIRST thing the desktop/web RCP client fetches to learn how
  # to talk to this runtime. Public (no credential; exposes only the auth rung, never tenant data).
  get "/.well-known/workbooks-runtime" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Nexus.Rcp.capabilities()))
  end

  # Native auth: begin a provider login (state/nonce CSRF + redirect to the provider). Public.
  # The matching `/auth/:provider/callback` lands with the callback slice (bd wb-ahr6).
  get "/auth/:provider/login" do
    Nexus.Auth.Provider.login(conn, provider)
  end

  # Provider redirects back here with ?code=&state= → verify, exchange, issue session. Public.
  get "/auth/:provider/callback" do
    Nexus.Auth.Provider.callback(conn, provider)
  end

  # Native email/password auth (our own — no external IdP). All public; a verified credential issues
  # a Nexus.Auth.Session cookie. See Nexus.Auth.Native.
  post("/auth/signup", do: Nexus.Auth.Native.signup(conn))
  post("/auth/login", do: Nexus.Auth.Native.login(conn))
  post("/auth/logout", do: Nexus.Auth.Native.logout(conn))
  get("/auth/verify", do: Nexus.Auth.Native.verify(conn))
  post("/auth/forgot", do: Nexus.Auth.Native.forgot(conn))
  post("/auth/reset", do: Nexus.Auth.Native.reset(conn))

  get "/" do
    # Single workbook → the app. Many workbooks → an index of what's mounted on this nexus.
    if multi?() do
      conn |> put_resp_content_type("text/html") |> send_resp(200, index_html())
    else
      serve_workbook(conn, root(), nil)
    end
  end

  # Serve a workbook's woven app. `base` (the mount name) injects a `<base href="/<name>/_v/<ver>/">`.
  # The mount path routes the island's RELATIVE urls to this mount; the `_v/<ver>/` segment is an
  # asset-version stamp (hash of the mount's files) so EVERY relative asset URL — including nested ES
  # module imports, which resolve against their importer's URL — changes on each deploy. That is a
  # content-addressed cache bust with no manual token and full nested-graph coverage. The serve side
  # strips `_v/<ver>/` (see dispatch_mount); the site-mode router ignores it (see Nexus.SSR).
  defp serve_workbook(conn, wb_root, base) do
    demo = Path.join(wb_root, "demo.html")
    html = if File.exists?(demo), do: File.read!(demo), else: cached_html(wb_root, Nexus.Auth.tenant(conn))
    html = if base, do: String.replace(html, "<head>", ~s(<head><base href="/#{base}/_v/#{asset_version(wb_root)}/">), global: false), else: html
    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # A short content version for a mount's assets — phash2 over every file's {relpath, mtime, size}.
  # Memoized per root (cleared on remount), so it's computed once per deploy, not per request.
  defp asset_version(root) do
    cache = :persistent_term.get({__MODULE__, :assetver}, %{})

    case cache do
      %{^root => v} ->
        v

      _ ->
        v = compute_asset_version(root)
        :persistent_term.put({__MODULE__, :assetver}, Map.put(cache, root, v))
        v
    end
  end

  defp compute_asset_version(root) do
    sig =
      Path.wildcard(Path.join(root, "**/*"))
      |> Enum.reject(&String.contains?(&1, "/node_modules/"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map(fn f ->
        case File.stat(f) do
          {:ok, s} -> {Path.relative_to(f, root), s.mtime, s.size}
          _ -> {f, 0, 0}
        end
      end)

    Integer.to_string(:erlang.phash2(sig), 32)
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
    <body><h1>⬡ #{he(nexus_label())}</h1><p>#{length(mounts())} workbook(s) mounted on this nexus.</p><div class="g">#{cards}</div></body></html>
    """
  end

  defp nexus_label do
    name = Application.get_env(:nexus, :nexus_name, "nexus")
    case Application.get_env(:nexus, :nexus_friendly, "") do
      "" -> name
      f -> "#{f} · #{name}"
    end
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
        actual = mount_runtime(name, Path.expand(path))
        %{ok: true, name: actual, url: "/" <> actual <> "/"}
      else
        _ -> %{ok: false, error: "need {name, path}, where path holds .work files on this machine"}
      end

    status = if payload.ok, do: 200, else: 422
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  # Mount a workbook live: compile + register its units, then add it to the routing table. Redeploying
  # the SAME workbook (same path) keeps its mount name; a DIFFERENT workbook wanting a taken name gets
  # a unique one (foo, foo-2, …) — names stay unique on a nexus. Returns the actual mount name.
  defp mount_runtime(name, path) do
    actual = mount_name(name, path)
    bringup(path)
    others = mounts() |> Enum.reject(fn {n, p} -> n == actual or p == path or n == "" end)
    Application.put_env(:nexus, :mounts, Enum.sort([{actual, path} | others]))
    actual
  end

  defp mount_name(name, path) do
    case Enum.find(mounts(), fn {_n, p} -> p == path end) do
      {existing, _} -> existing
      nil -> dedupe(name, MapSet.new(Enum.map(mounts(), &elem(&1, 0))), 1)
    end
  end

  defp dedupe(name, taken, n) do
    cand = if n == 1, do: name, else: "#{name}-#{n}"
    if MapSet.member?(taken, cand), do: dedupe(name, taken, n + 1), else: cand
  end

  # Resolve a request's path segments to the deepest mounted workbook (LONGEST mount-name prefix), so a
  # nested surface like "site/lander" wins over a shallower "site". Returns {name, root, tail_segments}
  # or nil. This is what makes subtree mounts (deploy-as-index-tree) routable.
  defp resolve_mount(segments) do
    mounts()
    |> Enum.reduce(nil, fn {name, root}, best ->
      nseg = if name == "", do: [], else: String.split(name, "/")

      if prefix?(nseg, segments) and (best == nil or length(nseg) > length(elem(best, 0))) do
        {nseg, name, root}
      else
        best
      end
    end)
    |> case do
      nil -> nil
      {nseg, name, root} -> {name, root, Enum.drop(segments, length(nseg))}
    end
  end

  defp prefix?([], _), do: true
  defp prefix?([h | t1], [h | t2]), do: prefix?(t1, t2)
  defp prefix?(_, _), do: false

  # One entry point for any mounted-workbook path: resolve the mount, then dispatch the tail to the
  # workbook's app / source / graph / data / live / static asset (handles flat AND nested mounts).
  defp handle_mount(conn, segments) do
    case resolve_mount(segments) do
      nil -> route_or_404(conn)
      {name, root, tail} -> dispatch_mount(conn, name, root, tail)
    end
  end

  defp dispatch_mount(conn, name, root, tail) do
    # Strip the asset-version segment (`_v/<ver>/…`) injected into <base href> — it's purely a cache
    # key; the real file is at the un-versioned path. Any version value maps to the current files.
    tail = case tail do
      ["_v", _ver | rest] -> rest
      _ -> tail
    end

    case tail do
      [] -> serve_workbook(conn, root, name)
      ["source"] -> mount_source(conn, root)
      ["graph"] -> mount_graph(conn, root)
      ["data", resource] -> mount_data(conn, root, resource)
      ["live", source] -> mount_live(conn, source)
      rest ->
        with :skip <- serve_static(conn, root, Enum.join(rest, "/")),
             :skip <- try_route(conn) do
          serve_workbook(conn, root, name)
        else
          {:served, c} -> c
        end
    end
  end

  # A mounted workbook's SOURCE — its `.work` files (name + content), ordered index → design → ui →
  # rest. Read-only; powers the templates explorer (look at the literate source behind an app).
  defp mount_source(conn, root) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(workbook_source(root), escape: :html_safe))
  end

  # A mounted workbook's STRUCTURE GRAPH — the literate code-graph (every client/server/resource/data
  # unit + its dependency edges, classified work/native/wasm) joined with the live utilization overlay
  # (telemetry runs/tokens/latency + DB schema + compiled artifact). Default = JSON; `?format=html` →
  # the self-contained interactive force-directed viz.
  defp mount_graph(conn, root) do
    g = Nexus.Graph.build_dir(root) |> Nexus.Graph.with_overlay(Nexus.Telemetry.overlay())
    format = Plug.Conn.fetch_query_params(conn).query_params["format"]

    if format == "html" do
      conn |> put_resp_content_type("text/html") |> send_resp(200, Nexus.Graph.Viz.to_html(g))
    else
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(graph_summary(g), escape: :html_safe))
    end
  end

  # Project the graph into a dashboard-friendly payload: the kind/lang breakdown (client vs server vs
  # resource vs data …), per-unit utilization (the telemetry overlay), and the dependency edges.
  defp graph_summary(%Nexus.Graph{nodes: nodes, edges: edges}) do
    all = Map.values(nodes)
    # `dep` nodes are external dependencies the units wire to (modules / packages / endpoints) — they
    # render in the graph but aren't counted as workbook units in the headline / kind breakdown.
    units = Enum.reject(all, &(&1.kind == "dep"))

    %{
      units: length(units),
      byKind: Enum.frequencies_by(units, & &1.kind),
      byLang: Enum.frequencies_by(units, & &1.lang),
      deps: length(all) - length(units),
      nodes:
        Enum.map(all, fn n ->
          %{
            id: n.id,
            kind: n.kind,
            lang: n.lang,
            file: n.file,
            deps: Enum.count(edges, &(&1.from == n.id)),
            observed: n.facets[:observed]
          }
        end),
      edges: Enum.map(edges, fn e -> %{from: e.from, to: e.to, type: e.type, layer: e.layer} end)
    }
  end

  defp workbook_source(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.sort_by(fn p ->
      b = Path.basename(p)
      {(b == "index.work" && 0) || (b == "design.work" && 1) || (b == "ui.work" && 2) || 3, p}
    end)
    |> Enum.map(fn p -> %{name: Path.relative_to(p, root), content: File.read!(p)} end)
  end

  # ── one nexus, many workbooks: a mounted workbook's app + its live source + its data ──────────
  defp mount_data(conn, root, resource) do
    rows = Map.get(Nexus.SSR.data(root, Nexus.Auth.tenant(conn)), resource, [])
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(rows, escape: :html_safe))
  end

  defp mount_live(conn, source) do
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
    handle_mount(conn, [wb])
  end

  # Deep paths under a mounted workbook (`/documentation/introduction/what-is-the-nexus`) are the
  # history-routed pages of a site-mode `app` SPA. The server serves the same SPA shell for any
  # sub-path; the in-page router reads `location.pathname` and shows the matching page. (Real
  # sub-resources — source/data/live — are matched by the explicit routes above, so they win.)
  get "/:wb/*rest" do
    handle_mount(conn, [wb | rest])
  end

  # Explicit workbook routes (Nexus.Router) are tried wherever a built-in route would otherwise 404 —
  # here (the true catch-all) and in the `/:wb` mount-miss branches (a declared `route "/api/x"` whose
  # first segment looks like a mount name). A `server` unit's `route "GET /api/orders", :list` is served.
  match _ do
    route_or_404(conn)
  end

  # Try a declared route for this request; serve it, or 404. Mount-aware paths reach here only when no
  # mount matched, so global declared routes get their chance before we give up.
  defp route_or_404(conn) do
    # Single-workbook mode: a top-level real file (`/fonts/x.woff2`, `/og.jpg`) is a static asset.
    static = if multi?(), do: :skip, else: serve_static(conn, root(), conn.request_path)

    case static do
      {:served, c} -> c
      :skip -> (case try_route(conn) do
                  {:served, c} -> c
                  :skip -> send_resp(conn, 404, "not found")
                end)
    end
  end

  # Dispatch an explicit declared route (Nexus.Router) for this request. `{:served, conn}` or `:skip`.
  defp try_route(conn) do
    case Nexus.Router.match(conn.method, conn.request_path) do
      {mod, fun, params} ->
        conn = Plug.Conn.fetch_query_params(conn)
        {:ok, body, conn} = read_body(conn)

        req = %{
          params: params,
          query: conn.query_params,
          body: decode_body(body),
          # The RAW body + request headers — needed by webhook handlers that must HMAC-verify the exact
          # bytes a provider signed (e.g. GitHub's X-Hub-Signature-256). Generic: any route can read them.
          raw_body: body,
          headers: Map.new(conn.req_headers),
          method: conn.method,
          path: conn.request_path,
          host: conn.host,
          scheme: to_string(conn.scheme),
          tenant: Nexus.Auth.tenant(conn)
        }

        {status, ctype, out} = Nexus.Router.dispatch(mod, fun, req)
        {:served, conn |> put_resp_content_type(ctype) |> send_resp(status, out)}

      nil ->
        :skip
    end
  end

  # Serve a workbook's static asset (fonts, images, css, js) from its mount dir. THE LINE: generic —
  # any workbook's bundled assets travel with it. `{:served, conn}` when a real, in-bounds, non-source
  # file is sent; `:skip` otherwise (→ SPA shell / router / 404). Path-traversal-safe; `.work` source
  # is NOT served here by default (it stays behind the intentional `/source` route).
  defp serve_static(conn, mount_root, rel) do
    rel = rel |> to_string() |> String.split("?", parts: 2) |> hd() |> URI.decode() |> String.trim_leading("/")
    root = Path.expand(mount_root)
    full = Path.expand(Path.join(root, rel))

    cond do
      # containment guard — the resolved path must stay inside the mount (no `..` escape)
      full != root and not String.starts_with?(full, root <> "/") -> :skip
      Path.extname(full) == ".work" -> :skip
      # never serve the durable store / hidden runtime data (.nexus/, *.db, WAL/SHM sidecars)
      dotted_or_db?(rel) -> :skip
      File.regular?(full) ->
        {:served, serve_file_cached(conn, full)}

      true ->
        :skip
    end
  end

  # Native static caching: a strong ETag (size+mtime) + a short max-age. Repeat loads send
  # If-None-Match → we answer 304 (no body) instead of re-shipping the asset, so a warm dashboard
  # reload pays only revalidation, not the full JS/CSS/font payload. max-age keeps it out of the
  # network entirely for a minute; the ETag makes a deploy visible on the next revalidate.
  defp serve_file_cached(conn, full) do
    stat = File.stat!(full)
    msecs = :calendar.datetime_to_gregorian_seconds(stat.mtime)
    etag = ~s("#{Integer.to_string(stat.size, 16)}-#{Integer.to_string(msecs, 16)}")
    conn = conn |> put_resp_header("etag", etag) |> put_resp_header("cache-control", "public, max-age=60")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      ct = MIME.from_path(full)
      conn = put_resp_content_type(conn, ct)

      # gzip compressible text assets on the fly (JS/CSS/SVG/JSON/HTML) — Bandit doesn't auto-compress,
      # so without this every asset ships raw (~4x larger). Binary (fonts/images) is already compressed.
      if compressible?(ct) and gzip_accepted?(conn) do
        body = :zlib.gzip(File.read!(full))
        conn |> put_resp_header("content-encoding", "gzip") |> put_resp_header("vary", "accept-encoding") |> send_resp(200, body)
      else
        send_file(conn, 200, full)
      end
    end
  end

  defp compressible?(ct) do
    String.starts_with?(ct, "text/") or
      ct in ~w(application/javascript text/javascript application/json image/svg+xml application/xml application/wasm)
  end

  defp gzip_accepted?(conn) do
    case get_req_header(conn, "accept-encoding") do
      [ae | _] -> String.contains?(ae, "gzip")
      _ -> false
    end
  end

  # True if any path segment is a dotfile/dir (e.g. `.nexus/`) or the file is a SQLite store file —
  # these are runtime data, never servable assets.
  defp dotted_or_db?(rel) do
    segs = String.split(rel, "/", trim: true)
    Enum.any?(segs, &String.starts_with?(&1, ".")) or
      Path.extname(rel) in [".db", ".sqlite", ".sqlite3"] or
      String.ends_with?(rel, "-wal") or String.ends_with?(rel, "-shm")
  end

  # Request bodies arrive as raw strings; decode JSON when it is JSON, else pass the raw string.
  defp decode_body(""), do: nil
  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, v} -> v
      _ -> body
    end
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
