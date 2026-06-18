defmodule Workbooks.Resource.Ash do
  @moduledoc """
  Generate **Ash resource source** from a `resource` declaration — the server database
  (see `docs/DATA-LAYER-DECISION.md`, step 2). Pure source generation: it needs no Ash
  installed to *produce* the code, so we get the parser/AST/types right first, then add the
  dep and the output compiles. Same declaration the shape layer reads → Ash attributes +
  `one_of` enums + default CRUD + a read per `query` + an update per `mutation`.
  """

  alias Workbooks.Resource

  # author's domain type → Ash attribute type. (`:money` → integer cents for now; AshMoney later.)
  @ash %{text: ":string", int: ":integer", float: ":float", bool: ":boolean", money: ":integer", id: ":string"}

  @doc "The Ash resource module source for a `resource` unit, formatted."
  def source(%{name: name} = node, opts \\ []) do
    domain = opts[:domain] || "Demo"
    data_layer = opts[:data_layer] || "Ash.DataLayer.Ets"
    mod = Macro.camelize(name)

    fields = Resource.fields(node)
    accept = "[" <> Enum.map_join(fields, ", ", fn {n, _} -> ":#{n}" end) <> "]"
    attrs = Enum.map_join(fields, "\n", fn {n, t} -> attr(n, t) end)
    custom = Enum.map_join(Resource.operations(node), "\n", &action/1)

    """
    defmodule #{mod} do
      use Ash.Resource, domain: #{domain}, data_layer: #{data_layer}

      attributes do
        uuid_primary_key :id
    #{attrs}
      end

      actions do
        defaults [:read, :destroy]
        create :create do
          accept #{accept}
        end
        update :update do
          accept #{accept}
        end
    #{custom}
      end
    end
    """
    # format paren-free, the way real Ash DSL source reads
    |> Code.format_string!(
      locals_without_parens: [
        attribute: :*,
        uuid_primary_key: :*,
        defaults: :*,
        accept: :*,
        filter: :*,
        change: :*,
        argument: :*
      ]
    )
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  @doc """
  Compile a `resource` declaration into a **live Ash resource module** (+ a domain) at
  runtime — generate the source, then `Code.compile_string`. Returns `{resource, domain}`,
  ready for `Ash.create`/`Ash.read`. This is the seam that turns a literate `.work` resource
  into a working database.
  """
  def materialize(%{name: name} = node, opts \\ []) do
    domain = opts[:domain] || Module.concat(["WbGen", "D#{System.unique_integer([:positive])}"])
    resource = Module.concat([Macro.camelize(name)])

    src =
      source(node, domain: inspect(domain)) <>
        "\n" <>
        """
        defmodule #{inspect(domain)} do
          use Ash.Domain, validate_config_inclusion?: false
          resources do
            resource #{Macro.camelize(name)}
          end
        end
        """

    Code.compile_string(src)
    {resource, domain}
  end

  # ── fields → Ash attributes ──

  defp attr(name, {:scalar, t}), do: "    attribute :#{name}, #{@ash[t]}, public?: true"

  defp attr(name, {:enum, cases}) do
    "    attribute :#{name}, :atom, constraints: [one_of: [#{Enum.map_join(cases, ", ", &":#{&1}")}]], public?: true"
  end

  defp attr(name, {:list, {:scalar, t}}), do: "    attribute :#{name}, {:array, #{@ash[t]}}, public?: true"
  defp attr(name, {:list, _}), do: "    attribute :#{name}, {:array, :string}, public?: true"
  defp attr(name, {:ref, ref}), do: "    attribute :#{name}, #{Macro.camelize(to_string(ref))}, public?: true"

  # ── operations → Ash actions ──

  defp action({:query, name, opts}) do
    filter =
      case opts[:where] do
        nil -> ""
        where -> "\n      filter expr(#{Macro.to_string(where)})"
      end

    "    read :#{name} do#{filter}\n    end"
  end

  defp action({:mutation, name, body}) do
    "    update :#{name} do\n#{changes(body)}\n    end"
  end

  # A mutation that resolves to a map of new attribute values → one `change set_attribute`
  # per key (the common case). Anything else keeps a faithful note for a hand-written change.
  defp changes(body) do
    case last_expr(body) do
      {:%{}, _meta, pairs} when pairs != [] ->
        Enum.map_join(pairs, "\n", fn {k, v} ->
          "      change set_attribute(:#{k}, #{Macro.to_string(v)})"
        end)

      _ ->
        note = body |> Macro.to_string() |> String.replace("\n", " ")
        "      # change (hand-write): #{note}"
    end
  end

  defp last_expr({:__block__, _meta, stmts}), do: List.last(stmts)
  defp last_expr(expr), do: expr
end
