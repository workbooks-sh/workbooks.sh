defmodule Workbooks.ResourceTest do
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

  test "a pure value record works the same" do
    wit = unit("record Money do\n  cents :int\n  currency :usd | :eur | :gbp\nend\n") |> Resource.wit()
    assert wit =~ "record money {"
    assert wit =~ "cents: s32,"
    assert wit =~ "currency: currency,"
    assert wit =~ "enum currency {"
  end
end
