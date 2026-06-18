defmodule WorkCore.Graph do
  @moduledoc """
  §9 — the code graph, assembled over the literate parse (§0). Nodes per unit;
  typed edges merged from the literate refs (§0.1) and the Elixir AST calls (§0.2).
  Backs `work check` / `work why` / `work near`. Foreign-language AST and the WIT
  feed (§2) extend the edge set later without changing this shape.
  """

  alias WorkCore.{Literate, Extract, Uid}

  defstruct nodes: %{}, edges: [], titles: %{}, backlinks: %{}

  @type t :: %__MODULE__{nodes: map, edges: [map], titles: map, backlinks: map}

  @doc "Build the graph from every .work file under a directory."
  def build_dir(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> build_files()
  end

  def build_files(paths) do
    parsed = Enum.map(paths, fn p -> {p, Literate.parse(File.read!(p))} end)
    nodes = collect_nodes(parsed)
    %__MODULE__{
      nodes: nodes,
      edges: collect_edges(parsed, nodes),
      titles: collect_titles(parsed),
      backlinks: collect_backlinks(parsed)
    }
  end

  defp collect_backlinks(parsed) do
    for {path, nodes} <- parsed, into: %{} do
      links =
        nodes
        # backlinks are a prose construct; a [[…]] inside a code body is a comment
        # example, not a real reference, so don't gate on it.
        |> Enum.reject(&(&1.type == :code))
        |> Enum.flat_map(&Map.get(&1, :refs, []))
        |> Enum.filter(&String.starts_with?(&1, "[["))
        |> Enum.uniq()

      {path, links}
    end
  end

  # ── nodes: one per named :code unit ──
  defp collect_nodes(parsed) do
    for {path, nodes} <- parsed, n <- nodes, n.type == :code, n.name, into: %{} do
      {n.name, %{id: n.name, kind: n.kind, lang: n.lang, file: path, exports: exports(n)}}
    end
  end

  defp exports(n), do: Extract.facts(n).exports

  defp collect_titles(parsed) do
    for {path, nodes} <- parsed, into: %{} do
      title = Enum.find_value(nodes, fn n -> if n.type == :heading and n.level == 1, do: n.text end)
      {path, title || Path.basename(path, ".work")}
    end
  end

  # ── edges: imports (AST calls to a unit) + refs (literate :atom mentions) ──
  defp collect_edges(parsed, nodes) do
    for {_path, ns} <- parsed, n <- ns, n.type == :code, n.name, e <- node_edges(n, nodes), do: e
  end

  defp node_edges(n, nodes) do
    facts = Extract.facts(n)

    # Elixir: remote calls (Module → unit). Foreign: declared imports
    # (work://unit, a linked wasm_import_module, an extern fn). Both → unit names.
    targets =
      (Enum.map(facts.calls, fn {mod, _f, _a} -> mod |> Module.split() |> List.last() |> String.downcase() end) ++
         Enum.map(facts.imports, &String.downcase/1))
      |> Enum.uniq()

    imports =
      targets
      |> Enum.filter(&(&1 != n.name and Map.has_key?(nodes, &1)))
      |> Enum.map(&%{from: n.name, to: &1, type: :import})

    refs =
      n.refs
      |> Enum.filter(&String.starts_with?(&1, ":"))
      |> Enum.map(&String.trim_leading(&1, ":"))
      |> Enum.filter(&(&1 != n.name and Map.has_key?(nodes, &1)))
      |> Enum.map(&%{from: n.name, to: &1, type: :ref})

    Enum.uniq(imports ++ refs)
  end

  # ── work check: do every backlink + import resolve? ──
  @doc "Resolve every [[backlink]] across the tree + every edge; report what dangles."
  def check(%__MODULE__{nodes: nodes, edges: edges, titles: titles} = g) do
    title_set = titles |> Map.values() |> Enum.map(&Uid.normalize/1) |> MapSet.new()
    node_set = nodes |> Map.keys() |> Enum.map(&Uid.normalize/1) |> MapSet.new()

    dangling_backlinks =
      for {path, links} <- g.backlinks, l <- links, not resolves?(l, node_set, title_set), do: {path, l}

    dangling_edges = for e <- edges, not Map.has_key?(nodes, e.to), do: e

    %{
      nodes: map_size(nodes),
      edges: length(edges),
      dangling_backlinks: dangling_backlinks,
      dangling_edges: dangling_edges,
      ok: dangling_backlinks == [] and dangling_edges == []
    }
  end

  defp resolves?(label, node_set, title_set) do
    n = Uid.normalize(label)
    MapSet.member?(node_set, n) or MapSet.member?(title_set, n)
  end

  # ── work why / work near ──
  @doc "Who depends on this unit (reverse deps)."
  def why(%__MODULE__{edges: edges}, name), do: for(e <- edges, e.to == name, do: e.from) |> Enum.uniq()

  @doc "The unit's immediate neighbourhood — edges in and out."
  def near(%__MODULE__{edges: edges}, name), do: for(e <- edges, e.from == name or e.to == name, do: e)

  # normalize/1 moved to WorkCore.Uid — the canonical identity home.
end
