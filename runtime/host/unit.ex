defmodule Workbooks.Unit do
  @moduledoc """
  Run a **server** (native-BEAM) unit: its literate Elixir body *is* a module. This
  compiles a parsed `server` unit's AST into a real module on the BEAM and invokes its
  exports — the server tier of the linguistic model, Elixir all the way down, no wasm.

  (`client`/`sandbox` units compile to wasm components instead; this is the BEAM lane.)
  A whole workbook compiles its units in dependency order — `Workbooks.Graph` gives that
  order so a unit's referenced units/types exist first; this is the single-unit step.
  """

  @doc """
  Compile a parsed `:code` unit into a BEAM module. Returns `{:ok, module}` or
  `{:error, reason}`. The unit's `do…end` body becomes the module body verbatim.
  """
  def compile(%{name: name, ast: ast}) when is_binary(name) and not is_nil(ast) do
    case do_body(ast) do
      nil ->
        {:error, :no_body}

      body ->
        mod = Module.concat([Workbooks.Units, Macro.camelize(name) <> suffix()])

        quoted =
          quote do
            defmodule unquote(mod) do
              unquote(body)
            end
          end

        try do
          [{module, _bin}] = Code.compile_quoted(quoted)
          {:ok, module}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  def compile(_), do: {:error, :not_a_unit}

  @doc """
  Compile a whole workbook's BEAM tier: its type modules (`defmodule`) and `server`
  units, each to its **canonical** module name (so a unit's `Score.score/1` and
  `%Lead{}` references resolve). Types compile first so struct refs exist; cross-unit
  *calls* resolve at runtime, so no dependency sort is needed for compilation. Returns
  `{:ok, [module]}` or `{:error, {unit_name, reason}}`. (`client`/`sandbox`/`flow`/
  `agent` units are skipped — wasm lanes / DSL macros, not plain BEAM Elixir.)
  """
  def compile_workbook(root) do
    nodes =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn p -> Workbooks.Literate.parse(File.read!(p)) end)

    types = Enum.filter(nodes, &(&1.type == :code and &1.kind == "defmodule"))
    servers = Enum.filter(nodes, &(&1.type == :code and &1.kind == "server" and &1.name))

    Enum.reduce_while(types ++ servers, {:ok, []}, fn node, {:ok, acc} ->
      case compile_named(node) do
        {:ok, mods} -> {:cont, {:ok, List.wrap(mods) ++ acc}}
        {:error, reason} -> {:halt, {:error, {node[:name] || :type, reason}}}
      end
    end)
  end

  # a type module is already a `defmodule` — compile it as-is (it names itself)
  defp compile_named(%{kind: "defmodule", ast: ast}) do
    try do
      {:ok, ast |> Code.compile_quoted() |> Enum.map(&elem(&1, 0))}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # a server unit's body becomes a module named for the unit (Score, Enrich, …)
  defp compile_named(%{kind: "server", name: name, ast: ast}) do
    case do_body(ast) do
      nil ->
        {:error, :no_body}

      body ->
        mod = Module.concat([Macro.camelize(name)])
        quoted = quote do: (defmodule unquote(mod) do unquote(body) end)

        try do
          [{module, _bin}] = Code.compile_quoted(quoted)
          {:ok, module}
        rescue
          e -> {:error, Exception.message(e)}
        end
    end
  end

  @doc "Compile a server unit and invoke one of its exported functions."
  def run(node, fun, args) when is_atom(fun) and is_list(args) do
    case compile(node) do
      {:ok, module} -> apply(module, fun, args)
      {:error, _} = err -> err
    end
  end

  # the do-block body of a `kind :name[, opts] do … end` unit
  defp do_body({_kind, _meta, args}) when is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  # keep module names unique so recompiles don't clash / warn
  defp suffix, do: "U#{System.unique_integer([:positive])}"
end
