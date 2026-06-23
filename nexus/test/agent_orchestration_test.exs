defmodule Nexus.AgentOrchestrationTest do
  @moduledoc """
  Round 4 orchestration: when the parent runs in a shared workspace, a delegated sub-agent inherits that
  workspace on its OWN unique branch (so it edits real files in its own jj worktree and FIFO-integrates),
  turning delegation into multi-agent orchestration. Without a parent workspace, delegation stays text-only.
  """
  use ExUnit.Case, async: true
  alias Nexus.Agent.Bash

  test "with a parent workspace, the sub-agent inherits it on a unique branch" do
    ws = %{bare: "/repos/site.git", work_dir: "/work/site", name: "site"}
    perms = %{grant: ["fs", "exec"], depth: 0, workspace: ws}

    o1 = Bash.sub_opts_for_test("worker", "build part 1", 0, perms)
    o2 = Bash.sub_opts_for_test("worker", "build part 2", 0, perms)

    assert o1[:depth] == 1
    assert o1[:grant_ceiling] == ["fs", "exec"]

    w1 = o1[:workspace]
    w2 = o2[:workspace]
    assert w1[:bare] == "/repos/site.git" and w1[:work_dir] == "/work/site"
    assert String.starts_with?(w1[:branch], "agent/worker-")
    # Each delegation gets a DISTINCT branch so parallel sub-agents never collide.
    refute w1[:branch] == w2[:branch]
  end

  test "without a parent workspace, delegation stays text-only (no workspace opt)" do
    perms = %{grant: ["fs"], depth: 0}
    o = Bash.sub_opts_for_test("worker", "summarize", 0, perms)
    assert o[:depth] == 1
    assert o[:workspace] == nil
  end
end
