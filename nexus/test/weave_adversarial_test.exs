defmodule Nexus.WeaveAdversarialTest do
  @moduledoc "The untangling — weave must never crash on hostile/malformed input, and must bound it."
  use ExUnit.Case, async: false

  defp wb(body) do
    dir = Path.join(System.tmp_dir!(), "adv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.work"), body)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "malformed .work (unclosed do) renders, does not crash" do
    html = Nexus.Weave.weave(wb("resource Bad do\n  name :text\n"))
    assert html =~ "<!doctype html>"
  end

  test "garbage / binary input does not crash the weave" do
    html = Nexus.Weave.weave(wb("\x00 not valid <<<>>> do end show ???"))
    assert html =~ "<!doctype html>"
  end

  test "XSS in a heading and in prose is escaped" do
    html = Nexus.Weave.weave(wb("# <img src=x onerror=alert(1)>\n\nhi <script>alert(2)</script> there\n"))
    refute html =~ "<img src=x onerror"
    refute html =~ "<script>alert(2)"
    assert html =~ "&lt;img" and html =~ "&lt;script&gt;"
  end

  test "a huge resource is capped (table + island), not rendered whole" do
    dir = wb("resource Big do\n  n :int\nend\n\nshow Big\n")
    mod = dir |> Path.join("a.work") |> File.read!() |> WorkCore.Literate.parse() |> Enum.find(&(&1.type == :code)) |> Nexus.Resource.compile()
    Nexus.Store.clear(mod)
    for i <- 1..600, do: Nexus.Store.create(mod, %{n: i})

    html = Nexus.Weave.weave(dir)
    # 500 capped data rows + 1 header row in the table
    assert length(Regex.scan(~r/<tr>/, html)) <= 502
    assert html =~ "showing 500 of 600"
    # the baked island is capped too (no 600th row)
    island = Regex.run(~r/application\/nexus-data[^>]*>(\[.*?\])<\/script>/s, html) |> List.last()
    assert {:ok, rows} = Jason.decode(island)
    assert length(rows) == 500
  end

  test "a render unit using an UNGRANTED cap is blocked before it runs (no compile)" do
    dir = wb("c :bad do\n  extern void emit(const char* p, int n);\n  void render(void) { emit(\"x\", 1); }\nend\n\nshow bad\n")
    html = Nexus.Weave.weave(dir)
    assert html =~ "blocked: ungranted caps" and html =~ "emit"
    # the output div is never emitted (the CSS `.unit-output{` rule is not the same string)
    refute html =~ ~s(class="unit-output")
  end
end
