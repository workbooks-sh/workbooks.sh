defmodule WorkCore.Graph do
  @moduledoc """
  §9 — the code graph, assembled over the literate parse (§0). Nodes per unit;
  typed edges merged from the literate refs (§0.1) and the Elixir AST calls (§0.2).
  Backs `work check` / `work why` / `work near`. Foreign-language AST and the WIT
  feed (§2) extend the edge set later without changing this shape.
  """

  alias WorkCore.{Literate, Extract, Uid, Capabilities, Wit}

  defstruct nodes: %{}, edges: [], titles: %{}, backlinks: %{}, types: %{}

  @type t :: %__MODULE__{nodes: map, edges: [map], titles: map, backlinks: map, types: map}

  @doc "Build the graph from every .work file under a directory."
  def build_dir(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> build_files()
  end

  def build_files(paths) do
    parsed = Enum.map(paths, fn p -> {p, p |> File.read!() |> Literate.parse() |> Extract.annotate()} end)
    nodes = collect_nodes(parsed)
    %__MODULE__{
      nodes: nodes,
      edges: collect_edges(parsed, nodes),
      titles: collect_titles(parsed),
      backlinks: collect_backlinks(parsed),
      types: collect_types(parsed)
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
      {n.name, node(n, path)}
    end
  end

  # One node, projected across the layers it lives in. Top-level id/kind/lang/file/
  # exports stay for back-compat; `uid` is the canonical identity (§1) every layer
  # shares; `facets` is the per-layer view: source facts, the WIT interface (§2),
  # the compiled artifact (filled by the artifact pass), and the data-layer module.
  defp node(n, path) do
    facts = Extract.facts(n)

    %{
      id: n.name,
      uid: %{key: Uid.key(n.name), wit: Uid.wit(n.name), package: Uid.package(n.name), module: Uid.module(n.name)},
      kind: n.kind,
      lang: n.lang,
      file: path,
      exports: facts.exports,
      facets: %{
        source: %{kind: n.kind, lang: n.lang, file: path, exports: facts.exports, imports: facts.imports, types: facts.types, calls: facts.calls},
        interface: Wit.world(n),
        artifact: nil,
        data: %{module: Uid.module(n.name)},
        observed: nil
      }
    }
  end

  # ── types: the unified workbook-wide type registry (§1) — records (defmodule
  #    type units) + enums (top-level decls), keyed by WIT name. Resolves a
  #    cross-file record param to a real WIT ref instead of the `string` degrade.
  defp collect_types(parsed) do
    records =
      for {path, ns} <- parsed,
          n <- ns,
          n.type == :code,
          n.kind == "defmodule",
          {:record, fields} <- Extract.facts(n).types,
          into: %{},
          do: {Uid.wit(n.name), %{kind: :record, name: n.name, spec: fields, file: path}}

    enums =
      for {path, ns} <- parsed,
          n <- ns,
          n.type == :decl,
          {:enum, name, atoms} <- WorkCore.Extract.Elixir.decl_types(n),
          into: %{},
          do: {Uid.wit(name), %{kind: :enum, name: name, spec: atoms, file: path}}

    Map.merge(enums, records)
  end

  @doc """
  The workbook-wide shared WIT types — `{interface, type_names}` — built from the
  unified type registry. Feed it to `WorkCore.Wit.world/2` to emit a per-unit world
  whose cross-file record params resolve to their real type ref.
  """
  def shared_types(%__MODULE__{types: types}) do
    record_specs = for {_w, %{kind: :record, name: n, spec: f}} <- types, do: {n, f}
    enums_kv = for {_w, %{kind: :enum, name: n, spec: a}} <- types, do: {n, a}
    Wit.interface_from_specs(record_specs, enums_kv)
  end

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
      |> Enum.map(&%{from: n.name, to: &1, type: :import, layer: :source, scope: :unit, signature: nil})

    refs =
      n.refs
      |> Enum.filter(&String.starts_with?(&1, ":"))
      |> Enum.map(&String.trim_leading(&1, ":"))
      |> Enum.filter(&(&1 != n.name and Map.has_key?(nodes, &1)))
      |> Enum.map(&%{from: n.name, to: &1, type: :ref, layer: :source, scope: :unit, signature: nil})

    # host-capability edges: a unit's `grant`s resolve against the capability catalog,
    # not other units — tagged :host_cap so `check` validates them there, not as
    # dangling unit edges (Seam 4: host imports vs unit imports were indistinguishable).
    caps =
      n
      |> Capabilities.grants()
      |> Enum.map(&%{from: n.name, to: &1, type: :import, layer: :interface, scope: :host_cap, signature: Capabilities.grant_import(&1)})

    Enum.uniq(imports ++ refs ++ caps)
  end

  # ── work check: do every backlink + import resolve? ──
  @doc "Resolve every [[backlink]] across the tree + every edge; report what dangles."
  def check(%__MODULE__{nodes: nodes, edges: edges, titles: titles} = g) do
    title_set = titles |> Map.values() |> Enum.map(&Uid.normalize/1) |> MapSet.new()
    node_set = nodes |> Map.keys() |> Enum.map(&Uid.normalize/1) |> MapSet.new()

    dangling_backlinks =
      for {path, links} <- g.backlinks, l <- links, not resolves?(l, node_set, title_set), do: {path, l}

    # unit edges must resolve to a node; host-cap edges resolve to the catalog instead.
    dangling_edges =
      for e <- edges,
          (Map.get(e, :scope, :unit) == :host_cap and not Capabilities.grantable?(e.to)) or
            (Map.get(e, :scope, :unit) == :unit and not Map.has_key?(nodes, e.to)),
          do: e

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

  @doc """
  Join a reality overlay (§10) onto the graph: each node's `facets.data` is merged
  with the overlay's data facet for that unit, and `facets.observed` is filled from
  the overlay's observed facet. The build stays pure — this is the query-time lens
  that brings live DB schema + agent telemetry under the same identity (§1).
  """
  def with_overlay(%__MODULE__{nodes: nodes} = g, %WorkCore.Overlay{} = ov) do
    merged =
      Map.new(nodes, fn {name, node} ->
        data = case WorkCore.Overlay.data(ov, name) do
          nil -> node.facets.data
          d -> Map.merge(node.facets.data, d)
        end

        facets = %{node.facets | data: data, observed: WorkCore.Overlay.observed(ov, name)}
        {name, %{node | facets: facets}}
      end)

    %{g | nodes: merged}
  end

  # ── the agent-/system-facing query surface over the unified graph ──

  @doc "The full multi-layer node for a unit (identity + facets), or nil."
  def get(%__MODULE__{nodes: nodes}, name), do: Map.get(nodes, name)

  @doc "List units, optionally filtered by `:lang` and/or `:kind`."
  def units(%__MODULE__{nodes: nodes}, filters \\ []) do
    nodes
    |> Map.values()
    |> Enum.filter(fn n ->
      Enum.all?(filters, fn
        {:lang, l} -> n.lang == l
        {:kind, k} -> n.kind == k
        _ -> true
      end)
    end)
  end

  @doc """
  Edges touching a unit, filtered. Opts: `:dir` (`:out`/`:in`/`:both`, default
  `:out`), `:layer`, `:scope`, `:type`.
  """
  def neighbors(%__MODULE__{edges: edges}, name, opts \\ []) do
    dir = Keyword.get(opts, :dir, :out)

    edges
    |> Enum.filter(fn e ->
      touches =
        case dir do
          :out -> e.from == name
          :in -> e.to == name
          :both -> e.from == name or e.to == name
        end

      touches and match_opt(e, :layer, opts) and match_opt(e, :scope, opts) and match_opt(e, :type, opts)
    end)
  end

  defp match_opt(e, key, opts) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, v} -> Map.get(e, key) == v
    end
  end

  @doc "Unit-scope dependencies of a unit (the units it imports/references)."
  def dependencies(g, name), do: neighbors(g, name, dir: :out, scope: :unit) |> Enum.map(& &1.to) |> Enum.uniq()

  @doc "Units that depend on this one (reverse deps) — alias of why/2."
  def dependents(g, name), do: why(g, name)

  @doc "The host capabilities a unit grants (the :host_cap edge targets)."
  def host_caps(g, name), do: neighbors(g, name, scope: :host_cap) |> Enum.map(& &1.to) |> Enum.uniq()

  @doc """
  The cross-layer view of a unit an agent wants in one call: its identity, every
  facet (source/interface/artifact/data), its unit dependencies + host caps, and
  who depends on it — the literate→source→WIT→wasm picture for one unit.
  """
  def trace(%__MODULE__{} = g, name) do
    case get(g, name) do
      nil ->
        nil

      node ->
        %{
          unit: name,
          identity: node.uid,
          facets: node.facets,
          dependencies: dependencies(g, name),
          host_caps: host_caps(g, name),
          dependents: dependents(g, name)
        }
    end
  end

  @doc "A dependency path from one unit to another over unit edges, or nil (BFS)."
  def path(%__MODULE__{} = g, from, to), do: bfs(g, [[from]], MapSet.new([from]), to)

  defp bfs(_g, [], _seen, _to), do: nil

  defp bfs(g, [[head | _] = trail | rest], seen, to) do
    if head == to do
      Enum.reverse(trail)
    else
      nexts = dependencies(g, head) |> Enum.reject(&MapSet.member?(seen, &1))
      seen = Enum.reduce(nexts, seen, &MapSet.put(&2, &1))
      bfs(g, rest ++ Enum.map(nexts, &[&1 | trail]), seen, to)
    end
  end

  # normalize/1 moved to WorkCore.Uid — the canonical identity home.
end
