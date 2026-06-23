# Round 4: MULTIPLE agents on a SHARED workspace, in PARALLEL.
# Each agent gets its own jj worktree (Nexus.JJ.workspace_add) off one shared bare repo, commits to its
# own branch, and FIFO-integrates into main. Proves intra-workspace concurrency (wb-7dbx).
#   CF_AIG_URL=… CF_AIG_TOKEN=… mix run round4_shared.exs [N]
Nexus.Config.put(:jj_substrate, true)
unless Nexus.JJ.substrate?(), do: (IO.puts("jj substrate unavailable (need jj + flag)"); System.halt(1))

n = case System.argv() do [a | _] -> String.to_integer(a); _ -> 3 end

# Resolve workhorse's def (system/kits/grant/model) for the workers.
src = File.read!(Path.join([File.cwd!(), "..", "dogfood", "cloud", "agents", "workhorse.work"]))
node = src |> Nexus.Literate.parse() |> Enum.find(&(Map.get(&1, :kind) == "agent"))
d = Nexus.Agent.def_from_unit(node)
base_opts =
  [system: d.system]
  |> then(&(if d[:tools], do: Keyword.put(&1, :kits, d[:tools]), else: &1))
  |> then(&(if d[:grant], do: Keyword.put(&1, :grant, d[:grant]), else: &1))
  |> then(&(if d[:model], do: Keyword.put(&1, :model, d[:model]), else: &1))
  |> Keyword.put(:limit, [turns: 20, timeout: 180_000])

# Provision ONE shared workspace + seed main so integrate has a base.
root = Path.join(System.tmp_dir!(), "wb-r4-#{System.system_time()}")
bare = Nexus.Git.bare_path(Path.join(root, "repos"), "site")
work_dir = Path.join(Path.join(root, "work"), "site")
{:ok, _} = Nexus.Git.provision_remote(bare, work_dir)
File.write!(Path.join(work_dir, "index.work"), "Shared marketing site.\n\nserver :site do\n  def name, do: \"site\"\nend\n")
{:ok, _} = Nexus.JJ.commit_change(bare, work_dir, "seed", author: "seed <seed>")
IO.puts("== shared workspace seeded; launching #{n} agents in PARALLEL ==")

t0 = System.monotonic_time(:millisecond)

results =
  1..n
  |> Task.async_stream(
    fn i ->
      ws = %{bare: bare, work_dir: work_dir, name: "site", branch: "agent/part-#{i}",
             author: "agent-#{i} <agent-#{i}>", message: "agent-#{i}: add part-#{i}", mode: "fifo"}
      task = "Create the file /work/part-#{i}.work containing a short prose line and a server unit named :part#{i} with a function ping/0 that returns :ok. Then run 'work check'. Keep it minimal."
      opts = Keyword.merge(base_opts, task: task, workspace: ws)
      res = Nexus.Agent.run(opts)
      {i, match?({:ok, _}, res)}
    end,
    max_concurrency: n, timeout: 200_000
  )
  |> Enum.map(fn {:ok, v} -> v end)

dt = System.monotonic_time(:millisecond) - t0
IO.puts("\n== agents done in #{dt}ms: #{inspect(results)} ==")

# What landed on MAIN (the merged shared tree)?
{out, _} = System.cmd("jj", ["--repository", work_dir, "log", "--no-graph", "-r", "::main", "-T", "description ++ \"\\n\""], stderr_to_stdout: true)
IO.puts("\n--- main commit log (merged) ---\n#{out}")
# Per-agent branches: did each agent actually commit its file? (proves the agents worked vs integrate raced)
IO.puts("--- per-agent branch trees ---")
for i <- 1..n do
  {bt, _} = System.cmd("jj", ["--repository", work_dir, "file", "list", "-r", "agent/part-#{i}"], stderr_to_stdout: true)
  bf = bt |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".work")) |> Enum.map(&Path.basename/1) |> Enum.sort()
  IO.puts("  agent/part-#{i}: #{inspect(bf)}")
end

# What does the MAIN bookmark's tree actually contain? (the authoritative merged result — no checkout needed)
{tree, _} = System.cmd("jj", ["--repository", work_dir, "file", "list", "-r", "main"], stderr_to_stdout: true)
files = tree |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".work")) |> Enum.map(&Path.basename/1) |> Enum.sort()
IO.puts("--- main's tree (jj file list -r main) ---\n#{inspect(files)}")
expected = for i <- 1..n, do: "part-#{i}.work"
missing = expected -- files
IO.puts("\n== RESULT: #{length(expected -- missing)}/#{n} parts merged to the shared workspace ==")
if missing != [], do: IO.puts("MISSING: #{inspect(missing)}")
File.rm_rf(root)
