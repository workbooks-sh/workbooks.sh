defmodule Workbooks.ToolkitInjectionTest do
  @moduledoc """
  The toolkit prompt-injection (wb-d2nx.8) — the text appended to an agent's
  system prompt that tells it WHICH toolkits it has and how to open a skill.
  This is what makes Waldo capable, so it's worth pinning. Runs under the started
  app (OQL kernel parses the manifests); asserts against the real, stable
  `workbooks-browser` toolkit rather than a fixture.
  """
  use ExUnit.Case, async: false

  alias Workbooks.WorkKits

  setup do
    # Pin to the default in-tree toolkit root (wb-q2qg): a leaked WB_WORKKITS_ROOT
    # from an earlier serial test would otherwise point discovery at a fixture/
    # empty dir, so the real workbooks-browser toolkit wouldn't be found.
    prev = System.get_env("WB_WORKKITS_ROOT")
    System.delete_env("WB_WORKKITS_ROOT")
    on_exit(fn -> if prev, do: System.put_env("WB_WORKKITS_ROOT", prev), else: System.delete_env("WB_WORKKITS_ROOT") end)
    :ok
  end

  test "no toolkits → empty string (nothing injected)" do
    assert WorkKits.injection_text([]) == ""
  end

  test "a real toolkit injects a ## Work-kits block with its id + skill index" do
    out = WorkKits.injection_text(["workbooks-browser"])
    assert out =~ "## Work-kits"
    # Teaches the progressive-disclosure call so the agent reads a skill on demand.
    assert out =~ "toolkit show"
    assert out =~ "workbooks-browser"
    # The skill index must be listed (overview is always present).
    assert out =~ "skills:"
    assert out =~ "overview"
  end

  test "no component toolkit in scope → empty catalog (nothing injected)" do
    assert WorkKits.component_catalog([]) == ""
    # A non-component toolkit must NOT yield a catalog.
    assert WorkKits.component_catalog(["workbooks-browser"]) == ""
  end

  test "subscribing to the component toolkit injects a work-* catalog discovered from the CEM" do
    out = WorkKits.component_catalog(["workponents"])
    assert out =~ "## Components"
    # Emit syntax is inline `<work-*>` HTML (no org source blocks).
    assert out =~ "write them as HTML"
    assert out =~ "<work-<tag>"
    # Inline-card types the chat renders via <work-gen-block type="…">.
    assert out =~ ~s(<work-gen-block type="callout")
    assert out =~ ~s(<work-gen-block type="kv")
    # Standalone work-* tags DISCOVERED from custom-elements.json — proof the
    # catalog is sourced from the CEM, not the old hardcoded five. work-chart /
    # work-table are CEM tags that were never in the hardcoded list.
    assert out =~ "work-chart"
    assert out =~ "work-table"
    # The CEM's attribute names ride along as the attr hint.
    assert out =~ "attrs:"
  end

  test "the component catalog reaches the agent prompt via the resolved closure" do
    # End-to-end of the wiring: an agent subscribed to the component toolkit
    # gets the work-* catalog in its prompt. component_catalog/2 is what
    # agent_system_prompt/1 appends, exercised here against the real toolkit.
    out = WorkKits.component_catalog(["workbooks-browser", "workponents"])
    assert out =~ "## Components"
    assert out =~ "work-chart"
  end

  test "an unknown toolkit is reported as not installed, not silently dropped" do
    out = WorkKits.injection_text(["ghost-does-not-exist"])
    assert out =~ "ghost-does-not-exist"
    assert out =~ "(not installed)"
  end

  test "mixed known + unknown — each is accounted for on its own line" do
    out = WorkKits.injection_text(["workbooks-browser", "ghost-zzz"])
    assert out =~ "workbooks-browser"
    assert out =~ "ghost-zzz: (not installed)"
  end

  test "no manifest drift: every skill file is documented in its toolkit manifest" do
    # Guards the drift just fixed (the `models` skill existed but was missing from
    # the workbooks-browser manifest's Live-now table). Every skills/*.md must be
    # mentioned in manifest.html so the doc can't silently fall behind the files.
    root = WorkKits.default_root()

    # Discover EVERY installed toolkit (not a hardcoded pair) so a new toolkit or
    # skill can't dodge the guard.
    toolkits =
      root
      |> File.ls!()
      |> Enum.filter(&File.exists?(Path.join([root, &1, "manifest.html"])))

    assert toolkits != [], "no toolkits discovered under #{root}"

    for tk <- toolkits do
      manifest = File.read!(Path.join([root, tk, "manifest.html"]))

      for skill <- WorkKits.skills(Path.join(root, tk)) do
        assert manifest =~ skill, "#{tk}: skill '#{skill}' missing from manifest.html"
      end
    end
  end

  test "toolkit run on a direct-verb toolkit guides to the DIRECT work command (self-correction)" do
    # The real eval-failure root cause: agents tried `work toolkit run workbooks-cli
    # deploy status` (refused) instead of `work deploy status`. The refusal now names
    # the exact direct command so the agent self-corrects at the point of error.
    cli = WorkKits.run_task_text("workbooks-cli", "deploy", ["status"])
    assert cli =~ "direct-verb"
    assert cli =~ "work deploy status"
    assert cli =~ "don't use `work toolkit run`"

    browser = WorkKits.run_task_text("workbooks-browser", "app", ["status"])
    assert browser =~ "work app status"
  end

  test "toolkit run on an unknown toolkit says so, not a crash" do
    assert WorkKits.run_task_text("ghost-zzz", "x", []) =~ "no such toolkit"
  end

  test "eval_text case-filter: a non-matching filter selects no case (no LLM run)" do
    # The filter narrows to one eval by filename substring — cheap iteration vs
    # the full suite. A bogus filter must short-circuit to a clear message rather
    # than running (and billing) anything.
    out = WorkKits.eval_text("workbooks-cli", WorkKits.default_root(), "no-such-eval-zzz")
    assert out == ~s(workbooks-cli: no eval matches "no-such-eval-zzz")
  end
end
