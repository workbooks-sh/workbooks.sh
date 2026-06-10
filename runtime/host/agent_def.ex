defmodule Workbooks.AgentDef do
  @moduledoc """
  Parse an Org `:agent:` node into a runnable agent (the brandnana-strategist
  shape). The node's properties carry `:ID:` / `:MODEL:` / `:TOOLKITS:`; the
  `** System prompt` subsection is the system prompt. `run/3` parses + runs the
  agent (Workbooks.Agent) on a task. So an agent is authored as Org, discovered
  like a toolkit, and run on the clean-room substrate — no bespoke format.
  """
  alias Workbooks.{OQL, Agent}

  @doc "Parse the first `:agent:` node in an Org source → %{id, model, toolkits, system}."
  def parse(org) when is_binary(org) do
    node = OQL.parse_headlines(org) |> Enum.find(&("agent" in &1["tags"]))

    %{
      id: node && node["id"],
      model: node && node["props"]["MODEL"],
      toolkits: ((node && node["props"]["TOOLKITS"]) || "") |> String.split(),
      tagline: node && node["props"]["TAGLINE"],
      system: system_prompt(org)
    }
  end

  @doc "Parse an Org agent def and run it on `task`. opts override (e.g. :model, :max_steps, :vfs)."
  def run(org, task, opts \\ []) do
    def = parse(org)

    # Toolkit auto-injection (TOOLKITS-V3 §P3): the agent's declared :TOOLKITS:
    # become a compact index appended to the system prompt — tier 1 of progressive
    # disclosure. Skill bodies stay on demand via the `wb` tool, never inlined.
    system =
      case Workbooks.Toolkits.injection_text(def.toolkits) do
        "" -> def.system
        index -> def.system <> "\n\n" <> index
      end

    Agent.run(system, task, Keyword.put_new(opts, :model, def.model))
  end

  # The system prompt is everything under the `** System prompt` heading, up to
  # the next sibling heading (or end). Falls back to the whole body.
  defp system_prompt(org) do
    case Regex.split(~r/^\*+\s+System prompt\s*$/m, org, parts: 2) do
      [_, rest] ->
        rest |> next_section() |> String.trim()

      _ ->
        # No `** System prompt` heading: fall back to the body of the :agent:
        # node (everything after its properties drawer) — an agent authored as
        # a plain def shouldn't silently run prompt-less. (This bit bit.ml: the
        # crew ran with EMPTY prompts and all imitated desk.)
        agent_body(org)
    end
  end

  # Everything after the first :agent: node's :END: drawer line, to the next
  # top-level heading — used when there's no explicit `** System prompt`.
  defp agent_body(org) do
    case Regex.split(~r/^\s*:END:\s*$/m, org, parts: 2) do
      [_, rest] -> rest |> String.trim()
      _ -> ""
    end
  end

  # End the system prompt at the next sibling/parent heading (level 1-2), so
  # deeper `***` subsections (Command surface, Recipes, …) stay part of it.
  defp next_section(text) do
    case Regex.split(~r/^\*{1,2}\s+\S/m, text, parts: 2) do
      [section | _] -> section
      _ -> text
    end
  end
end
