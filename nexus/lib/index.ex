defmodule Nexus.Index do
  @moduledoc """
  The `index.work` semantics — an index is the CONFIG + COMPOSITION + CEILING marker for its subtree,
  **not** a place for logic. It *indexes* its siblings/children (the merge-point): config
  (`deploy`/`ceiling`), declarations (`data`/`resource`/`enum`/`record`/`type`), composition + routing
  (`app`/`section`/`page`/`route`/`theme`), and bindings (`hook`) — plus prose. Executable logic
  (`server`/`client`/`def`/`flow`/`test`/`agent`/`check`) belongs in SIBLING `.work` files the index
  references, never inside it.

  A *pure* index is what lets it credibly serve as the capability **ceiling** for its subtree
  (Autopoiesis v2 — ceiling-in-index): the trust boundary can't be a trust boundary if it's also a
  dumping ground for application code. `purity/1` is the static gate that keeps it honest.
  """

  # Kinds that carry executable logic or a render island — they do not belong in an index.
  @logic_kinds ~w(server client def flow test agent check)

  @doc "The logic/island kinds an index may not contain."
  def logic_kinds, do: @logic_kinds

  @doc """
  Logic/island units found in an `index.work` file — `[]` means the index is pure. Each violation is
  `{kind, name}` (e.g. `{"server", "cloud"}`), the unit that should move to a sibling file.
  """
  def purity(path) when is_binary(path) do
    path
    |> File.read!()
    |> Nexus.Literate.parse()
    |> Enum.filter(&(&1.type == :code and &1.kind in @logic_kinds))
    |> Enum.map(fn u -> {u.kind, Map.get(u, :name)} end)
  end

  @doc """
  Audit every `index.work` under `root` → `%{relpath => [violations]}` for the impure indexes only.
  An empty map means every index in the tree is a clean config/composition/ceiling marker.
  """
  def purity_tree(root) do
    Path.join(root, "**/index.work")
    |> Path.wildcard()
    |> Enum.map(fn f -> {Path.relative_to(f, root), purity(f)} end)
    |> Enum.reject(fn {_f, v} -> v == [] end)
    |> Map.new()
  end

  # ── The ceiling (Autopoiesis v2 — ceiling-in-index) ────────────────────────
  #
  # An index declares its subtree's capability CEILING:
  #
  #     ceiling do
  #       grant net, llm, vfs
  #     end
  #
  # The ceiling is the MAX set of capabilities any agent under this subtree may hold. Nested indexes
  # nest ceilings; the EFFECTIVE ceiling at any path is the INTERSECTION of every ancestor index's
  # ceiling from the root down — so a deeper index can only ever NARROW, never widen. Widening requires
  # editing an ancestor index, which sits above an agent's workspace write-scope = structurally
  # unreachable. That is what makes escalation impossible by construction.

  @doc """
  The capability ceiling declared by a single `index.work` — a sorted list of grantable caps, or
  `:unbounded` when the index has no `ceiling` block (it imposes no constraint of its own).
  """
  def ceiling(path) when is_binary(path), do: path |> File.read!() |> ceiling_source()

  @doc "Like `ceiling/1` but reads the `ceiling` block straight from a `.work` SOURCE string (used by
  the merge gate, which diffs proposed source before it is ever written to disk)."
  def ceiling_source(src) when is_binary(src) do
    src
    |> Nexus.Literate.parse()
    |> Enum.find(&(&1.type == :code and &1.kind == "ceiling"))
    |> ceiling_caps()
  end

  defp ceiling_caps(nil), do: :unbounded

  defp ceiling_caps(%{ast: {:ceiling, _, args}}) do
    with block when not is_nil(block) <- Enum.find_value(args, fn [{:do, b}] -> b; _ -> nil end),
         {:grant, _, gargs} <- find_grant(block) do
      cap_names(gargs) |> Enum.filter(&Nexus.Capabilities.grantable?/1) |> Enum.uniq() |> Enum.sort()
    else
      # a `ceiling` block with no `grant` line grants nothing — the tightest possible ceiling.
      _ -> []
    end
  end

  defp ceiling_caps(_), do: :unbounded

  defp find_grant({:__block__, _, stmts}), do: Enum.find(stmts, &match?({:grant, _, _}, &1))
  defp find_grant({:grant, _, _} = g), do: g
  defp find_grant(_), do: nil

  # Bare identifiers / atoms → cap name strings (same normalization agent.ex uses for `grant`).
  defp cap_names(args) do
    args
    |> Enum.flat_map(fn list when is_list(list) -> list; other -> [other] end)
    |> Enum.map(fn
      a when is_atom(a) -> Atom.to_string(a)
      {id, _, ctx} when is_atom(id) and is_atom(ctx) -> Atom.to_string(id)
      other -> Macro.to_string(other)
    end)
  end

  @doc """
  The EFFECTIVE capability ceiling governing `path` — the intersection of every ancestor `index.work`
  ceiling from `root` down to the directory containing `path`. `:unbounded` if no ancestor declares a
  ceiling; otherwise the caps allowed by ALL declaring ancestors (deeper indexes can only narrow).
  """
  def effective_ceiling(root, path) do
    ancestor_indexes(root, path)
    |> Enum.map(&ceiling/1)
    |> Enum.reject(&(&1 == :unbounded))
    |> case do
      [] -> :unbounded
      [first | rest] -> Enum.reduce(rest, first, fn caps, acc -> Enum.filter(acc, &(&1 in caps)) end)
    end
  end

  @doc """
  Clamp a `declared` grant list to the effective ceiling governing `path` — `declared ∩ ceiling`. This
  is the one comparison every agent run uses (Autopoiesis v2): editing a declared grant up can only
  ever be a no-op, because the result is intersected back down to what the ceiling allows.
  """
  def clamp_grant(declared, root, path) when is_list(declared) do
    case effective_ceiling(root, path) do
      :unbounded -> declared
      ceiling -> Enum.filter(declared, &(&1 in ceiling))
    end
  end

  # Every `index.work` from `root` down to the directory of `path`, root-first (the ancestor chain).
  defp ancestor_indexes(root, path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    rel = Path.relative_to(dir, root)
    segs = if rel in [".", ""], do: [], else: Path.split(rel)

    segs
    |> Enum.scan(root, fn seg, acc -> Path.join(acc, seg) end)
    |> then(&[root | &1])
    |> Enum.map(&Path.join(&1, "index.work"))
    |> Enum.filter(&File.exists?/1)
  end
end
