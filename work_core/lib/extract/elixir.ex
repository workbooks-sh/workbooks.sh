defmodule WorkCore.Extract.Elixir do
  @moduledoc """
  §0.2 — walk a parsed Elixir code node's real AST and extract the facts the rest
  of the system needs: its **exports** (public `def`s), the **types** it declares
  (`defstruct` records, nested modules), and the **calls** it makes to other units.

  Reads `WorkCore.Literate` `:code` nodes that carried an `:ast` (the Elixir blocks).
  Returns one shape — `%{exports, types, calls}` — the SAME shape every per-language
  extractor returns, so `WorkCore.Graph` (§9) and the WIT generator (§2) merge them
  without caring which language produced them.
  """

  @type facts :: %{exports: [{atom, non_neg_integer}], imports: [], types: [tuple], calls: [tuple]}

  @spec extract(map) :: facts
  def extract(%{ast: nil}), do: empty()
  def extract(%{ast: ast}), do: from_body(do_body(ast))
  def extract(_), do: empty()

  defp empty, do: %{exports: [], imports: [], types: [], calls: []}

  @doc "Collect the type declarations (records, enums, modules) anywhere in an AST."
  def types_in(ast) do
    {_ast, ty} =
      Macro.prewalk(ast, [], fn node, acc ->
        if t = type(node), do: {node, [t | acc]}, else: {node, acc}
      end)

    ty |> Enum.reverse() |> Enum.uniq()
  end

  @doc "Parse a flat `:decl` node's source and collect its type declarations."
  def decl_types(%{type: :decl, text: text}) do
    case Code.string_to_quoted(text, emit_warnings: false) do
      {:ok, ast} -> types_in(ast)
      _ -> []
    end
  end

  def decl_types(_), do: []

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

    types = ty |> Enum.reverse() |> Enum.uniq()

    # the canonical result variant: a body that returns both {:ok, _} and
    # {:error, _} tagged tuples declares a `result` variant (the format convention).
    types =
      if has_tag?(body, :ok) and has_tag?(body, :error),
        do: types ++ [{:variant, :result, [:ok, :err]}],
        else: types

    %{
      exports: ex |> Enum.reverse() |> Enum.uniq(),
      imports: [],
      types: types,
      calls: ca |> Enum.reverse() |> Enum.uniq()
    }
  end

  defp has_tag?(ast, tag) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {^tag, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # The unit body lives under the trailing `[do: …]` of the block call.
  defp do_body({kind, _meta, args}) when is_atom(kind) and is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil

  # ── exports: a public def becomes {name, [arg_types]} — a %Struct{} pattern types
  #    that argument as its record; everything else defaults to string ──
  defp export({:def, _, [{:when, _, [{name, _, args} | _]} | _]}) when is_atom(name),
    do: {name, arg_types(args)}

  defp export({:def, _, [{name, _, args} | _]}) when is_atom(name) and name not in [:when],
    do: {name, arg_types(args)}

  defp export(_), do: nil

  defp arg_types(args) when is_list(args), do: Enum.map(args, &arg_type/1)
  defp arg_types(_), do: []

  # `%Struct{} = var` and `%Struct{…}` patterns name a record type
  defp arg_type({:=, _, [pat, _]}), do: arg_type(pat)
  defp arg_type({:%, _, [{:__aliases__, _, mods}, _]}), do: mods |> List.last() |> to_string() |> String.downcase()
  defp arg_type(_), do: "string"

  # ── types: a defstruct is a record (fields + defaults, so WIT types can be
  #    inferred); a nested defmodule is a named shape ──
  defp type({:defstruct, _, [fields]}) when is_list(fields) do
    pairs =
      if Keyword.keyword?(fields),
        do: fields,
        else: Enum.map(fields, &{&1, nil})

    {:record, pairs}
  end

  defp type({:defmodule, _, [{:__aliases__, _, mods} | _]}), do: {:module, List.last(mods)}

  # a module attribute assigned a non-empty list of atoms is an enum:
  # `@statuses [:new, :enriched, :scored]` → {:enum, :statuses, [:new, …]}
  defp type({:@, _, [{name, _, [list]}]}) when is_atom(name) and is_list(list) do
    if list != [] and Enum.all?(list, &is_atom/1), do: {:enum, name, list}
  end

  defp type(_), do: nil

  # ── calls: a remote call Mod.fun(args) → another unit/kit reference ──
  defp call({{:., _, [{:__aliases__, _, mods}, fun]}, _, args}) when is_atom(fun),
    do: {Module.concat(mods), fun, arity(args)}

  defp call(_), do: nil

  defp arity(args) when is_list(args), do: length(args)
  defp arity(_), do: 0
end
