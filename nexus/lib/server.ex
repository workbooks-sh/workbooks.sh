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

  match _ do
    send_resp(conn, 404, "not found")
  end

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
