defmodule Workbooks.DraftTest do
  @moduledoc """
  Phase 5 — Drafts. A Draft is an isolated worktree off the live version: editing a
  Draft must NOT touch the live tree; Keep folds it in (append-only merge); Discard
  throws it away leaving the live version untouched. Plus name-confinement.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Draft, Git}

  setup do
    prev = System.get_env("WB_DATA")
    data = Path.join(System.tmp_dir!(), "wb-draft-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)
    on_exit(fn ->
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      File.rm_rf(data)
    end)
    :ok
  end

  defp uniq(p), do: "#{p}-#{System.unique_integer([:positive])}"

  # seed a tenant repo with a committed home.md on the live branch
  defp seed(tenant, content) do
    dir = Git.ensure_repo(tenant)
    File.write!(Path.join(dir, "home.md"), content)
    Git.commit_and_push(dir, "seed", tenant)
    dir
  end

  # edit + commit a file inside a Draft's worktree (simulating work on the Draft)
  defp edit_in_draft(dir, name, file, content) do
    wt = Path.join([dir, ".drafts", name])
    File.write!(Path.join(wt, file), content)
    env = [{"GIT_AUTHOR_NAME", "x"}, {"GIT_AUTHOR_EMAIL", "x@y.z"}, {"GIT_COMMITTER_NAME", "x"}, {"GIT_COMMITTER_EMAIL", "x@y.z"}]
    System.cmd("git", ["-c", "safe.directory=*", "add", "-A"], cd: wt, stderr_to_stdout: true)
    System.cmd("git", ["-c", "safe.directory=*", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "edit"], cd: wt, env: env, stderr_to_stdout: true)
  end

  test "a Draft edit does NOT touch the live version; Keep folds it in" do
    t = uniq("acme")
    dir = seed(t, "# Home v1\n")

    assert {:ok, %{name: "redesign", preview_path: ".drafts/redesign"}} = Draft.create(t, "redesign")

    edit_in_draft(dir, "redesign", "home.md", "# Home — REDESIGNED\n")

    # the live tree is untouched while the Draft holds the change
    assert File.read!(Path.join(dir, "home.md")) == "# Home v1\n"

    # the Draft's diff shows the change
    assert {:ok, changes} = Draft.diff(t, "redesign")
    assert Enum.any?(changes, &(&1.path == "home.md" and &1.status == "modified"))

    # Keep folds the Draft into the live version, then removes the Draft
    assert {:ok, %{merged: "redesign"}} = Draft.keep(t, "redesign")
    assert File.read!(Path.join(dir, "home.md")) =~ "REDESIGNED"
    assert Draft.list(t) == []
    refute File.dir?(Path.join([dir, ".drafts", "redesign"]))
  end

  test "Discard throws the Draft away; the live version never changed" do
    t = uniq("beta")
    dir = seed(t, "# Home v1\n")
    {:ok, _} = Draft.create(t, "experiment")
    edit_in_draft(dir, "experiment", "home.md", "# wild experiment\n")

    assert :ok = Draft.discard(t, "experiment")
    # live untouched, Draft gone
    assert File.read!(Path.join(dir, "home.md")) == "# Home v1\n"
    assert Draft.list(t) == []
    refute File.dir?(Path.join([dir, ".drafts", "experiment"]))
  end

  test "list reports open Drafts with a change count" do
    t = uniq("gamma")
    dir = seed(t, "# Home\n")
    {:ok, _} = Draft.create(t, "one")
    edit_in_draft(dir, "one", "a.md", "new file\n")

    drafts = Draft.list(t)
    assert Enum.any?(drafts, &(&1.name == "one" and &1.files_changed >= 1))
  end

  test "name confinement + missing-Draft errors" do
    t = uniq("delta")
    seed(t, "# Home\n")

    assert {:error, :bad_name} = Draft.create(t, "../escape")
    assert {:error, :bad_name} = Draft.create(t, "a/b")
    assert {:error, :bad_name} = Draft.create(t, "")
    assert {:error, :not_found} = Draft.diff(t, "ghost")
    assert {:error, :not_found} = Draft.keep(t, "ghost")
    assert {:error, :not_found} = Draft.discard(t, "ghost")

    {:ok, _} = Draft.create(t, "dup")
    assert {:error, :exists} = Draft.create(t, "dup")
  end
end
