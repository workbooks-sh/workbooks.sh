defmodule Nexus.Autopoet.Plan do
  @moduledoc """
  Task delineation + handoff documents (Autopoiesis v2 — wb-a6u3.14) — the autopoet as the single
  planner. The autopoet is the ONE entity you talk to; it decomposes a goal ("we need X and Y") into
  delegated, task-scoped subtasks, each carrying a **handoff document** — a self-contained brief so the
  delegated agent runs with full context and never has to await clarification. This is multi-agent
  *delineation of work*, NOT a persistent multi-agent swarm: delegation is ephemeral (the spawn half is
  the depth-capped, grant-narrowed `agent <name> <task>` command from wb-a6u3.2).

  A plan files as the workbooks-native to-dos DAG (a parent goal + subtasks — `resource Todo`), via
  neutral `plan.created` / `task.created` bus events; the cloud product persists them. `dispatch/2` runs
  each handoff through a runner (default: the assignee agent on the rendered brief) — pluggable so the
  planner is testable without the LLM.
  """

  alias Nexus.Autopoet.Plan.Handoff

  defmodule Handoff do
    @moduledoc "A self-contained task handoff: everything the delegated agent needs, no back-and-forth."
    @enforce_keys [:title, :task]
    defstruct [:title, :task, :context, :inputs, :acceptance, :assignee]
  end

  @doc "Build a validated handoff document. Requires `title` + `task`; the rest are optional context."
  def handoff(attrs) when is_map(attrs) do
    with {:ok, title} <- fetch(attrs, :title),
         {:ok, task} <- fetch(attrs, :task) do
      {:ok,
       %Handoff{
         title: title,
         task: task,
         context: get(attrs, :context),
         inputs: attrs |> get(:inputs) |> List.wrap() |> Enum.map(&to_string/1),
         acceptance: get(attrs, :acceptance),
         assignee: get(attrs, :assignee)
       }}
    end
  end

  @doc """
  Render a handoff to a self-contained brief — the exact text the delegated agent receives as its task.
  Carries context, inputs, and the done-when so the agent needs nothing else.
  """
  def render(%Handoff{} = h) do
    [
      "# #{h.title}",
      section("Context", h.context),
      "## Task\n#{h.task}",
      list_section("Inputs", h.inputs),
      section("Done when", h.acceptance)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n\n")
  end

  @doc "Delineate a `goal` into an ordered list of handoff steps → a plan."
  def delineate(goal, handoffs) when is_binary(goal) and is_list(handoffs) do
    %{goal: goal, steps: handoffs}
  end

  @doc """
  Run each handoff through `runner` (default: the assignee agent on the rendered brief). Returns a list
  of `%{title, result}`. Ephemeral, task-scoped delegation — each subtask is independent.
  """
  def dispatch(%{steps: steps}, runner \\ &default_runner/1) do
    for %Handoff{} = h <- steps, do: %{title: h.title, result: runner.(h)}
  end

  @doc "File the plan into the to-dos DAG via neutral bus events (parent goal + per-step task)."
  def file(%{goal: goal, steps: steps}) do
    parent = Nexus.Events.emit(%{kind: "plan.created", actor: "autopoet", title: goal})

    for %Handoff{} = h <- steps do
      Nexus.Events.emit(%{
        kind: "task.created",
        actor: "autopoet",
        title: h.title,
        plan: parent[:id],
        assignee: h.assignee,
        brief: render(h)
      })
    end

    parent
  end

  # Default runner: hand the rendered brief to the assignee agent (a declared agent). `:no_assignee`
  # when a step names none — the planner still produced a valid handoff for a human/other dispatcher.
  defp default_runner(%Handoff{assignee: nil}), do: {:error, :no_assignee}

  defp default_runner(%Handoff{} = h) do
    case Nexus.Agent.run_named(h.assignee, render(h)) do
      {:ok, %{answer: a}} -> {:ok, a}
      other -> other
    end
  end

  defp section(_label, nil), do: nil
  defp section(label, text), do: "## #{label}\n#{text}"
  defp list_section(_label, []), do: nil
  defp list_section(label, items), do: "## #{label}\n" <> Enum.map_join(items, "\n", &("- " <> &1))

  defp fetch(attrs, key) do
    case get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp get(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      v when is_binary(v) -> String.trim(v)
      v -> v
    end
  end
end
