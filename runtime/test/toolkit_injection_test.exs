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

  test "no manifest drift: every skill file is documented in its toolkit manifest" do
    # Guards the drift just fixed (the `models` skill existed but was missing from
    # the workbooks-browser manifest's Live-now table). Every skills/*.org must be
    # mentioned in manifest.org so the doc can't silently fall behind the files.
    root = Toolkits.default_root()

    # Discover EVERY installed toolkit (not a hardcoded pair) so a new toolkit or
    # skill can't dodge the guard.
    toolkits =
      root
      |> File.ls!()
      |> Enum.filter(&File.exists?(Path.join([root, &1, "manifest.org"])))

    assert toolkits != [], "no toolkits discovered under #{root}"

    for tk <- toolkits do
      manifest = File.read!(Path.join([root, tk, "manifest.org"]))

      for skill <- Toolkits.skills(Path.join(root, tk)) do
        assert manifest =~ skill, "#{tk}: skill '#{skill}' missing from manifest.org"
      end
    end
  end

  test "eval_text case-filter: a non-matching filter selects no case (no LLM run)" do
    # The filter narrows to one eval by filename substring — cheap iteration vs
    # the full suite. A bogus filter must short-circuit to a clear message rather
    # than running (and billing) anything.
    out = Toolkits.eval_text("workbooks-cli", Toolkits.default_root(), "no-such-eval-zzz")
    assert out == ~s(workbooks-cli: no eval matches "no-such-eval-zzz")
  end
end
