defmodule Workbooks.UnitWorkbookTest do
  use ExUnit.Case, async: false
  alias Workbooks.Unit

  setup do
    dir = Path.join(System.tmp_dir!(), "wbunit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "types.work"), """
    # Types

    defmodule Lead do
      defstruct name: "", score: 0
    end
    """)

    File.write!(Path.join([dir, "lib", "score.work"]), """
    # Score

    server :score do
      def score(%Lead{} = lead), do: %Lead{lead | score: 10}
    end
    """)

    File.write!(Path.join([dir, "lib", "report.work"]), """
    # Report

    server :report do
      def run(lead), do: Score.score(lead).score
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "compiles a workbook's type modules + server units; cross-type and cross-unit refs resolve", %{dir: dir} do
    assert %{compiled: mods, failed: []} = Unit.compile_workbook(dir)

    # Lead (type), Score, Report (servers) all compiled to their canonical names
    assert Lead in mods
    assert Score in mods
    assert Report in mods

    # cross-type: Score.score takes %Lead{} and updates it
    lead = struct(Lead, name: "acme")
    assert Score.score(lead).score == 10

    # cross-unit: Report.run calls Score.score (resolved at runtime)
    assert Report.run(lead) == 10
  end
end
