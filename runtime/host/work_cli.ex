defmodule Workbooks.Work.CLI do
  @moduledoc """
  The `work check / why / near / wit` CLI surface over a `.work` workbook tree —
  §9 (code graph) and §2 (WIT) made queryable from the command line. Pure file
  reads + the literate parse: no app boot, no NIF, safe from the escript.

  Each verb returns `{text, failed?}` so the CLI can set an exit code.
  """

  alias Workbooks.{Graph, Wit, Literate}

  @doc "work check [dir] — resolve every reference + audit caps; non-zero exit on any fault."
  def check(dir) do
    r = Graph.build_dir(dir) |> Graph.check()
    leaks = Workbooks.Audit.caps(dir)
    ok = r.ok and leaks == []

    head = "#{r.nodes} units · #{r.edges} edges"
    pass = if ok, do: ["✓ check passed — references resolve, capabilities audited"], else: []

    {Enum.join([head] ++ ref_lines(r) ++ cap_lines(leaks) ++ pass, "\n"), not ok}
  end

  defp ref_lines(%{ok: true}), do: []

  defp ref_lines(r) do
    ["✗ #{length(r.dangling_backlinks)} dangling backlink(s):"] ++
      Enum.map(r.dangling_backlinks, fn {path, label} -> "  #{Path.basename(path)}: #{label}" end)
  end

  defp cap_lines([]), do: []

  defp cap_lines(leaks) do
    ["✗ #{length(leaks)} ungranted capability use(s):"] ++
      Enum.map(leaks, fn %{unit: u, cap: c} -> "  :#{u} uses #{c} but doesn't grant it" end)
  end

  @doc "work why :unit [dir] — who depends on this unit."
  def why(dir, name) do
    deps = Graph.build_dir(dir) |> Graph.why(name)

    text =
      if deps == [],
        do: "no unit depends on :#{name}",
        else: ":#{name} ← " <> Enum.map_join(deps, ", ", &(":" <> &1))

    {text, false}
  end

  @doc "work near :unit [dir] — the unit's immediate edges, in and out."
  def near(dir, name) do
    edges = Graph.build_dir(dir) |> Graph.near(name)

    text =
      if edges == [],
        do: "no edges touch :#{name}",
        else: Enum.map_join(edges, "\n", fn e -> "  :#{e.from} —#{e.type}→ :#{e.to}" end)

    {text, false}
  end

  @doc "work wit :unit [dir] — print the generated WIT world for a unit."
  def wit(dir, name) do
    case find_unit(dir, name) do
      nil -> {"no unit named :#{name} under #{dir}", true}
      node -> {Wit.world(node), false}
    end
  end

  defp find_unit(dir, name) do
    (Path.wildcard(Path.join(dir, "*.work")) ++ Path.wildcard(Path.join(dir, "**/*.work")))
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> Literate.parse(File.read!(path)) end)
    |> Enum.find(fn n -> n.type == :code and n.name == name end)
  end
end
