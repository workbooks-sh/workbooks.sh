defmodule Nexus.Facet do
  @moduledoc """
  The workbook FACET — the manifest-level classification every served surface declares in its
  `index.work` (wb-jr1py.9; canon: AGENTS.md "Workbook Facets"):

      facet kit     # imported — a library workbook others pull in (toolkits, corpora)
      facet app     # entry interface — a product surface users open
      facet agent   # has a server brain — an embodied agent workbook

  `container` is an execution property, not a facet. The syntax + read mirror the `management`
  posture line (`Nexus.Index.management_source/1`): one plain line near the top of the surface's
  `index.work`, regex-read off the source — declarative, never executed. It is DISTINCT from the
  `app :name do` / `agent :name do` UNIT kinds: the facet classifies the WORKBOOK, a block kind
  classifies one unit inside it.

  The facet is the identity precondition of the agents-manage-apps reshape: app↔agent ownership
  (wb-jr1py.10) and the agent ship path (wb-jr1py.11) bind to a `facet app` workbook.

  Enforcement is STAGED: `validate/1` runs inside `Nexus.Compile.check/1` as WARNINGS today
  (visible in `work check` + the push gate output, non-blocking), and flips to errors once the
  tenant migration window closes — tracked in beads under the wb-jr1py epic.
  """

  @facets ~w(kit app agent)

  @doc "The declared facet vocabulary."
  def facets, do: @facets

  @doc ~S(Read the facet off an index.work SOURCE: "kit" / "app" / "agent" / nil.)
  def facet_source(src) when is_binary(src) do
    case Regex.run(~r/^\s*facet\s+(kit|app|agent)\b/m, src, capture: :all_but_first) do
      [f] -> f
      _ -> nil
    end
  end

  def facet_source(_), do: nil

  @doc "The facet of the surface rooted at `dir` (reads `dir/index.work`). Nil when undeclared."
  def facet(dir) do
    case File.read(Path.join(dir, "index.work")) do
      {:ok, src} -> facet_source(src)
      _ -> nil
    end
  end

  # ── ownership (wb-jr1py.10): agent `manages "surface"` → the app↔agent binding ──────────────────

  @doc """
  All app↔agent ownership bindings declared in the tree (agents' `manages` fields):
  `%{surface_path => %{agent: name, src: path}}`. On a duplicate claim the audit flags it;
  the map keeps the last parse order — resolution is only trustworthy on a clean audit.
  """
  def owners(root) do
    Map.new(bindings(root), fn {surface, agent, src} -> {surface, %{agent: agent, src: src}} end)
  end

  @doc "The managing agent of `surface` (relative path), or nil. `%{agent: name, src: path}`."
  def owner(root, surface), do: Map.get(owners(root), String.trim(to_string(surface), "/"))

  defp bindings(root) do
    for p <- Enum.uniq(Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work"))),
        {:ok, src} <- [File.read(p)],
        unit <- Nexus.Literate.parse(src),
        unit.type == :code and unit.kind == "agent",
        d = Nexus.Agent.def_from_unit(unit),
        surface <- List.wrap(d[:manages] || []) do
      {surface, to_string(d[:name]), Path.relative_to(p, root)}
    end
  end

  @doc """
  Tree audit — the facet + ownership invariants (staged as warnings in `Nexus.Compile.check/1`):

    * every served SURFACE declares a facet (surface set = `Nexus.Server.discover_mounts` semantics:
      every folder with an `index.work` at any depth; the root's own `index.work` is the deploy
      MANIFEST — exempt — when nested surfaces exist, else it is itself the one surface);
    * every `manages` target exists as a surface in the tree;
    * a managed surface's facet is `app` (only app products are managed);
    * a surface has at most ONE managing agent.

  `:ok | {:error, [message]}`.
  """
  def validate(root) do
    surfs = surfaces(root)
    dirs = Map.new(surfs)
    binds = bindings(root)

    missing =
      for {name, dir} <- surfs, facet(dir) == nil do
        "#{name}/index.work declares no facet — add one line: `facet kit|app|agent` " <>
          "(kit = imported library, app = entry interface, agent = has a server brain)"
      end

    unknown =
      for {s, agent, src} <- binds, not Map.has_key?(dirs, s) do
        "agent :#{agent} (#{src}) manages \"#{s}\" — no such surface (no #{s}/index.work in this tree)"
      end

    not_app =
      for {s, agent, src} <- binds, dir = dirs[s], dir != nil, f = facet(dir), f not in [nil, "app"] do
        "agent :#{agent} (#{src}) manages \"#{s}\" — its facet is `#{f}`; only a `facet app` surface can be managed"
      end

    dupes =
      binds
      |> Enum.group_by(fn {s, _, _} -> s end)
      |> Enum.filter(fn {_, claims} -> length(claims) > 1 end)
      |> Enum.map(fn {s, claims} ->
        agents = Enum.map_join(claims, ", ", fn {_, a, _} -> ":" <> a end)
        "surface \"#{s}\" has #{length(claims)} managing agents (#{agents}) — an app has exactly one owner"
      end)

    problems = missing ++ unknown ++ not_app ++ dupes
    if problems == [], do: :ok, else: {:error, problems}
  end

  # Mirrors discover_mounts (server.ex): nested index.work folders are surfaces (root = manifest,
  # exempt); a lone root index.work IS the surface. Path.wildcard skips dotdirs by default.
  defp surfaces(root) do
    nested =
      Path.wildcard(Path.join(root, "**/index.work"))
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == root))
      |> Enum.map(&{Path.relative_to(&1, root), &1})
      |> Enum.sort()

    cond do
      nested != [] -> nested
      File.exists?(Path.join(root, "index.work")) -> [{".", root}]
      true -> []
    end
  end
end
