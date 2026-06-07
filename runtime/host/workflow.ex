defmodule Workbooks.Workflow do
  @moduledoc """
  A workflow is the unit of orchestration — there is no separate "board". A native
  Org `:workflow:` headline IS the DAG: its `:component:` children are the tasks,
  `:out`→`:in` header args are the edges, nested `:workflow:` headings are
  sub-workflows. Workflows and tasks make up the DAG; running a workflow executes
  it (topological, piping along edges) and recurses into sub-workflows, yielding a
  run record with the schedule surfaced. Org owns the orchestration spec; the
  runtime just executes it — no DSL, no board model.
  """
  alias Workbooks.{OQL, PackageManager}

  @doc "Run the workflows declared in an Org source → nested run records."
  def run(org, input \\ "") when is_binary(org) do
    OQL.tangle_plan(org)["worlds"] |> Enum.map(&run_world(&1, input))
  end

  @doc "The workflows in an Org source, with their schedules (no execution)."
  def list(org) when is_binary(org) do
    OQL.tangle_plan(org)["worlds"] |> Enum.map(&summary/1)
  end

  defp run_world(world, input) do
    %{
      workflow: world["name"],
      schedule: world["schedule"],
      exports: world["exports"],
      tasks: PackageManager.run_world(world, input, &step/2),
      sub_workflows: Enum.map(world["workflows"] || [], &run_world(&1, input))
    }
  end

  # A workflow step. An `agent`-lang component runs the agent loop (its source
  # block is the system prompt, the piped input is the task) — so a workflow can
  # fan out sub-agents, brandnana-style. Any other component is a WASM filter.
  defp step(%{"lang" => "agent", "src" => prompt}, input) do
    Workbooks.Agent.run(prompt, input, max_steps: 6).result
  end

  defp step(comp, input), do: PackageManager.run_component_step(comp, input)

  defp summary(world) do
    %{
      workflow: world["name"],
      schedule: world["schedule"],
      tasks: Enum.map(world["components"] || [], & &1["name"]),
      sub_workflows: Enum.map(world["workflows"] || [], &summary/1)
    }
  end
end
