defmodule WorkCLI.Work do
  @moduledoc """
  The local `.work` verbs — `check / why / near / wit / structure` — over the shared `work_core`
  toolchain (`WorkCore.Graph` / `Wit` / `Literate`). Pure file reads + parse: no engine, no network.
  Each verb prints through `WorkCore.Log` and returns `:ok | {:error, _}` for the CLI's exit code.
  """

  alias WorkCore.{Graph, Wit, Literate, Audit, Log}

  @doc "work check [dir] — resolve every reference + backlink AND audit capability grants across the tree."
  def check(dir) do
    r = dir |> Graph.build_dir() |> Graph.check()
    leaks = Audit.workbook(dir)
    Log.prompt("work check #{dir}")

    counts = "#{r.nodes} units · #{r.edges} edges"

    if r.ok and leaks == %{} do
      Log.ok(counts, detail: "references resolve · capabilities audited")
      :ok
    else
      faults = length(r.dangling_backlinks) + length(r.dangling_edges) + map_size(leaks)
      Log.error(counts, detail: "#{faults} fault(s)")

      for {path, label} <- r.dangling_backlinks do
        Log.step("dangling ref " <> Log.path(label) <> " in #{Path.basename(path)}")
      end

      for e <- r.dangling_edges do
        Log.step("#{e.from} —#{e.type}→ " <> Log.path("#{e.to}") <> " (missing)")
      end

      for {unit, caps} <- leaks, c <- caps do
        Log.step(Log.cmd(":#{unit}") <> " uses " <> Log.path(c) <> " but doesn't grant it")
      end

      {:error, :faults}
    end
  end

  @doc "work lint [dir] — alias of check (resolve references + audit capabilities)."
  def lint(dir), do: check(dir)

  @doc "work why :unit [dir] — who depends on this unit."
  def why(name, dir) do
    deps = dir |> Graph.build_dir() |> Graph.why(name)
    Log.prompt("work why :#{name} #{dir}")

    if deps == [] do
      Log.step("no unit depends on :#{name}")
    else
      Log.ok(":#{name}", detail: "#{length(deps)} dependent(s)")
      for d <- deps, do: Log.step(":#{name} ← " <> Log.path(":#{d}"))
    end

    :ok
  end

  @doc "work near :unit [dir] — the unit's immediate edges, in and out."
  def near(name, dir) do
    edges = dir |> Graph.build_dir() |> Graph.near(name)
    Log.prompt("work near :#{name} #{dir}")

    if edges == [] do
      Log.step("no edges touch :#{name}")
    else
      Log.ok(":#{name}", detail: "#{length(edges)} edge(s)")
      for e <- edges, do: Log.step(Log.path(":#{e.from}") <> " —#{e.type}→ " <> Log.path(":#{e.to}"))
    end

    :ok
  end

  @doc "work wit :unit [dir] — print the generated WIT world for a unit."
  def wit(name, dir) do
    Log.prompt("work wit :#{name} #{dir}")

    case find_unit(dir, name) do
      nil ->
        Log.error("no unit named :#{name} under #{dir}")
        {:error, :no_unit}

      node ->
        case Wit.world(node) do
          nil -> (Log.error("no WIT world for :#{name}"); {:error, :no_world})
          world -> (Log.info(""); IO.puts(world); :ok)
        end
    end
  end

  @doc "work weave <dir> <out.html> — weave the .work tree into one self-contained HTML workbook."
  def weave(dir, out) do
    Log.prompt("work weave #{dir} → #{out}")
    units = WorkCore.Weave.unit_count(dir)
    {:ok, ^out, bytes} = WorkCore.Weave.to_file(dir, out)
    Log.ok("#{Path.basename(out)}", detail: "#{units} unit(s) · #{kb(bytes)} · static")
    Log.step(Log.dim("dynamic hydration (compile + live data) needs a nexus — `work deploy` (P3)"))
    :ok
  end

  defp kb(b) when b >= 1024, do: "#{Float.round(b / 1024, 1)}KB"
  defp kb(b), do: "#{b}B"

  @doc "work structure [dir] — list the units in the tree."
  def structure(dir) do
    units =
      dir
      |> work_files()
      |> Enum.flat_map(fn p -> p |> File.read!() |> Literate.parse() |> Enum.filter(&(&1.type == :code)) |> Enum.map(&{p, &1}) end)

    Log.prompt("work structure #{dir}")
    Log.ok("#{length(units)} unit(s)")

    for {path, u} <- units do
      tag = [u.kind, u.lang] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      Log.step(Log.cmd(":#{u.name}") <> "  " <> Log.dim(tag) <> "  " <> Log.path(Path.basename(path)))
    end

    :ok
  end

  defp find_unit(dir, name) do
    dir
    |> work_files()
    |> Enum.flat_map(fn path -> Literate.parse(File.read!(path)) end)
    |> Enum.find(fn n -> n.type == :code and n.name == name end)
  end

  defp work_files(dir) do
    (Path.wildcard(Path.join(dir, "*.work")) ++ Path.wildcard(Path.join(dir, "**/*.work"))) |> Enum.uniq()
  end
end
