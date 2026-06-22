defmodule Mix.Tasks.Nexus.Purity do
  @moduledoc """
  Audit `index.work` purity across a tree — an index is the config/composition/**ceiling** marker for
  its subtree, never a place for logic. `mix nexus.purity <dir>` flags any index that smuggles in a
  logic/island unit (`server`/`client`/`def`/`flow`/`test`/`agent`/`check`); those belong in sibling
  `.work` files the index references. Exits non-zero if any index is impure (CI-friendly).

      mix nexus.purity ../dogfood
  """
  @shortdoc "Audit index.work purity (config/ceiling, not logic)"
  use Mix.Task

  @impl true
  def run(args) do
    root = List.first(args) || "."
    impure = Nexus.Index.purity_tree(root)

    if impure == %{} do
      Mix.shell().info("✓ every index.work under #{root} is pure (config/composition/ceiling)")
    else
      Mix.shell().error("✗ impure index.work files (logic/islands belong in sibling files):\n")

      for {f, violations} <- Enum.sort(impure) do
        detail = Enum.map_join(violations, ", ", fn {k, n} -> "#{k}:#{n}" end)
        Mix.shell().error("  #{f}  ->  #{detail}")
      end

      Mix.shell().error("\n#{map_size(impure)} impure index(es)")
      exit({:shutdown, 1})
    end
  end
end
