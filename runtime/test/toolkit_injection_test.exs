defmodule Workbooks.ToolkitInjectionTest do
  @moduledoc """
  The toolkit prompt-injection (wb-d2nx.8) — the text appended to an agent's
  system prompt that tells it WHICH toolkits it has and how to open a skill.
  This is what makes Waldo capable, so it's worth pinning. Runs under the started
  app (OQL kernel parses the manifests); asserts against the real, stable
  `workbooks-browser` toolkit rather than a fixture.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Toolkits

  test "no toolkits → empty string (nothing injected)" do
    assert Toolkits.injection_text([]) == ""
  end

  test "a real toolkit injects a ## Toolkits block with its id + skill index" do
    out = Toolkits.injection_text(["workbooks-browser"])
    assert out =~ "## Toolkits"
    # Teaches the progressive-disclosure call so the agent reads a skill on demand.
    assert out =~ "toolkit show"
    assert out =~ "workbooks-browser"
    # The skill index must be listed (overview is always present).
    assert out =~ "skills:"
    assert out =~ "overview"
  end

  test "an unknown toolkit is reported as not installed, not silently dropped" do
    out = Toolkits.injection_text(["ghost-does-not-exist"])
    assert out =~ "ghost-does-not-exist"
    assert out =~ "(not installed)"
  end

  test "mixed known + unknown — each is accounted for on its own line" do
    out = Toolkits.injection_text(["workbooks-browser", "ghost-zzz"])
    assert out =~ "workbooks-browser"
    assert out =~ "ghost-zzz: (not installed)"
  end
end
