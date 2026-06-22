defmodule Nexus.ResourceTest do
  use ExUnit.Case, async: true
  alias Nexus.Resource
  alias Nexus.Literate

  defp unit(src), do: Literate.parse(src) |> Enum.find(&(&1.type == :code))

  @lead """
  resource Lead do
    name     :text
    revenue  :money
    status   :new | :enriched | :scored
    score    :int
    tags     [:text]

    seed [%{name: "Acme", score: 70, status: :scored}]
    query :hot, where: status == :scored
  end
  """

  test "fields come from DECLARED domain types, in order — no inference" do
    fs = @lead |> unit() |> Resource.fields()

    assert fs == [
             {:name, {:scalar, :text}},
             {:revenue, {:scalar, :money}},
             {:status, {:enum, [:new, :enriched, :scored]}},
             {:score, {:scalar, :int}},
             {:tags, {:list, {:scalar, :text}}}
           ]

    # seed / query are NOT fields
    refute Enum.any?(fs, fn {n, _} -> n in [:seed, :query] end)
  end

  test "WIT is generated faithfully from the declarations" do
    wit = @lead |> unit() |> Resource.wit()

    assert wit =~ "record lead {"
    assert wit =~ "name: string,"
    assert wit =~ "revenue: money,"      # domain type :money → money record
    assert wit =~ "status: status,"      # inline enum, named for its field
    assert wit =~ "score: s32,"          # :int, declared — not guessed
    assert wit =~ "tags: list<string>,"  # element type DECLARED, not assumed
    assert wit =~ "enum status {"
    assert wit =~ "scored,"
  end

  test "compiles to a real struct with type-appropriate defaults (the client-safe shape)" do
    mod = @lead |> unit() |> Resource.compile()

    v = struct(mod, [])
    # plain struct, AtomVM-safe — only __struct__, a literal-returning __fields__/0, and the
    # __nexus_unit__/0 marker (lets Nexus.Uid.guard/1 allow recompiles); no runtime deps
    assert mod.__info__(:functions) == [__fields__: 0, __nexus_unit__: 0, __struct__: 0, __struct__: 1]
    assert is_map(v) and Map.has_key?(v, :__struct__)

    # defaults follow the DECLARED type: text→"", int→0, enum→first case, list→[]
    assert v.name == ""
    assert v.score == 0
    assert v.status == :new
    assert v.tags == []
  end

  test "a pure value resource works the same" do
    wit = unit("resource Money do\n  cents :int\n  currency :usd | :eur | :gbp\nend\n") |> Resource.wit()
    assert wit =~ "record money {"
    assert wit =~ "cents: s32,"
    assert wit =~ "currency: currency,"
    assert wit =~ "enum currency {"
  end

  # Regression for wb-o5ng: `resource Task` compiled to top-level `Elixir.Task`, clobbering the
  # stdlib concurrency module the web server's acceptors spawn through, and killed nexus boot.
  test "a resource name that would shadow a runtime module is refused — and the stdlib module survives" do
    refused = unit("resource Task do\n  tid :string\nend\n")

    assert_raise RuntimeError, ~r/would shadow the runtime module Task/, fn ->
      Resource.compile(refused)
    end

    # the real stdlib Task is untouched — the function the web server depends on still exists
    assert function_exported?(Task, :start_link, 3)
  end

  test "a non-colliding resource name compiles, carries the unit marker, and recompiles cleanly" do
    todo = unit("resource Todo do\n  tid :string\nend\n")

    mod = Resource.compile(todo)
    assert function_exported?(mod, :__nexus_unit__, 0)
    assert mod.__nexus_unit__()

    # recompiling the SAME unit is allowed even though the module is now loaded (the marker proves
    # it's ours, not a runtime module being clobbered)
    assert Resource.compile(todo) == mod
  end
end
