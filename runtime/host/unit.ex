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
