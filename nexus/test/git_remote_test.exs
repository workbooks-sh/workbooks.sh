defmodule Nexus.GitRemoteTest do
  use ExUnit.Case
  alias Nexus.Git

  setup do
    base = Path.join(System.tmp_dir!(), "wbgit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  test "provision_remote + push checks files out into the working dir", %{base: base} do
    bare = Git.bare_path(Path.join(base, "repos"), "demo")
    work = Path.join(base, "work/demo")
    {:ok, ^bare} = Git.provision_remote(bare, work)
    assert Git.bare?(bare)
    assert File.regular?(Path.join([bare, "hooks", "post-receive"]))

    # A client repo that pushes a .work file to the bare remote.
    client = Path.join(base, "client")
    File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"])
    src.(["config", "user.name", "t"])
    src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "hello.work"), "data Greeting do\n  text :string\nend\n")
    src.(["add", "-A"])
    src.(["commit", "-q", "-m", "first"])
    {out, code} = src.(["push", "-q", bare, "main"])

    assert code == 0, out
    # The post-receive hook should have checked the file out into the working dir.
    assert File.read!(Path.join(work, "hello.work")) =~ "data Greeting"
  end

  test "second push updates the working tree (and removes deleted files)", %{base: base} do
    bare = Git.bare_path(Path.join(base, "repos"), "demo")
    work = Path.join(base, "work/demo")
    Git.provision_remote(bare, work)

    client = Path.join(base, "client")
    File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"]); src.(["config", "user.name", "t"]); src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "a.work"), "x")
    File.write!(Path.join(client, "b.work"), "y")
    src.(["add", "-A"]); src.(["commit", "-q", "-m", "two files"]); src.(["push", "-q", bare, "main"])
    assert File.exists?(Path.join(work, "a.work"))
    assert File.exists?(Path.join(work, "b.work"))

    File.rm!(Path.join(client, "b.work"))
    File.write!(Path.join(client, "a.work"), "x2")
    src.(["add", "-A"]); src.(["commit", "-q", "-m", "drop b, edit a"]); src.(["push", "-q", bare, "main"])

    assert File.read!(Path.join(work, "a.work")) == "x2"
    refute File.exists?(Path.join(work, "b.work")), "checkout -f should remove files deleted upstream"
  end

  test "boot overlay: rehydrate makes a pushed repo win over baked, exactly", %{base: base} do
    # The push-to-deploy overlay (Nexus.Server.rehydrate_checkouts): on boot, each durable bare repo is
    # checked out EXACTLY over its ephemeral image-baked working dir (pushed wins, no baked orphans),
    # while a workspace with NO bare repo keeps its baked copy (the safety-net fallback).
    root = Path.join(base, "data")
    File.mkdir_p!(root)
    prev = System.get_env("WB_DATA")
    System.put_env("WB_DATA", root)
    on_exit(fn -> if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA") end)

    repos = Nexus.GitHttp.repos_root()
    File.mkdir_p!(repos)

    # PUSHED workspace: provision a bare repo + push real content.
    bare = Git.bare_path(repos, "cloud")
    Git.provision_remote(bare, Path.join(root, "cloud"))
    client = Path.join(base, "client"); File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"]); src.(["config", "user.name", "t"]); src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "index.work"), "# PUSHED\n")
    src.(["add", "-A"]); src.(["commit", "-q", "-m", "real"]); src.(["push", "-q", bare, "main"])

    # Simulate REDEPLOY: wipe the ephemeral checkouts + repopulate from the image bake.
    File.rm_rf!(Path.join(root, "cloud")); File.mkdir_p!(Path.join(root, "cloud"))
    File.write!(Path.join(root, "cloud/index.work"), "# BAKED stale\n")
    File.write!(Path.join(root, "cloud/orphan.work"), "baked only\n")
    # A never-pushed surface (no bare repo) — its baked copy must be left alone.
    File.mkdir_p!(Path.join(root, "login"))
    File.write!(Path.join(root, "login/index.work"), "# BAKED login\n")

    Nexus.Server.rehydrate_checkouts_for_test(root)

    assert File.read!(Path.join(root, "cloud/index.work")) =~ "PUSHED"
    refute File.exists?(Path.join(root, "cloud/orphan.work")), "overlay is exact — baked orphans removed"
    assert File.read!(Path.join(root, "login/index.work")) =~ "BAKED login", "never-pushed surface keeps its baked copy"
  end

  test "set_mirror makes a push mirror its refs to the configured remote", %{base: base} do
    bare = Git.bare_path(Path.join(base, "repos"), "demo")
    work = Path.join(base, "work/demo")
    Git.provision_remote(bare, work)

    # A second bare repo standing in for "the org's GitHub".
    mirror = Path.join(base, "mirror.git")
    System.cmd("git", ["init", "--bare", "-q", "-b", "main", mirror], stderr_to_stdout: true)
    Git.set_mirror(bare, mirror)

    client = Path.join(base, "client")
    File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"]); src.(["config", "user.name", "t"]); src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "m.work"), "mirror me")
    src.(["add", "-A"]); src.(["commit", "-q", "-m", "mirror"]); src.(["push", "-q", bare, "main"])

    # The mirror remote should now have the main ref.
    {refs, 0} = System.cmd("git", ["--git-dir=#{mirror}", "for-each-ref", "--format=%(refname)"], stderr_to_stdout: true)
    assert refs =~ "refs/heads/main"
  end

  test "commit_file saves a working-tree edit into the bare repo (and mirrors)", %{base: base} do
    bare = Git.bare_path(Path.join(base, "repos"), "demo")
    work = Path.join(base, "work/demo")
    Git.provision_remote(bare, work)

    # Seed the repo with an initial push so HEAD/main exists.
    client = Path.join(base, "client"); File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"]); src.(["config", "user.name", "t"]); src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "a.work"), "v1"); src.(["add", "-A"]); src.(["commit", "-q", "-m", "init"]); src.(["push", "-q", bare, "main"])

    # A mirror, configured.
    mirror = Path.join(base, "mirror.git"); System.cmd("git", ["init", "--bare", "-q", "-b", "main", mirror], stderr_to_stdout: true)
    Git.set_mirror(bare, mirror)

    # The dashboard edits the working file, then saves it as a commit.
    File.write!(Path.join(work, "a.work"), "v2-edited")
    assert {:ok, _sha} = Git.commit_file(bare, work, "a.work", "edit via dashboard")

    # History advanced in the bare repo, and the mirror received it.
    {log, 0} = System.cmd("git", ["--git-dir=#{bare}", "log", "--format=%s", "-n", "1"], stderr_to_stdout: true)
    assert log =~ "edit via dashboard"
    {mlog, 0} = System.cmd("git", ["--git-dir=#{mirror}", "log", "--format=%s", "-n", "1"], stderr_to_stdout: true)
    assert mlog =~ "edit via dashboard"

    # No-op commit when nothing changed.
    assert :nochange = Git.commit_file(bare, work, "a.work", "noop")
  end
end
