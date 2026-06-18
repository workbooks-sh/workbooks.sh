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
    html = Nexus.Weave.weave(root())

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
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
end
