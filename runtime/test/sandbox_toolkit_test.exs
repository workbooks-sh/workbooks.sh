defmodule Workbooks.SandboxToolkitTest do
  use ExUnit.Case, async: false

  # The sandbox toolkit is the agent-discovery surface for the in-sandbox command set. This guards it:
  # the manifest must parse to exactly one `<work-toolkit>` node (a malformed one would break
  # discover_dir for ALL agents), the skills must exist, and the agents we activated it on must still
  # list it.

  @toolkits Path.expand("../../workkits", __DIR__)

  test "the sandbox manifest discovers as exactly one valid <work-toolkit> node" do
    manifest = Path.join(@toolkits, "sandbox/manifest.html")
    assert File.regular?(manifest)

    nodes = Workbooks.WorkKits.discover(File.read!(manifest))
    assert [node] = nodes
    assert node.id == "sandbox"
    assert node.skill_dir == "skills/"
  end

  test "the sandbox toolkit ships its skills" do
    for s <- ~w(overview commands) do
      assert File.regular?(Path.join(@toolkits, "sandbox/skills/#{s}.md")),
             "sandbox skill '#{s}' should exist"
    end
  end

  test "the activated agents list the sandbox toolkit" do
    # analyst.html lives at runtime/examples/agents/ (__DIR__ is runtime/test)
    analyst = Path.expand("../examples/agents/analyst.html", __DIR__)
    assert File.read!(analyst) =~ ~r/toolkits="[^"]*\bsandbox\b/
  end
end
