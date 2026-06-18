defmodule Mix.Tasks.Nexus.Serve do
  @moduledoc """
  Serve a workbook folder over HTTP — the local dev server (and the same server runs in prod).

      mix nexus.serve examples/store
      mix nexus.serve examples/store --port 8080

  `GET /` returns the workbook SSR'd (cached by file mtime — units compile once, not per request),
  `GET /data/:resource` returns live rows. The served page is `live: true`, so it shows current
  data via the client `nexus.data` API. Ctrl-C to stop.
  """
  @shortdoc "Serve a workbook folder over HTTP (dev/prod)"
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, switches: [port: :integer])
    root = List.first(rest) || "."
    port = opts[:port] || 4000

    Mix.Task.run("app.start")
    {:ok, _} = Nexus.Server.start_link(root: root, port: port)
    Mix.shell().info("nexus serving #{root} → http://127.0.0.1:#{port}  (Ctrl-C to stop)")
    Process.sleep(:infinity)
  end
end
