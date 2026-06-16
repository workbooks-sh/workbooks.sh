defmodule Workbooks.Conformance do
  @moduledoc """
  Build-time conformance check (wb-11ck.15): does a built component actually match
  the `workbooks:engine` world it must dock into? A Workbook component has to
  export `run` and may only import the engine Dock funcs (session-info / vfs-query
  / run-command) plus WASI. We extract the component's WIT with `wasm-tools` and
  verify it — so a malformed Workbook is caught at `work build`, not at instantiate.
  """

  # The world-level func imports the engine Dock provides. WASI interface imports
  # (wasi:...) are always allowed and ignored here.
  @engine_imports ~w(session-info vfs-query run-command)

  @doc "Conformance to the workbooks:engine world → :ok | {:error, [problem]}."
  def engine?(wasm_path) do
    case wit(wasm_path) do
      {:ok, text} ->
        problems = check_export(text) ++ check_imports(text)
        if problems == [], do: :ok, else: {:error, problems}

      err ->
        err
    end
  end

  defp wit(path) do
    env = [{"PATH", "#{Path.expand("~/.cargo/bin")}:#{System.get_env("PATH")}"}]

    case System.cmd("wasm-tools", ["component", "wit", path], stderr_to_stdout: true, env: env) do
      {out, 0} -> {:ok, out}
      {err, _} -> {:error, {:not_a_component, String.slice(err, 0, 140)}}
    end
  end

  defp check_export(text) do
    if text =~ ~r/export run: func/, do: [], else: ["missing required export `run`"]
  end

  # Only world-level func imports matter (lines `import <name>: func`); WASI
  # interface imports (`import wasi:.../...`) never match and are ignored.
  defp check_imports(text) do
    ~r/import ([a-z][a-z-]*): func/
    |> Regex.scan(text)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.reject(&(&1 in @engine_imports))
    |> Enum.map(&"undeclared Dock import `#{&1}` (not in workbooks:engine)")
  end
end
