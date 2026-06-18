defmodule Workbooks.Resource do
  @moduledoc """
  The shape layer for the `resource` / `record` vocabulary — the foundation of the data
  model (see `docs/DATA-LAYER-DECISION.md`). It reads a unit's **declared** domain-typed
  fields (`name :text`, `revenue :money`, `status :new | :scored`, `tags [:text]`) and
  derives sound WIT — *no inference from defaults*, so the contract never lies.

  Domain types are the author's vocabulary; each maps to exactly one WIT type. This is the
  same shape later handed to TypedStruct (client) and Ash (server); WIT is derived here.
  """

  alias Workbooks.Wit.Types

  # author's domain type → WIT scalar (the whole mapping, in one place, no guessing)
  @scalars %{text: "string", int: "s32", float: "f64", bool: "bool", money: "money", id: "string"}

  # field-position calls that are NOT fields (operations / seed data)
  @non_field ~w(seed query mutation grant action)a

  @doc "The declared fields of a resource/record unit: `[{name, type}]` (declaration order)."
  def fields(%{ast: ast}) when not is_nil(ast) do
    case do_body(ast) do
      nil -> []
      body -> body |> statements() |> Enum.flat_map(&field/1)
    end
  end

  def fields(_), do: []

  @doc "Generate the WIT for a resource/record: the field `record` + any inline `enum`s."
  def wit(%{name: name} = node) do
    fs = fields(node)
    enums = for {f, {:enum, cases}} <- fs, do: {f, cases}

    record =
      "record #{Types.wit(name)} {\n" <>
        Enum.map_join(fs, "\n", fn {f, t} -> "  #{Types.wit(f)}: #{wit_type(f, t)}," end) <>
        "\n}"

    Enum.join([record | Enum.map(enums, fn {f, cases} -> Types.enum(f, cases) end)], "\n\n")
  end

  @doc "The struct fields + type-appropriate defaults the resource compiles to."
  def struct_fields(node) do
    for {name, type} <- fields(node), do: {name, default_for(type)}
  end

  @doc """
  Compile the resource/record to a real BEAM struct module (the client-safe shape — a plain
  `defstruct`, no runtime deps, AtomVM-safe). Returns the module. WIT + Ash derive from the
  same declaration; this is what `%Lead{}` literals use.
  """
  def compile(%{name: name} = node) do
    mod = Module.concat([Macro.camelize(name)])
    defaults = struct_fields(node)

    quoted =
      quote do
        defmodule unquote(mod) do
          defstruct unquote(Macro.escape(defaults))
        end
      end

    [{module, _bin}] = Code.compile_quoted(quoted)
    module
  end

  defp default_for({:scalar, :text}), do: ""
  defp default_for({:scalar, :id}), do: ""
  defp default_for({:scalar, :int}), do: 0
  defp default_for({:scalar, :float}), do: 0.0
  defp default_for({:scalar, :bool}), do: false
  defp default_for({:scalar, :money}), do: nil
  defp default_for({:enum, [first | _]}), do: first
  defp default_for({:enum, []}), do: nil
  defp default_for({:list, _}), do: []
  defp default_for({:ref, _}), do: nil

  # ── field extraction ──

  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(single), do: [single]

  # `name :text` parses as a call `name(:text)`; skip the operations/seed calls.
  defp field({name, _meta, [type]}) when is_atom(name) and name not in @non_field do
    [{name, normalize(type)}]
  end

  defp field(_), do: []

  # ── domain type → normalized type ──

  defp normalize(atom) when is_atom(atom) do
    case Map.fetch(@scalars, atom) do
      {:ok, _} -> {:scalar, atom}
      :error -> {:ref, atom}                       # a record/resource name (e.g. :money already handled; :address)
    end
  end

  defp normalize([inner]), do: {:list, normalize(inner)}
  defp normalize({:|, _meta, _} = union), do: {:enum, enum_cases(union)}
  defp normalize(_), do: {:scalar, :text}

  defp enum_cases({:|, _meta, [a, rest]}), do: [a | enum_cases(rest)]
  defp enum_cases(atom) when is_atom(atom), do: [atom]

  # ── normalized type → WIT ──

  defp wit_type(field, {:enum, _cases}), do: Types.wit(field)      # inline enum, named for its field
  defp wit_type(_field, {:scalar, atom}), do: Map.fetch!(@scalars, atom)
  defp wit_type(_field, {:list, inner}), do: "list<#{wit_type(nil, inner)}>"
  defp wit_type(_field, {:ref, name}), do: Types.wit(name)

  defp do_body({_kind, _meta, args}) when is_list(args) do
    case List.last(args) do
      [{:do, body}] -> body
      _ -> nil
    end
  end

  defp do_body(_), do: nil
end
