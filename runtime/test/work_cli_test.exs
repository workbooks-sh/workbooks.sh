defmodule Workbooks.Work.CLITest do
  use ExUnit.Case, async: true
  alias Workbooks.Work.CLI

  setup do
    dir = Path.join(System.tmp_dir!(), "wbcli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "enrich.work"), "# Enrich\n\nserver :enrich, grant: [net: \"x\"] do\n  def enrich(lead), do: lead\nend\n")
    File.write!(Path.join(dir, "flow.work"), "# Pipeline\n\nflow :pipeline do\n  def run(ls), do: Enum.map(ls, &Enrich.enrich/1)\nend\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "check passes on a clean tree and fails (exit) on a dangling backlink", %{dir: dir} do
    {out, failed?} = CLI.check(dir)
    assert out =~ "units"
    assert out =~ "check passed"
    refute failed?

    File.write!(Path.join(dir, "bad.work"), "# Bad\n\nSee [[Nope]].\n")
    {out2, failed2?} = CLI.check(dir)
    assert out2 =~ "dangling"
    assert out2 =~ "[[Nope]]"
    assert failed2?
  end

  test "why lists reverse dependencies", %{dir: dir} do
    {out, false} = CLI.why(dir, "enrich")
    assert out =~ ":enrich ←"
    assert out =~ ":pipeline"
  end

  test "near shows the unit's edges", %{dir: dir} do
    {out, false} = CLI.near(dir, "enrich")
    assert out =~ ":pipeline —import→ :enrich"
  end

  test "wit prints the generated world for a unit, or errors on an unknown one", %{dir: dir} do
    {out, false} = CLI.wit(dir, "enrich")
    assert out =~ "world enrich {"
    assert out =~ "import host-net;"

    {miss, true} = CLI.wit(dir, "ghost")
    assert miss =~ "no unit named :ghost"
  end
end
