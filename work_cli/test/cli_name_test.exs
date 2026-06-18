defmodule WorkCLI.NameTest do
  use ExUnit.Case, async: true

  # The sibling CLI is the canonical `work` binary (mirrors the runtime guardrail). The escript name
  # must stay "work" and the entry module WorkCLI.Main, so the installer can ship this as `work`.
  test "the escript is named work with the WorkCLI.Main entrypoint" do
    project = WorkCLI.MixProject.project()
    escript = Keyword.fetch!(project, :escript)
    assert escript[:name] == "work"
    assert escript[:main_module] == WorkCLI.Main
  end
end
