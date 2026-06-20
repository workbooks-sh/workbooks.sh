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
end
