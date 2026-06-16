defmodule Workbooks.AgentDef do
  @moduledoc """
  Parse a `<work-agent>` element into a runnable agent. The element's attributes
  carry `id` / `model` / `toolkits` / `tagline`; a nested `<work-system>` element
  (or, failing that, the agent's own text) is the system prompt. An agent is
  authored as an HTML file using the `work-*` components, discovered like a
  toolkit, and run on the clean-room substrate — no bespoke format, no parser.
  """
  alias Workbooks.Agent

  @doc "Parse the first `<work-agent>` in a workbook's HTML → %{id, model, toolkits, tagline, system}."
  def parse(html) when is_binary(html) do
    agent = find_agent(html)

    %{
      id: agent && attr(agent, "id"),
      model: agent && attr(agent, "model"),
      toolkits: ((agent && attr(agent, "toolkits")) || "") |> String.split(),
      tagline: agent && attr(agent, "tagline"),
      system: agent && system_prompt(agent)
    }
  end

  @doc "Parse a `<work-agent>` and run it on `task`. opts override (e.g. :model, :max_steps, :vfs)."
  def run(html, task, opts \\ []) do
    def = parse(html)

    # Toolkit auto-injection (TOOLKITS-V3 §P3): the agent's declared toolkits
    # become a compact index appended to the system prompt — tier 1 of progressive
    # disclosure. Skill bodies stay on demand via the `wb` tool, never inlined.
    system =
      case Workbooks.Toolkits.injection_text(def.toolkits) do
        "" -> def.system
        index -> "#{def.system}\n\n#{index}"
      end

    Agent.run(system, task, Keyword.put_new(opts, :model, def.model))
  end

  # The first `<work-agent>` element as a Floki node, or nil.
  defp find_agent(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} -> tree |> Floki.find("work-agent") |> List.first()
      _ -> nil
    end
  end

  defp attr(node, name) do
    case Floki.attribute([node], name) do
      [v | _] -> v
      _ -> nil
    end
  end

  # The system prompt is the `<work-system>` child's text; failing that, the
  # agent's own direct text. An agent must NEVER run prompt-less (the bit.ml
  # footgun — agents authored without a prompt ran empty and imitated each other).
  defp system_prompt(agent) do
    case Floki.find([agent], "work-system") do
      [sys | _] -> sys |> Floki.text() |> String.trim()
      [] -> agent |> own_text() |> String.trim()
    end
  end

  # Direct text of the agent element, excluding nested child elements' text.
  defp own_text({_tag, _attrs, children}),
    do: children |> Enum.filter(&is_binary/1) |> Enum.join()

  defp own_text(_), do: ""
end
