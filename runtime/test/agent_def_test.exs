defmodule Workbooks.AgentDefTest do
  @moduledoc """
  Regression tests for the agent-def parser (the seam that gives an agent its
  system prompt + toolkits). Pins the known footgun: an agent must NEVER run
  prompt-less. (The bit.ml incident — agents authored without a `** System
  prompt` heading ran with EMPTY prompts and all imitated each other.) Runs
  under the started app (OQL kernel parses headlines).
  """
  use ExUnit.Case, async: false

  alias Workbooks.AgentDef

  defp def_with_heading do
    """
    * Waldo                                                          :agent:
      :PROPERTIES:
      :ID:        waldo
      :MODEL:     anthropic/claude-haiku-4.5
      :TOOLKITS:  workbooks-browser workbooks-cli
      :TAGLINE:   Resident agent
      :END:

    ** System prompt

       You are Waldo, the resident agent.

    *** Command surface

       Use `work app …` to drive the shell.

    ** Notes

       This must NOT be part of the prompt.
    """
  end

  test "parses id, model, space-split toolkits, tagline" do
    d = AgentDef.parse(def_with_heading())
    assert d.id == "waldo"
    assert d.model == "anthropic/claude-haiku-4.5"
    assert d.toolkits == ["workbooks-browser", "workbooks-cli"]
    assert d.tagline == "Resident agent"
  end

  test "system prompt spans the heading + deeper *** subsections, stops at next sibling **" do
    d = AgentDef.parse(def_with_heading())
    assert d.system =~ "You are Waldo, the resident agent."
    # a deeper *** subsection stays IN the prompt
    assert d.system =~ "Use `work app"
    # a sibling ** heading ends the prompt — its body must be excluded
    refute d.system =~ "This must NOT be part of the prompt."
  end

  test "FOOTGUN: no `** System prompt` heading falls back to the node body, never empty" do
    org = """
    * Scout                                                          :agent:
      :PROPERTIES:
      :ID:        scout
      :END:

      You scout the codebase and report findings concisely.
    """

    d = AgentDef.parse(org)
    assert d.id == "scout"
    # MUST carry the body — a prompt-less agent is the bug we're guarding against
    refute d.system == ""
    assert d.system =~ "You scout the codebase"
  end

  test "no toolkits prop → empty list (not a crash, not a [\"\"])" do
    org = """
    * Bare                                                           :agent:
      :PROPERTIES:
      :ID:        bare
      :END:

      Minimal agent.
    """

    d = AgentDef.parse(org)
    assert d.toolkits == []
  end

  test "no :agent: node → nil id, empty-ish def (graceful, no raise)" do
    d = AgentDef.parse("* Just a heading\n\nSome prose, no agent tag.\n")
    assert d.id == nil
    assert d.toolkits == []
  end
end
