defmodule Workbooks.WorkKits.Graph do
  @moduledoc """
  The DEPENDENCY-GRAPH half of `Workbooks.WorkKits` — the transitive closure over
  toolkit→toolkit `<work-ref rel="needs">` edges, both in-document (`resolve/2`,
  `closure/3`) and disk-backed (`closure_disk/2`).

  Discovery/closure ONLY — caps stay grant-gated (a dep edge never widens powers).
  """
  alias Workbooks.WorkKits.{Manifest, Registry}

  @doc """
  Resolve a `<work-agent>`'s `kits` list → the toolkit views it may use, expanded
  over toolkit→toolkit `<work-ref rel="needs">` edges (transitive closure first,
  then flatten; dedup, declared-first order). Unknown names are dropped.
  """
  def resolve(html, agent_id) when is_binary(html) do
    wanted = agent_toolkits(html, agent_id)
    tks = Manifest.work_toolkit_nodes(html)
    by_id = Map.new(tks, &{&1.attrs["id"], Manifest.view(&1)})
    edges = Map.new(tks, &{&1.attrs["id"], Manifest.parse_requires(&1.attrs["requires"])})

    closure(wanted, edges, Map.keys(by_id))
    |> Enum.map(&by_id[&1])
    |> Enum.reject(&is_nil/1)
  end

  # The `kits` list declared on a `<work-agent id=…>` element, or [].
  defp agent_toolkits(html, agent_id) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        case Floki.find(tree, "work-agent[id=\"#{agent_id}\"]") do
          [node | _] -> Floki.attribute([node], "kits") |> List.first() |> to_string() |> String.split()
          [] -> []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Transitive closure of `roots` over toolkit-id dependency edges.

  `edges` maps a toolkit id → its parsed requires tokens (`Manifest.parse_requires`
  shape). `known` is the set of installed toolkit ids — a `{:dep, name, _}` token
  is followed ONLY when `name ∈ known`. Returns ids declared-first, dependency-after,
  deduped. A back-edge raises `ArgumentError` — the graph must be a DAG.
  """
  def closure(roots, edges, known) do
    known = MapSet.new(known)

    {acc, _seen} =
      Enum.reduce(roots, {[], MapSet.new()}, fn id, {acc, seen} ->
        visit(id, edges, known, acc, seen, MapSet.new())
      end)

    Enum.reverse(acc)
  end

  # DFS post-order with an active-path set for cycle detection.
  defp visit(id, edges, known, acc, seen, path) do
    cond do
      MapSet.member?(path, id) ->
        raise ArgumentError, "toolkit dependency cycle through #{id} (the REQUIRES graph must be a DAG)"

      MapSet.member?(seen, id) ->
        {acc, seen}

      true ->
        dep_ids =
          for {:dep, name, _raw} <- Map.get(edges, id, []), MapSet.member?(known, name), do: name

        {acc, seen} =
          Enum.reduce(dep_ids, {acc, seen}, fn dep, {acc, seen} ->
            visit(dep, edges, known, acc, seen, MapSet.put(path, id))
          end)

        {[id | acc], MapSet.put(seen, id)}
    end
  end

  @doc """
  Expand a flat list of declared toolkit ids into the transitive closure over
  ON-DISK dependency edges — the disk-backed counterpart of `closure/3`. Reads each
  toolkit's manifest for its edges; unknown/uninstalled ids pass through unfollowed.
  """
  def closure_disk(ids, root) do
    descs = Registry.discover_dir(root)
    known = Enum.map(descs, & &1.id)

    edges =
      Map.new(descs, fn t ->
        {t.id, Manifest.parse_descriptor(File.read!(Path.join(t.dir, Registry.manifest_file()))).requires}
      end)

    closure(ids, edges, known)
  end
end
