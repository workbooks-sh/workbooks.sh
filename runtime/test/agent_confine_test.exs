defmodule Workbooks.AgentConfineTest do
  use ExUnit.Case, async: true

  # Security-critical (wb-9ae confinement + general runtime safety): an exec
  # agent's file tools (vfs_read/vfs_write) MUST NOT escape their workdir. Before
  # the fix they were unguarded — an agent could read/write /etc/passwd, host
  # *.ex, secrets, or another tenant's repo via an absolute path or `..`. This
  # exercises the real guard (safe_path_for_test delegates to the production
  # safe_path/2).
  @wd "/tmp/wb-confine-wd"

  test "legit paths inside the workdir are allowed" do
    assert {:ok, _} = Workbooks.Agent.safe_path_for_test(@wd, "content/stories/x.org")
    assert {:ok, _} = Workbooks.Agent.safe_path_for_test(@wd, "file.txt")
    # an absolute path that IS inside the workdir is fine (agents pass these)
    assert {:ok, _} = Workbooks.Agent.safe_path_for_test(@wd, "#{@wd}/content/x.org")
  end

  test "`..` traversal out of the workdir is blocked" do
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "../secret.txt")
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "../../runtime/host/agent.ex")
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "content/../../escape")
  end

  test "absolute paths OUTSIDE the workdir are blocked" do
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "/etc/passwd")
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "/data/wb-other-tenant/content/x.org")
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "/tmp/wb-confine-wd-sibling/x")
  end

  test "a sibling dir sharing a prefix does not pass (no prefix-confusion)" do
    # "/tmp/wb-confine-wd-evil" starts with "/tmp/wb-confine-wd" as a STRING but
    # is not inside it — the trailing-slash check must reject it.
    assert :escape = Workbooks.Agent.safe_path_for_test(@wd, "/tmp/wb-confine-wd-evil/x")
  end
end
