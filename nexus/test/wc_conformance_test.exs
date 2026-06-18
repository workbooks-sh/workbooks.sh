defmodule Nexus.ConformanceTest do
  use ExUnit.Case, async: true

  # The zero-drift gate: the Elixir parser must produce the SAME units as the shared golden
  # (reactor/src/corpus/units.golden) that the Zig parser is ALSO tested against. One `.work` spec, two
  # conformant implementations — if this or the Zig conformance test goes red, the parsers disagree.
  @corpus Path.expand("../../reactor/src/corpus", __DIR__)

  test "Elixir parser conforms to the shared .work golden (matches the Zig CLI)" do
    got =
      (Path.wildcard(Path.join(@corpus, "*.work")) |> Enum.sort())
      |> Enum.flat_map(fn p -> Nexus.Literate.parse(File.read!(p)) end)
      |> Enum.filter(&(&1.type == :code and &1.name not in [nil, ""]))
      |> Enum.map(fn u -> "#{u.name}|#{u.kind}|#{u.lang}" end)
      |> Enum.sort()
      |> Enum.join("\n")

    want = @corpus |> Path.join("units.golden") |> File.read!() |> String.trim_trailing("\n")
    assert got == want
  end
end
