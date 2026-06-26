defmodule Mix.Tasks.Porffor.Debug do
  @moduledoc """
  Profile a JS file through the Porffor→WASM→Washy lane and print a named hot-function report.

      mix porffor.debug path/to/file.js [--fuel N] [--top N] [--entry m] [--transpile] [--prelude P]

  `--prelude` prepends a file (e.g. the CJS prelude) before the program. The report names the hottest
  wasm functions so a runaway loop / trap localizes instantly (e.g. a dominant `__Porffor_malloc` =
  runaway allocation; repeated `__TypeError_prototype_toString` = an exception thrown every iteration).
  """
  use Mix.Task
  alias Nexus.Porffor.Debug

  @shortdoc "Profile a JS file on the Porffor→Washy lane (named hot functions + error decode)"

  @switches [fuel: :integer, top: :integer, entry: :string, transpile: :boolean, prelude: :string]

  def run(argv) do
    Mix.Task.run("app.start")
    {opts, files, _} = OptionParser.parse(argv, switches: @switches)

    case files do
      [path | _] ->
        prelude = if opts[:prelude], do: File.read!(opts[:prelude]) <> "\n", else: ""
        js = prelude <> File.read!(path)

        diag_opts =
          [
            fuel: opts[:fuel] || 2_000_000_000,
            top: opts[:top] || 25,
            entry: opts[:entry] || "m",
            transpile: opts[:transpile] || false
          ]

        case Debug.diagnose(js, diag_opts) do
          {:ok, report} -> IO.puts(Debug.format(report))
          {:error, reason} -> Mix.raise("compile/run failed: #{inspect(reason)}")
        end

      [] ->
        Mix.raise("usage: mix porffor.debug <file.js> [--fuel N] [--top N] [--prelude P]")
    end
  end
end
