defmodule Nexus.GitReceiveNestedTest do
  @moduledoc """
  RED tests for the "receive" lane (git push-to-nexus) — nested workspace ids.

  Per CLAUDE.md: a workspace is a declared SUBTREE whose `id` IS its on-disk folder path, and that id
  is ALSO the git remote (`/git/<id>.git`). Nesting is natural (subtree-in-subtree), e.g. `site/lander`
  pushed to `…/git/site/lander.git`. The current `Nexus.GitHttp.serve/2` parses the workspace name with
  `rest |> String.split("/", parts: 2) |> hd()`, which collapses `site/lander.git/info/refs` to `"site"`
  — the WRONG repo — and its `String.contains?(ws, "/")` guard would reject a correct nested id anyway.

  The fix extracts the parse+validate into a pure helper the implementer must provide:

      Nexus.GitHttp.workspace_from_path(rest :: String.t()) ::
        {:ok, ws :: String.t()} | :error

  where `ws` is the FULL nested workspace id with the trailing `.git` and the CGI suffix
  (`/info/refs`, `/git-receive-pack`, `/git-upload-pack`, `/HEAD`, `/objects/...`) stripped, and `:error`
  is returned for an empty name or any path-traversal attempt (`..`). These tests encode that post-fix
  contract and FAIL against the current code (which has no such helper, and mis-parses nested ids).
  """
  use ExUnit.Case
  alias Nexus.Git

  test "workspace_from_path keeps a nested workspace id intact (not collapsed to the first segment)" do
    # The bug: a nested push collapses to the first path segment.
    assert {:ok, "site/lander"} = Nexus.GitHttp.workspace_from_path("site/lander.git/info/refs")
    assert {:ok, "site/lander"} = Nexus.GitHttp.workspace_from_path("site/lander.git/git-receive-pack")
    assert {:ok, "site/lander"} = Nexus.GitHttp.workspace_from_path("site/lander.git/git-upload-pack")
    # Deeper nesting (subtree-in-subtree) is just as valid.
    assert {:ok, "a/b/c"} = Nexus.GitHttp.workspace_from_path("a/b/c.git/info/refs")
  end

  test "workspace_from_path handles a top-level (non-nested) workspace id" do
    assert {:ok, "demo"} = Nexus.GitHttp.workspace_from_path("demo.git/info/refs")
    assert {:ok, "demo"} = Nexus.GitHttp.workspace_from_path("demo.git/git-receive-pack")
    # Bare id (just the repo, no CGI suffix) still resolves.
    assert {:ok, "demo"} = Nexus.GitHttp.workspace_from_path("demo.git")
  end

  test "workspace_from_path rejects traversal and empty names (fail closed)" do
    assert :error = Nexus.GitHttp.workspace_from_path("..")
    assert :error = Nexus.GitHttp.workspace_from_path("../etc/passwd.git/info/refs")
    assert :error = Nexus.GitHttp.workspace_from_path("a/../../b.git/info/refs")
    assert :error = Nexus.GitHttp.workspace_from_path(".git/info/refs")
    assert :error = Nexus.GitHttp.workspace_from_path("")
    assert :error = Nexus.GitHttp.workspace_from_path("/info/refs")
  end

  test "bare_path resolves a NESTED workspace id to a real on-disk bare repo (parent dirs created)" do
    # The id-IS-the-folder-path invariant must hold for nested ids end to end: provisioning a nested
    # workspace must create the intermediate directories so the bare repo actually lands on disk. The
    # current provision_remote relies on File.mkdir_p! so the bare itself is fine — this test guards the
    # full receive flow: push a nested id, files check out under the nested working dir.
    base = Path.join(System.tmp_dir!(), "wbnest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, "site/lander"} = Nexus.GitHttp.workspace_from_path("site/lander.git/git-receive-pack")

    bare = Git.bare_path(Path.join(base, "repos"), "site/lander")
    work = Path.join(base, "work/site/lander")
    {:ok, ^bare} = Git.provision_remote(bare, work)
    assert Git.bare?(bare)

    client = Path.join(base, "client")
    File.mkdir_p!(client)
    src = fn args -> System.cmd("git", args, cd: client, stderr_to_stdout: true) end
    src.(["init", "-q", "-b", "main"])
    src.(["config", "user.name", "t"])
    src.(["config", "user.email", "t@t"])
    File.write!(Path.join(client, "index.work"), "# nested surface\n")
    src.(["add", "-A"])
    src.(["commit", "-q", "-m", "nested"])
    {out, code} = src.(["push", "-q", bare, "main"])

    assert code == 0, out
    assert File.read!(Path.join(work, "index.work")) =~ "nested surface"
  end
end
