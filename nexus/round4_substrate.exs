# Round 4 (substrate): can N workers edit ONE shared workspace concurrently and all land on main?
# Deterministic — NO LLM (isolates the jj concurrency from model flakiness). Each worker: own jj worktree
# → write part-i.work → commit to its branch → integrate into main. Then assert main's tree has all N.
#   mix run round4_substrate.exs [N]
Nexus.Config.put(:jj_substrate, true)
unless Nexus.JJ.substrate?(), do: (IO.puts("jj substrate unavailable"); System.halt(1))
n = case System.argv() do [a | _] -> String.to_integer(a); _ -> 5 end

root = Path.join(System.tmp_dir!(), "wb-r4s-#{System.system_time()}")
bare = Nexus.Git.bare_path(Path.join(root, "repos"), "site")
work_dir = Path.join(Path.join(root, "work"), "site")
{:ok, _} = Nexus.Git.provision_remote(bare, work_dir)
File.write!(Path.join(work_dir, "index.work"), "Shared site.\n\nserver :site do\n  def name, do: \"site\"\nend\n")
{:ok, _} = Nexus.JJ.commit_change(bare, work_dir, "seed", author: "seed <seed>")
IO.puts("== seeded; #{n} workers editing the SAME workspace concurrently (no LLM) ==")

t0 = System.monotonic_time(:millisecond)

results =
  1..n
  |> Task.async_stream(fn i ->
    dest = Path.join(System.tmp_dir!(), "wt-#{i}-#{System.unique_integer([:positive])}")
    branch = "agent/part-#{i}"
    with {:ok, _} <- Nexus.JJ.workspace_add(bare, work_dir, "w#{i}", dest),
         :ok <- (File.write!(Path.join(dest, "part-#{i}.work"), "Part #{i}.\n\nserver :part#{i} do\n  def ping, do: :ok\nend\n"); :ok),
         {:ok, _} <- Nexus.JJ.workspace_commit(dest, "add part-#{i}", "a#{i} <a#{i}>", branch) do
      r = Nexus.JJ.integrate(bare, work_dir, branch, "main")
      Nexus.JJ.workspace_forget(work_dir, "w#{i}", dest)
      {i, r}
    else
      e -> {i, {:setup_failed, e}}
    end
  end, max_concurrency: n, timeout: 60_000)
  |> Enum.map(fn {:ok, v} -> v end)

dt = System.monotonic_time(:millisecond) - t0
IO.puts("== integrate results (#{dt}ms) ==")
for {i, r} <- results, do: IO.puts("  part-#{i}: #{inspect(r, limit: 2)}")

{tree, _} = System.cmd("jj", ["--repository", work_dir, "file", "list", "-r", "main"], stderr_to_stdout: true)
files = tree |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".work")) |> Enum.map(&Path.basename/1) |> Enum.sort()
IO.puts("\n--- main's tree ---\n#{inspect(files)}")
expected = for i <- 1..n, do: "part-#{i}.work"
landed = Enum.count(expected, &(&1 in files))
IO.puts("== RESULT: #{landed}/#{n} parts merged to main concurrently ==")
File.rm_rf(root)
