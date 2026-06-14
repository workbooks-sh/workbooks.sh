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

  setup do
    # Pin to the default in-tree toolkit root (wb-q2qg): a leaked WB_TOOLKITS_ROOT
    # from an earlier serial test would otherwise point discovery at a fixture/
    # empty dir, so the real workbooks-browser toolkit wouldn't be found.
    prev = System.get_env("WB_TOOLKITS_ROOT")
    System.delete_env("WB_TOOLKITS_ROOT")
    on_exit(fn -> if prev, do: System.put_env("WB_TOOLKITS_ROOT", prev), else: System.delete_env("WB_TOOLKITS_ROOT") end)
    :ok
  end

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

  test "eval_text case-filter: a non-matching filter selects no case (no LLM run)" do
    # The filter narrows to one eval by filename substring — cheap iteration vs
    # the full suite. A bogus filter must short-circuit to a clear message rather
    # than running (and billing) anything.
    out = Toolkits.eval_text("workbooks-cli", Toolkits.default_root(), "no-such-eval-zzz")
    assert out == ~s(workbooks-cli: no eval matches "no-such-eval-zzz")
  end
end
