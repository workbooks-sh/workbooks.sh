defmodule Workbooks.Work.CLI do
  @moduledoc """
  The `work check / why / near / wit` CLI surface over a `.work` workbook tree —
  §9 (code graph) and §2 (WIT) made queryable from the command line. Pure file
  reads + the literate parse: no app boot, no NIF, safe from the escript.

  Each verb returns `{text, failed?}` so the CLI can set an exit code.
  """

  alias Workbooks.{Graph, Wit, Literate}

  @doc "work check [dir] — resolve every reference; non-zero exit if any dangle."
  def check(dir) do
    r = Graph.build_dir(dir) |> Graph.check()

    head = "#{r.nodes} units · #{r.edges} edges"

    body =
      if r.ok do
        ["✓ check passed — every reference resolves"]
      else
        ["✗ #{length(r.dangling_backlinks)} dangling backlink(s):"] ++
          Enum.map(r.dangling_backlinks, fn {path, label} -> "  #{Path.basename(path)}: #{label}" end)
      end

    {Enum.join([head | body], "\n"), not r.ok}
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
