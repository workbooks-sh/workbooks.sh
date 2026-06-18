defmodule Nexus.ToolchainTest do
  use ExUnit.Case, async: false
  @moduletag :greenfield

  test "the Zig toolchain reactor parses .work and matches WorkCore (the one toolchain, on the server)" do
    if Nexus.Toolchain.available?() do
      start_supervised!(Nexus.Toolchain)
      src = File.read!(Path.expand("../../cli/src/corpus/store.work", __DIR__))

      got = Nexus.Toolchain.parse_units(src)
      want =
        WorkCore.Literate.parse(src)
        |> Enum.filter(&(&1.type == :code and &1.name not in [nil, ""]))
        |> Enum.map(fn u -> %{name: u.name, kind: u.kind, lang: u.lang} end)

      assert got == want
    else
      IO.puts("[skip] work-toolchain.wasm not staged")
    end
  end
end

defmodule Nexus.ToolchainParseTest do
  use ExUnit.Case, async: false
  @moduletag :greenfield

  test "parse/1 (full nodes via the Zig reactor) matches WorkCore on the common fields" do
    if Nexus.Toolchain.available?() do
      start_supervised!(Nexus.Toolchain)
      src = File.read!(Path.expand("../../cli/src/corpus/store.work", __DIR__))

      # Structural conformance: the code units (name/kind/lang) match. Finer ref-token parity
      # (:atoms/@types/#tags) is a documented follow-up — see docs/WORK-CORE-DECISION.md.
      got = Nexus.Toolchain.parse(src) |> Enum.filter(&(&1["type"] == "code")) |> Enum.map(&{&1["name"], &1["kind"], &1["lang"]})
      want = WorkCore.Literate.parse(src) |> Enum.filter(&(&1.type == :code)) |> Enum.map(&{&1.name, &1.kind, &1.lang})

      assert got == want
    else
      IO.puts("[skip] reactor not staged")
    end
  end
end
