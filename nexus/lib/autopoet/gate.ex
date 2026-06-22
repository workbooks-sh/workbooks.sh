defmodule Nexus.Autopoet.Gate do
  @moduledoc """
  The merge gate's AUTHORITY check (Autopoiesis v2 — wb-a6u3.4). The autopoet may edit `managed` agents
  and apps autonomously *within ceiling*, but it may NEVER autonomously land a change to the human-gated
  **structural triad** — `grant`, the subtree `ceiling` (declared in `index.work`), and an agent's
  `management` posture. `classify/3` takes a proposed `.work` source change (before it is written) and
  returns whether it may be FIFO-merged by the autopoet or must be routed for human sign-off.

      {:autonomous, []}                 # safe to merge: prompt/tools/logic of a `managed` agent, etc.
      {:human_gated, [reason, …]}       # route to a human (surfaced via #event → hook → notify)

  Reasons are explicit so the notification can say exactly why: `{:grant, name}`, `{:management, name}`,
  `{:frozen, name}`, `{:proposed, name}`, `:ceiling`. This is the one place that decides "can the
  autopoet do this alone?", and it always errs toward a human when the triad is touched.
  """

  alias Nexus.{Agent, Index}

  @doc "Classify a proposed change to `path` (old → new source) as `:autonomous` or `:human_gated`."
  def classify(path, old_src, new_src) when is_binary(old_src) and is_binary(new_src) do
    reasons = Enum.uniq(index_reasons(path, old_src, new_src) ++ agent_reasons(old_src, new_src))
    if reasons == [], do: {:autonomous, []}, else: {:human_gated, reasons}
  end

  # A change to an index.work's CEILING is always human-gated — widening (or narrowing) the subtree
  # boundary is a structural act. (Other index edits — composition/routing — are not gated here; purity
  # is enforced separately by Nexus.Index.purity in the eval harness.)
  defp index_reasons(path, old_src, new_src) do
    if Path.basename(path) == "index.work" and Index.ceiling_source(old_src) != Index.ceiling_source(new_src),
      do: [:ceiling],
      else: []
  end

  # For every agent that appears in the new source, compare it to its old self. Touching grant or
  # management → human-gated. A `frozen` target (either side) is never autonomously editable; a
  # `proposed` target always routes to a human.
  defp agent_reasons(old_src, new_src) do
    old = agents_by_name(old_src)

    for {name, nnode} <- agents_by_name(new_src), reduce: [] do
      acc ->
        onode = Map.get(old, name)
        new_mgmt = Agent.management(nnode)
        old_mgmt = if onode, do: Agent.management(onode), else: new_mgmt

        cond do
          new_mgmt == "frozen" or old_mgmt == "frozen" -> [{:frozen, name} | acc]
          new_mgmt == "proposed" -> [{:proposed, name} | acc]
          old_mgmt != new_mgmt -> [{:management, name} | acc]
          onode && grant_of(onode) != grant_of(nnode) -> [{:grant, name} | acc]
          true -> acc
        end
    end
  end

  defp agents_by_name(src) do
    src
    |> Nexus.Literate.parse()
    |> Enum.filter(&(&1.type == :code and &1.kind == "agent"))
    |> Map.new(fn u -> {to_string(u.name), u} end)
  end

  defp grant_of(node), do: Agent.def_from_unit(node)[:grant]
end
