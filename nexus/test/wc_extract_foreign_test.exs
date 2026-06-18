defmodule Nexus.Extract.ForeignTest do
  use ExUnit.Case, async: true
  alias Nexus.{Literate, Extract}

  defp facts(src) do
    [code] = Literate.parse(src) |> Enum.filter(&(&1.type == :code))
    Extract.facts(code)
  end

  test "rust: pub fn → exports; extern + wasm_import_module → imports" do
    src = """
    rust :forecast do
      #[link(wasm_import_module = "kernel")]
      extern "C" {
        fn project_series(base: *const f64);
      }
      pub fn forecast(leads: &[f64]) -> f64 { 0.0 }
    end
    """

    f = facts(src)
    assert "forecast" in f.exports
    assert "project_series" in f.imports
    assert "kernel" in f.imports
  end

  test "zig: export fn → exports" do
    f = facts("zig :kernel do\n  export fn project_series(x: f64) void {}\nend\n")
    assert "project_series" in f.exports
  end

  test "python: top-level def → exports" do
    f = facts("python :risk do\n  def risk_score(lead):\n    return 0\nend\n")
    assert "risk_score" in f.exports
  end

  test "svelte/solid: export function + work:// import" do
    src = """
    client solid :panel do
      import { chart } from "work://chart"
      export function Panel(props) { return null }
    end
    """

    f = facts(src)
    assert "Panel" in f.exports
    assert "chart" in f.imports
  end

  test "the graph turns a foreign work:// import into a typed import edge" do
    dir = Path.join(System.tmp_dir!(), "wbfgn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "chart.work"), "# Chart\n\nclient svelte :chart do\n  export function Chart() {}\nend\n")

    File.write!(Path.join(dir, "panel.work"), """
    # Panel

    client solid :panel do
      import { chart } from "work://chart"
      export function Panel() {}
    end
    """)

    g = Nexus.Graph.build_dir(dir)
    assert Enum.any?(g.edges, &(&1.from == "panel" and &1.to == "chart" and &1.type == :import and &1.scope == :unit))
    assert "panel" in Nexus.Graph.why(g, "chart")
    File.rm_rf!(dir)
  end
end
