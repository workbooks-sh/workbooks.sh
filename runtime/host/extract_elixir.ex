defmodule Workbooks.Extract.Elixir do
  @moduledoc """
  §0.2 — walk a parsed Elixir code node's real AST and extract the facts the rest
  of the system needs: its **exports** (public `def`s), the **types** it declares
  (`defstruct` records, nested modules), and the **calls** it makes to other units.

  Reads `Workbooks.Literate` `:code` nodes that carried an `:ast` (the Elixir blocks).
  Returns one shape — `%{exports, types, calls}` — the SAME shape every per-language
  extractor returns, so `Workbooks.Graph` (§9) and the WIT generator (§2) merge them
  without caring which language produced them.
  """

  @type facts :: %{exports: [{atom, non_neg_integer}], imports: [], types: [tuple], calls: [tuple]}

  @spec extract(map) :: facts
  def extract(%{ast: nil}), do: empty()
  def extract(%{ast: ast}), do: from_body(do_body(ast))
  def extract(_), do: empty()

  defp empty, do: %{exports: [], imports: [], types: [], calls: []}

  defp from_body(nil), do: empty()

  defp from_body(body) do
    {_ast, {ex, ty, ca}} =
      Macro.prewalk(body, {[], [], []}, fn node, {ex, ty, ca} = acc ->
        cond do
          e = export(node) -> {node, {[e | ex], ty, ca}}
          t = type(node) -> {node, {ex, [t | ty], ca}}
          c = call(node) -> {node, {ex, ty, [c | ca]}}
          true -> {node, acc}
        end
      end)

    %{
      exports: ex |> Enum.reverse() |> Enum.uniq(),
      imports: [],
      types: ty |> Enum.reverse() |> Enum.uniq(),
      calls: ca |> Enum.reverse() |> Enum.uniq()
    }
  end

  # The unit body lives under the trailing `[do: …]` of the block call.
  defp do_body({kind, _meta, args}) when is_atom(kind) and is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  # ── exports: a public def becomes {name, arity} ──
  defp export({:def, _, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name),
    do: {name, arity(args)}

  defp export({:def, _, [{name, _, args} | _]}) when is_atom(name) and name not in [:when],
    do: {name, arity(args)}

  defp export(_), do: nil

  # ── types: a defstruct is a record; a nested defmodule is a named shape ──
  defp type({:defstruct, _, [fields]}) when is_list(fields) do
    keys = if Keyword.keyword?(fields), do: Keyword.keys(fields), else: fields
    {:record, keys}
  end

  defp type({:defmodule, _, [{:__aliases__, _, mods} | _]}), do: {:module, List.last(mods)}
  defp type(_), do: nil

  # ── calls: a remote call Mod.fun(args) → another unit/kit reference ──
  defp call({{:., _, [{:__aliases__, _, mods}, fun]}, _, args}) when is_atom(fun),
    do: {Module.concat(mods), fun, arity(args)}

  defp call(_), do: nil

  defp arity(args) when is_list(args), do: length(args)
  defp arity(_), do: 0
end
