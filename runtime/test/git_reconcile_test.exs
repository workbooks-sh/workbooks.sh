defmodule Workbooks.GitReconcileTest do
  use ExUnit.Case, async: false

  # GitOps inbound (wb-642i): `Workbooks.Git.pull/1` lets a human push a CODE
  # update to the tenant's GitHub repo and have the live runtime integrate it
  # WITHOUT clobbering the agent's DATA. The proof: a merge integrates, it does not
  # overwrite — code and data are different files, so both survive. Same-file
  # divergence is reported + rolled back, never silently lost.

  @root "/tmp/wb-gitops-test"

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    System.put_env("WB_DATA", @root)
    on_exit(fn ->
      File.rm_rf!(@root)
      System.delete_env("WB_DATA")
    end)
    :ok
  end

  defp g(dir, args),
    do: System.cmd("git", ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "safe.directory=*"] ++ args, cd: dir, stderr_to_stdout: true)

  test "pull integrates an upstream CODE push with the agent's local DATA commit — neither clobbered" do
    tenant = "gitops"
    dir = Workbooks.Git.ensure_repo(tenant)

    # seed: a CODE file + a DATA file on `main`
    g(dir, ["checkout", "-b", "main"])
    File.write!(Path.join(dir, "design.org"), "canon v1\n")
    File.mkdir_p!(Path.join(dir, "content"))
    File.write!(Path.join(dir, "content/post.org"), "post v1\n")
    g(dir, ["add", "-A"])
    g(dir, ["commit", "-m", "seed"])

    # a bare origin + push the seed
    origin = Path.join(@root, "origin.git")
    System.cmd("git", ["init", "--bare", "-q", origin])
    g(dir, ["remote", "add", "origin", origin])
    g(dir, ["push", "-q", "origin", "main"])

    # HUMAN: clone origin elsewhere, edit the CODE file, push it upstream
    human = Path.join(@root, "human")
    System.cmd("git", ["clone", "-q", origin, human])
    File.write!(Path.join(human, "design.org"), "canon v2 — human update\n")
    g(human, ["add", "-A"])
    g(human, ["commit", "-m", "human: update canon"])
    g(human, ["push", "-q", "origin", "main"])

    # AGENT: meanwhile commits a DATA change locally (not yet pushed)
    File.write!(Path.join(dir, "content/post.org"), "post v2 — agent wrote this\n")
    g(dir, ["add", "-A"])
    g(dir, ["commit", "-m", "agent: new post"])

    # RECONCILE — pull the human's code into the live repo
    assert {:ok, {:applied, summary}} = Workbooks.Git.pull(tenant)
    assert "design.org" in summary.files

    # BOTH survive — the human's code AND the agent's data
    assert File.read!(Path.join(dir, "design.org")) =~ "human update"
    assert File.read!(Path.join(dir, "content/post.org")) =~ "agent wrote this"
  end

  test "pull is a no-op when origin has nothing new" do
    tenant = "gitops2"
    dir = Workbooks.Git.ensure_repo(tenant)
    g(dir, ["checkout", "-b", "main"])
    File.write!(Path.join(dir, "x.org"), "v1\n")
    g(dir, ["add", "-A"])
    g(dir, ["commit", "-m", "s"])
    origin = Path.join(@root, "origin2.git")
    System.cmd("git", ["init", "--bare", "-q", origin])
    g(dir, ["remote", "add", "origin", origin])
    g(dir, ["push", "-q", "origin", "main"])

    assert {:ok, :uptodate} = Workbooks.Git.pull(tenant)
  end

  test "pull skips cleanly when there is no origin remote" do
    assert {:skip, _} = Workbooks.Git.pull("noremote")
  end
end
