defmodule Nexus.JJConcurrentIntegrateTest do
  @moduledoc """
  Round 4 (wb-7dbx): multiple agents editing ONE shared workspace concurrently. Each works in its own jj
  worktree, then commits + integrates into main. Concurrent workspace_add + integrate against one repo
  used to race and corrupt main (5 concurrent → 0 landed); Nexus.JJ.with_repo_lock serializes the shared-
  repo mutations (agents still work in parallel) → all N land. Skips cleanly without jj.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    if System.find_executable("jj") && System.find_executable("git") do
      Nexus.Config.put(:jj_substrate, true)
      if Nexus.JJ.substrate?(), do: :ok, else: {:ok, skip: true}
    else
      {:ok, skip: true}
    end
  end

  test "N agents merge into one shared workspace concurrently — all land, none lost", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] jj unavailable — concurrent-integrate safety not exercised")
    else
      n = 5
      root = Path.join(System.tmp_dir!(), "wb-cc-#{System.unique_integer([:positive])}")
      bare = Nexus.Git.bare_path(Path.join(root, "repos"), "site")
      work_dir = Path.join(Path.join(root, "work"), "site")
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, _} = Nexus.Git.provision_remote(bare, work_dir)
      File.write!(Path.join(work_dir, "index.work"), "Shared.\n\nserver :site do\n  def n, do: :ok\nend\n")
      {:ok, _} = Nexus.JJ.commit_change(bare, work_dir, "seed", author: "seed <seed>")

      results =
        1..n
        |> Task.async_stream(
          fn i ->
            dest = Path.join(System.tmp_dir!(), "wt-#{i}-#{System.unique_integer([:positive])}")
            branch = "agent/part-#{i}"

            with {:ok, _} <- Nexus.JJ.workspace_add(bare, work_dir, "w#{i}", dest),
                 :ok <- File.write!(Path.join(dest, "part-#{i}.work"), "Part #{i}.\n\nserver :part#{i} do\n  def n, do: :ok\nend\n"),
                 {:ok, _} <- Nexus.JJ.workspace_commit(dest, "add #{i}", "a#{i} <a#{i}>", branch) do
              r = Nexus.JJ.integrate(bare, work_dir, branch, "main")
              Nexus.JJ.workspace_forget(work_dir, "w#{i}", dest)
              r
            end
          end,
          max_concurrency: n, timeout: 60_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      assert Enum.all?(results, &match?({:ok, _}, &1)), "some integrations failed: #{inspect(results)}"

      {tree, 0} = System.cmd("jj", ["--repository", work_dir, "file", "list", "-r", "main"], stderr_to_stdout: true)
      for i <- 1..n do
        assert tree =~ "part-#{i}.work", "part-#{i}.work lost from main under concurrency"
      end
      assert tree =~ "index.work", "the seed was lost from main"
    end
  end
end
