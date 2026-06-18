defmodule Workbooks.WitEmitTest do
  use ExUnit.Case, async: true
  alias Workbooks.Wit

  setup do
    dir = Path.join(System.tmp_dir!(), "wbemit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "types.work"), """
    # Types

    defmodule Lead do
      defstruct name: "", revenue: 0, status: :new
    end

    @statuses [:new, :enriched, :scored]
    """)

    File.write!(Path.join([dir, "lib", "enrich.work"]), """
    # Enrich

    server :enrich, grant: [net: "api.crm.com"] do
      def enrich(%Lead{} = lead) do
        case lookup(lead) do
          {:ok, l} -> {:ok, l}
          {:error, r} -> {:error, r}
        end
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "emit/1 produces a file interface + per-unit worlds across the tree", %{dir: dir} do
    out = Wit.emit(dir)

    # the types file → a shared interface (record + enum), no unit worlds
    types = out[Path.join(dir, "types.work")]
    assert types.interface =~ "interface types {"
    assert types.interface =~ "record lead {"
    assert types.interface =~ "status: statuses,"
    assert types.worlds == %{}

    # the enrich unit → a world with a typed export, the grant import, and the variant
    enrich = out[Path.join([dir, "lib", "enrich.work"])]
    world = enrich.worlds["enrich"]
    assert world =~ "world enrich {"
    assert world =~ "export enrich: func(a0: lead) -> string;"
    assert world =~ "import host:net/fetch;"
    assert world =~ "variant result {"
  end

  test "emit/1 over the real demo tree generates a world for every unit", %{dir: _dir} do
    demo = Path.expand("../workponents/sales", File.cwd!())

    if File.dir?(demo) do
      out = Wit.emit(demo)
      worlds = out |> Map.values() |> Enum.flat_map(&Map.keys(&1.worlds))
      assert "score" in worlds
      assert "enrich" in worlds
      assert "pipeline" in worlds
    end
  end
end
