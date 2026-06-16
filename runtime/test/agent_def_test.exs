defmodule Workbooks.AgentDefTest do
  @moduledoc """
  Regression tests for the agent-def parser (the seam that gives an agent its
  system prompt + toolkits). Pins the known footgun: an agent must NEVER run
  prompt-less. (The bit.ml incident — agents authored without a `<work-system>`
  prompt ran with EMPTY prompts and all imitated each other.) An agent is an HTML
  file built from `work-*` components; the parser reads it with Floki.
  """
  use ExUnit.Case, async: false

  alias Workbooks.AgentDef

  defp def_with_system do
    """
    <work-agent id="waldo" model="anthropic/claude-haiku-4.5"
                toolkits="workbooks-browser workbooks-cli" tagline="Resident agent">
      <work-system>
        You are Waldo, the resident agent.

        Command surface: use `work app …` to drive the shell.
      </work-system>
      <work-note>This must NOT be part of the prompt.</work-note>
    </work-agent>
    """
  end

  test "parses id, model, space-split toolkits, tagline" do
    d = AgentDef.parse(def_with_system())
    assert d.id == "waldo"
    assert d.model == "anthropic/claude-haiku-4.5"
    assert d.toolkits == ["workbooks-browser", "workbooks-cli"]
    assert d.tagline == "Resident agent"
  end

  test "system prompt is the <work-system> body; sibling elements are excluded" do
    d = AgentDef.parse(def_with_system())
    assert d.system =~ "You are Waldo, the resident agent."
    # content inside <work-system> stays in the prompt
    assert d.system =~ "use `work app"
    # a sibling element's text must be excluded
    refute d.system =~ "This must NOT be part of the prompt."
  end

  test "FOOTGUN: no <work-system> falls back to the agent's own text, never empty" do
    html = ~s(<work-agent id="scout">You scout the codebase and report findings concisely.</work-agent>)

    d = AgentDef.parse(html)
    assert d.id == "scout"
    # MUST carry the body — a prompt-less agent is the bug we're guarding against
    refute d.system == ""
    assert d.system =~ "You scout the codebase"
  end

  test "no toolkits attr → empty list (not a crash, not a [\"\"])" do
    d = AgentDef.parse(~s(<work-agent id="bare">Minimal agent.</work-agent>))
    assert d.toolkits == []
  end

  test "no <work-agent> → nil id, empty-ish def (graceful, no raise)" do
    d = AgentDef.parse(~s(<work-doc title="Just a heading">Some prose, no agent.</work-doc>))
    assert d.id == nil
    assert d.toolkits == []
  end
end
