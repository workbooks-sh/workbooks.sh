defmodule Workbooks.Resource.AshTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Literate, Resource}

  defp unit(src), do: Literate.parse(src) |> Enum.find(&(&1.type == :code))

  @lead """
  resource Lead do
    name     :text
    revenue  :money
    status   :new | :enriched | :scored
    score    :int
    tags     [:text]

    query :hot, where: status == :scored
    mutation :enrich do
      %{status: :enriched}
    end
  end
  """

  test "generates a valid Ash resource source from the declaration" do
    src = @lead |> unit() |> Resource.Ash.source(domain: "Demo")

    # it's syntactically valid Elixir (formatter already proved it; parse again to be sure)
    assert {:ok, _ast} = Code.string_to_quoted(src)

    assert src =~ "defmodule Lead do"
    assert src =~ "use Ash.Resource, domain: Demo"

    # fields → attributes with DECLARED types + constraints (no inference)
    assert src =~ "attribute :name, :string, public?: true"
    assert src =~ "attribute :revenue, :integer, public?: true"          # :money → integer cents
    assert src =~ "attribute :status, :atom, constraints: [one_of: [:new, :enriched, :scored]]"
    assert src =~ "attribute :score, :integer, public?: true"
    assert src =~ "attribute :tags, {:array, :string}, public?: true"

    # default CRUD + a read per query + an update per mutation
    assert src =~ "defaults [:read, :destroy]"
    assert src =~ "accept [:name, :revenue, :status, :score, :tags]"
    assert src =~ "read :hot do"
    assert src =~ "filter expr(status == :scored)"
    assert src =~ "update :enrich do"

    # seed is NOT an attribute or action
    refute src =~ "attribute :seed"
  end

  test "the real demo resource Lead generates a sensible Ash resource" do
    node = File.read!(Path.expand("../workponents/sales/05-data/data.work", File.cwd!()))
           |> Literate.parse()
           |> Enum.find(&(&1.type == :code and &1.name == "Lead"))

    src = Resource.Ash.source(node)
    assert {:ok, _} = Code.string_to_quoted(src)
    assert src =~ "attribute :status, :atom, constraints: [one_of: [:new, :enriched, :scored]]"
  end
end
