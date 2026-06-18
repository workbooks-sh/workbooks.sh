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

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, cached_html(root()))
  end

  get "/data/:resource" do
    rows = Map.get(Nexus.Weave.data(root()), resource, [])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(rows, escape: :html_safe))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp root, do: Application.get_env(:nexus, :workbook_root) || File.cwd!()

  # Cache the woven shell by the workbook's newest .work mtime, so units compile ONCE — not per
  # request (a `show <Unit>` recompiles a wasm component, ~seconds; never do that on a hot path).
  # Served HTML is `live: true`, so the cached shell still shows current data (the client fetches
  # /data); the cache re-weaves only when a .work file changes. The /data endpoint is always live.
  defp cached_html(root) do
    mtime = workbook_mtime(root)
    table = cache_table()

    case :ets.lookup(table, root) do
      [{^root, ^mtime, html}] ->
        html

      _ ->
        html = Nexus.Weave.weave(root, live: true)
        :ets.insert(table, {root, mtime, html})
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
