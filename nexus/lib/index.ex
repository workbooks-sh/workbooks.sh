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
end
