defmodule Workbooks.WorkCompileTest do
  use ExUnit.Case, async: false
  alias Workbooks.Work

  defp tree(files) do
    dir = Path.join(System.tmp_dir!(), "wbcomp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, src} -> File.write!(Path.join(dir, name), src) end)
    dir
  end

  test "work compile passes on a self-consistent server tier" do
    dir =
      tree(%{
        "a.work" => "# A\n\nserver :alpha do\n  def go(x), do: x + 1\nend\n",
        "b.work" => "# B\n\nserver :beta do\n  def run(x), do: Alpha.go(x) * 2\nend\n"
      })

    {out, failed?} = Work.CLI.compile(dir)
    assert out =~ "compiled"
    assert out =~ "server tier compiles"
    refute failed?
    File.rm_rf!(dir)
  end

  test "work compile fails (non-zero) on a unit calling an undefined local helper" do
    dir =
      tree(%{
        "bad.work" => "# Bad\n\nserver :broken do\n  def go(x), do: missing_helper(x)\nend\n"
      })

    {out, failed?} = Work.CLI.compile(dir)
    assert failed?
    assert out =~ "✗ broken"
    File.rm_rf!(dir)
  end
end
